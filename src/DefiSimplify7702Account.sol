// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Exec} from "@account-abstraction/contracts/utils/Exec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IDefiSimplify7702Account} from "./interfaces/IDefiSimplify7702Account.sol";

/// @title DefiSimplify7702Account
/// @notice EIP-7702 delegated account with inherited static execution and dynamic batch execution.
/// @dev This implementation is deployed directly and used as an EIP-7702 delegation target.
///      During delegated execution, `address(this)` is the delegated EOA, not this implementation's
///      deployment address. The immutable EntryPoint and all account behavior are inherited from
///      the pinned upstream Simple7702Account v0.9.0 implementation.
contract DefiSimplify7702Account is Simple7702Account, IDefiSimplify7702Account {
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    /// @dev Transient reentrancy-lock slot shared by every dynamic execution frame of this account.
    bytes32 internal constant _DYNAMIC_EXECUTION_LOCK_SLOT =
        keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");
    /// @dev Transient monotonically increasing counter that scopes invocations within one transaction.
    bytes32 internal constant _DYNAMIC_INVOCATION_COUNTER_SLOT =
        keccak256("DefiSimplify7702Account.dynamicInvocationCounter.v1");
    /// @dev Domain-separated root of the invocation- and checkpoint-keyed transient record table.
    bytes32 internal constant _CHECKPOINT_TABLE_NAMESPACE = keccak256("DefiSimplify7702Account.checkpointTable.v1");

    /// @dev Per-call memory cache shared by patch resolution and checkpoint creation.
    /// @param tokens ERC20 addresses stored in insertion order.
    /// @param balances Balance corresponding to each token at the same index.
    /// @param length Number of populated entries in the preallocated arrays.
    struct BalanceCache {
        address[] tokens;
        uint256[] balances;
        uint256 length;
    }

    /// @notice Constructs the immutable delegation implementation for one EntryPoint.
    /// @param anEntryPoint EntryPoint authorized by the inherited account implementation.
    constructor(IEntryPoint anEntryPoint) Simple7702Account(anEntryPoint) {}

    /// @inheritdoc IDefiSimplify7702Account
    function executeBatchDynamic(DynamicCall[] calldata calls) external payable override {
        _requireForExecute();

        TransientSlot.BooleanSlot lockSlot = _DYNAMIC_EXECUTION_LOCK_SLOT.asBoolean();
        if (lockSlot.tload()) {
            revert DynamicExecutionReentered();
        }
        lockSlot.tstore(true);

        uint256 invocationId = _allocateInvocationId();

        uint256 callsLength = calls.length;
        if (callsLength == 0) {
            revert EmptyDynamicBatch();
        }

        for (uint256 i = 0; i < callsLength; ++i) {
            DynamicCall calldata dynamicCall = calls[i];
            address target = dynamicCall.target;
            if (target == address(0) || target == address(this)) {
                revert InvalidTarget(i, target);
            }

            bytes memory data = dynamicCall.data;
            BalanceCache memory cache =
                _newBalanceCache(dynamicCall.patches.length + dynamicCall.checkpointsBefore.length);
            _applyPatches(invocationId, i, dynamicCall.patches, data, cache);
            _createCheckpoints(invocationId, i, dynamicCall.checkpointsBefore, cache);

            bool success = Exec.call(target, dynamicCall.value, data, gasleft());
            if (!success) {
                revert DynamicCallFailed(i, target, Exec.getReturnData(0));
            }
        }

        lockSlot.tstore(false);
    }

    /// @dev Increments the transaction-scoped transient counter and returns this frame's checkpoint scope.
    ///      EVM revert semantics roll back the allocation together with the containing execution.
    /// @return invocationId Nonzero identifier retained by the active dynamic execution frame.
    function _allocateInvocationId() internal returns (uint256 invocationId) {
        TransientSlot.Uint256Slot counterSlot = _DYNAMIC_INVOCATION_COUNTER_SLOT.asUint256();
        invocationId = counterSlot.tload() + 1;
        counterSlot.tstore(invocationId);
    }

    /// @dev Validates and applies every patch in strict offset order before same-call checkpoints are created.
    /// @param invocationId Active invocation scope used for checkpoint lookup.
    /// @param callIndex Index of the call whose calldata is being patched.
    /// @param patches Ordered patch descriptors supplied for the call.
    /// @param data Mutable memory copy of the target calldata.
    /// @param cache Per-call token-balance cache.
    function _applyPatches(
        uint256 invocationId,
        uint256 callIndex,
        BalancePatch[] calldata patches,
        bytes memory data,
        BalanceCache memory cache
    ) internal view {
        uint256 patchesLength = patches.length;
        uint256 previousOffset = 0;

        for (uint256 patchIndex = 0; patchIndex < patchesLength; ++patchIndex) {
            BalancePatch calldata patch = patches[patchIndex];
            uint256 offset = _validatePatch(callIndex, patchIndex, patch, data.length, previousOffset);
            previousOffset = offset;
            _writePatch(data, offset, _resolvePatchAmount(invocationId, callIndex, patchIndex, patch, cache));
        }
    }

    /// @dev Validates a patch token, ABI word offset, ordering, and basis-point range.
    /// @param callIndex Index of the call containing the patch.
    /// @param patchIndex Index of the patch within the call.
    /// @param patch Patch descriptor to validate.
    /// @param dataLength Length of the mutable target calldata.
    /// @param previousOffset Validated offset of the preceding patch, ignored for index zero.
    /// @return offset Validated calldata byte offset.
    function _validatePatch(
        uint256 callIndex,
        uint256 patchIndex,
        BalancePatch calldata patch,
        uint256 dataLength,
        uint256 previousOffset
    ) private pure returns (uint256 offset) {
        if (patch.token == address(0)) {
            revert InvalidPatchToken(callIndex, patchIndex);
        }

        offset = patch.offset;
        if (offset < 4 || (offset - 4) % 32 != 0 || offset + 32 > dataLength) {
            revert InvalidPatchOffset(callIndex, patchIndex, offset, dataLength);
        }
        if (patchIndex != 0 && offset <= previousOffset) {
            revert UnsortedPatchOffset(callIndex, patchIndex, previousOffset, offset);
        }

        uint256 bps = patch.bps;
        if (bps == 0 || bps > 10_000) {
            revert InvalidBps(callIndex, patchIndex, bps);
        }
    }

    /// @dev Resolves a patch amount from either the current balance or an invocation-local checkpoint delta.
    /// @param invocationId Active invocation scope used for checkpoint lookup.
    /// @param callIndex Index of the call containing the patch.
    /// @param patchIndex Index of the patch within the call.
    /// @param patch Patch descriptor whose amount is resolved.
    /// @param cache Per-call token-balance cache.
    /// @return amount Full-precision `floor(base * bps / 10_000)` result.
    function _resolvePatchAmount(
        uint256 invocationId,
        uint256 callIndex,
        uint256 patchIndex,
        BalancePatch calldata patch,
        BalanceCache memory cache
    ) private view returns (uint256 amount) {
        address token = patch.token;
        bytes32 checkpointId = patch.checkpointId;
        uint256 checkpointBalance = 0;
        if (patch.source == BalanceSource.CurrentBalance) {
            if (checkpointId != bytes32(0)) {
                revert UnexpectedCheckpointId(callIndex, patchIndex, checkpointId);
            }
        } else {
            checkpointBalance = _loadCheckpointBalance(invocationId, callIndex, patchIndex, token, checkpointId);
        }

        uint256 currentBalance = _currentBalanceForPatch(callIndex, patchIndex, token, cache);
        uint256 base;
        if (patch.source == BalanceSource.CurrentBalance) {
            base = currentBalance;
        } else {
            if (currentBalance < checkpointBalance) {
                revert BalanceBelowCheckpoint(
                    callIndex, patchIndex, token, checkpointId, currentBalance, checkpointBalance
                );
            }
            base = currentBalance - checkpointBalance;
        }

        return Math.mulDiv(base, uint256(patch.bps), 10_000);
    }

    /// @dev Replaces exactly one previously validated 32-byte calldata word.
    /// @param data Mutable memory copy of the target calldata.
    /// @param offset Byte offset from the beginning of `data`, including its selector.
    /// @param amount Unsigned integer encoded into the selected ABI word.
    function _writePatch(bytes memory data, uint256 offset, uint256 amount) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), amount)
        }
    }

    /// @dev Validates and records checkpoints after patch resolution and immediately before the target call.
    /// @param invocationId Active invocation scope in which records are stored.
    /// @param callIndex Index of the call declaring the checkpoints.
    /// @param checkpoints Ordered checkpoint descriptors declared by the call.
    /// @param cache Per-call token-balance cache shared with patch resolution.
    function _createCheckpoints(
        uint256 invocationId,
        uint256 callIndex,
        BalanceCheckpoint[] calldata checkpoints,
        BalanceCache memory cache
    ) internal {
        uint256 checkpointsLength = checkpoints.length;
        for (uint256 checkpointIndex = 0; checkpointIndex < checkpointsLength; ++checkpointIndex) {
            BalanceCheckpoint calldata checkpoint = checkpoints[checkpointIndex];
            address token = checkpoint.token;
            if (token == address(0)) {
                revert InvalidCheckpointToken(callIndex, checkpointIndex);
            }

            bytes32 checkpointId = checkpoint.id;
            if (checkpointId == bytes32(0)) {
                revert InvalidCheckpointId(callIndex, checkpointIndex);
            }

            bytes32 recordRoot = _checkpointRecordRoot(invocationId, checkpointId);
            TransientSlot.BooleanSlot presenceSlot = recordRoot.asBoolean();
            TransientSlot.AddressSlot tokenSlot = recordRoot.offset(1).asAddress();
            TransientSlot.Uint256Slot balanceSlot = recordRoot.offset(2).asUint256();
            if (presenceSlot.tload()) {
                revert CheckpointAlreadyExists(callIndex, checkpointIndex, checkpointId);
            }

            uint256 balance = _currentBalanceForCheckpoint(callIndex, checkpointIndex, token, cache);
            presenceSlot.tstore(true);
            tokenSlot.tstore(token);
            balanceSlot.tstore(balance);
        }
    }

    /// @dev Derives the root slot of the transient checkpoint record scoped by
    ///      `(invocationId, checkpointId)`. The logical record layout is:
    ///      offset 0 = presence, offset 1 = token, offset 2 = checkpoint balance.
    /// @param invocationId Active invocation scope containing the checkpoint.
    /// @param checkpointId Invocation-local checkpoint identifier.
    /// @return recordRoot Slot at offset zero of the logical transient record.
    function _checkpointRecordRoot(uint256 invocationId, bytes32 checkpointId) internal pure returns (bytes32) {
        return _CHECKPOINT_TABLE_NAMESPACE.deriveMapping(invocationId).deriveMapping(checkpointId);
    }

    /// @dev Loads and token-validates a checkpoint from the active invocation's transient table.
    /// @param invocationId Active invocation scope containing the checkpoint.
    /// @param callIndex Index of the call containing the consuming patch.
    /// @param patchIndex Index of the consuming patch within the call.
    /// @param token Token expected by the consuming patch.
    /// @param checkpointId Referenced checkpoint identifier.
    /// @return checkpointBalance Token balance recorded by the checkpoint.
    function _loadCheckpointBalance(
        uint256 invocationId,
        uint256 callIndex,
        uint256 patchIndex,
        address token,
        bytes32 checkpointId
    ) private view returns (uint256 checkpointBalance) {
        bytes32 recordRoot = _checkpointRecordRoot(invocationId, checkpointId);
        if (!recordRoot.asBoolean().tload()) {
            revert CheckpointNotFound(callIndex, patchIndex, checkpointId);
        }

        address checkpointToken = recordRoot.offset(1).asAddress().tload();
        if (checkpointToken != token) {
            revert CheckpointTokenMismatch(callIndex, patchIndex, checkpointId, token, checkpointToken);
        }

        return recordRoot.offset(2).asUint256().tload();
    }

    /// @dev Preallocates a zero-length per-call balance cache with the requested capacity.
    /// @param capacity Maximum number of distinct balance reads before the target call.
    /// @return cache Empty cache whose token and balance arrays have `capacity` elements.
    function _newBalanceCache(uint256 capacity) private pure returns (BalanceCache memory cache) {
        cache.tokens = new address[](capacity);
        cache.balances = new uint256[](capacity);
    }

    /// @dev Returns a cached balance or performs the first patch-attributed checked balance read.
    /// @param callIndex Index of the call containing the patch.
    /// @param patchIndex Index of the patch that triggers the read on a cache miss.
    /// @param token ERC20 whose delegated-account balance is requested.
    /// @param cache Per-call token-balance cache.
    /// @return tokenBalance Current balance observed before the target call.
    function _currentBalanceForPatch(uint256 callIndex, uint256 patchIndex, address token, BalanceCache memory cache)
        private
        view
        returns (uint256 tokenBalance)
    {
        (bool found, uint256 cachedBalance) = _findCachedBalance(token, cache);
        if (found) {
            return cachedBalance;
        }

        (bool success, bytes memory returnData, uint256 balance) = _readBalance(token);
        if (!success || returnData.length < 32) {
            revert PatchBalanceReadFailed(callIndex, patchIndex, token, returnData);
        }
        _storeCachedBalance(token, balance, cache);
        return balance;
    }

    /// @dev Returns a cached balance or performs the first checkpoint-attributed checked balance read.
    /// @param callIndex Index of the call declaring the checkpoint.
    /// @param checkpointIndex Index of the checkpoint that triggers the read on a cache miss.
    /// @param token ERC20 whose delegated-account balance is requested.
    /// @param cache Per-call token-balance cache.
    /// @return tokenBalance Current balance observed before the target call.
    function _currentBalanceForCheckpoint(
        uint256 callIndex,
        uint256 checkpointIndex,
        address token,
        BalanceCache memory cache
    ) private view returns (uint256 tokenBalance) {
        (bool found, uint256 cachedBalance) = _findCachedBalance(token, cache);
        if (found) {
            return cachedBalance;
        }

        (bool success, bytes memory returnData, uint256 balance) = _readBalance(token);
        if (!success || returnData.length < 32) {
            revert CheckpointBalanceReadFailed(callIndex, checkpointIndex, token, returnData);
        }
        _storeCachedBalance(token, balance, cache);
        return balance;
    }

    /// @dev Performs a linear lookup over populated entries in the small per-call memory cache.
    /// @param token ERC20 address to locate.
    /// @param cache Per-call token-balance cache.
    /// @return found Whether the token already has a cached balance.
    /// @return balance Cached balance when `found` is true.
    function _findCachedBalance(address token, BalanceCache memory cache)
        private
        pure
        returns (bool found, uint256 balance)
    {
        uint256 cacheLength = cache.length;
        for (uint256 i = 0; i < cacheLength; ++i) {
            if (cache.tokens[i] == token) {
                return (true, cache.balances[i]);
            }
        }
    }

    /// @dev Appends a token and balance to the preallocated per-call cache.
    /// @param token ERC20 address to cache.
    /// @param balance Balance observed for the token.
    /// @param cache Per-call token-balance cache.
    function _storeCachedBalance(address token, uint256 balance, BalanceCache memory cache) private pure {
        uint256 cacheIndex = cache.length;
        cache.tokens[cacheIndex] = token;
        cache.balances[cacheIndex] = balance;
        cache.length = cacheIndex + 1;
    }

    /// @dev Reads `balanceOf(address(this))` by low-level `STATICCALL` and preserves raw returndata.
    ///      Callers decide whether failure or returndata shorter than 32 bytes is checkpoint- or patch-attributed.
    /// @param token ERC20 whose delegated-account balance is read.
    /// @return success Whether the low-level call succeeded.
    /// @return returnData Complete returndata from the token.
    /// @return tokenBalance First returned word when at least 32 bytes are available; otherwise zero.
    function _readBalance(address token)
        private
        view
        returns (bool success, bytes memory returnData, uint256 tokenBalance)
    {
        (success, returnData) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));

        if (returnData.length >= 32) {
            assembly ("memory-safe") {
                tokenBalance := mload(add(returnData, 32))
            }
        }
    }

    /// @inheritdoc Simple7702Account
    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return id == type(IDefiSimplify7702Account).interfaceId || super.supportsInterface(id);
    }
}
