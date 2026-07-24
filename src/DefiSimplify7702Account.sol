// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Exec} from "@account-abstraction/contracts/utils/Exec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAaveV3FlashLoanSimplePool} from "./interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "./interfaces/IDefiSimplify7702Account.sol";
import {TransientTokenBalanceRecord} from "./libraries/TransientTokenBalanceRecord.sol";
import {TransientLock} from "./libraries/TransientLock.sol";
import {TransientCounter} from "./libraries/TransientCounter.sol";
import {TransientCallback} from "./libraries/TransientCallback.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

/// @title DefiSimplify7702Account
/// @notice EIP-7702 delegated account with inherited static execution, dynamic batches, and one Aave V3 callback.
/// @dev This implementation is deployed directly and used as an EIP-7702 delegation target.
///      During delegated execution, `address(this)` is the delegated EOA, not this implementation's
///      deployment address. The immutable EntryPoint and all account behavior are inherited from
///      the pinned upstream Simple7702Account v0.9.0 implementation.
contract DefiSimplify7702Account is Simple7702Account, IDefiSimplify7702Account {
    using SlotDerivation for bytes32;
    using TransientTokenBalanceRecord for bytes32;

    // keccak256("DefiSimplify7702Account.checkpointTable")
    bytes32 internal constant _CHECKPOINT_TABLE_SLOT =
        0xd1d3a863e7516a2a35bb0fe7d400238fd14cf626e5d368379324d5240f1186da;

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

        uint256 callsLength = calls.length;
        if (callsLength == 0) {
            revert EmptyDynamicBatch();
        }
        if (TransientLock.isLocked()) {
            revert DynamicExecutionReentered();
        }
        TransientLock.lock();

        _validateOuterCallbackCount(calls);
        uint256 invocationId = _allocateInvocationId();

        for (uint256 i = 0; i < callsLength; ++i) {
            _executeDynamicCall(invocationId, i, calls[i], false, 0);
        }

        TransientLock.unlock();
    }

    /// @inheritdoc IDefiSimplify7702Account
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        override
        returns (bool success)
    {
        uint256 outerCallIndex = _authenticateAaveV3Callback(asset, amount, initiator, params);

        CallbackEnvelope memory envelope = abi.decode(params, (CallbackEnvelope));
        if (premium > envelope.maxPremium) {
            revert FlashLoanPremiumTooHigh(outerCallIndex, premium, envelope.maxPremium);
        }
        _validateCallbackPlan(outerCallIndex, envelope.callbackCalls);
        _executeCallbackPlan(outerCallIndex, envelope.callbackCalls);
        _prepareFlashLoanRepayment(outerCallIndex, asset, amount, premium, msg.sender);
        return true;
    }

    /// @dev Authenticates one callback against the active direct Pool and canonical patched origin.
    ///      Envelope decoding deliberately occurs only after this helper returns.
    /// @param asset ERC20 asset reported by the callback sender.
    /// @param amount Principal amount reported by the callback sender.
    /// @param initiator Initiator reported by the callback sender.
    /// @param params Opaque callback bytes included in canonical origin reconstruction.
    /// @return outerCallIndex Committed outer call index used for later validation and errors.
    function _authenticateAaveV3Callback(address asset, uint256 amount, address initiator, bytes calldata params)
        private
        view
        returns (uint256 outerCallIndex)
    {
        if (!TransientLock.isLocked()) {
            revert CallbackOutsideDynamicExecution();
        }

        outerCallIndex = TransientCallback.callIndex();
        TransientCallback.CallbackState state = TransientCallback.state();
        if (state != TransientCallback.CallbackState.AwaitingCallback) {
            revert CallbackNotAwaiting(outerCallIndex, uint8(state));
        }

        address expectedTarget = TransientCallback.target();
        if (msg.sender != expectedTarget) {
            revert UnexpectedCallbackSender(outerCallIndex, expectedTarget, msg.sender);
        }
        if (initiator != address(this)) {
            revert UnexpectedCallbackInitiator(outerCallIndex, address(this), initiator);
        }

        bytes32 expectedCalldataHash = TransientCallback.calldataHash();
        bytes32 actualCalldataHash = keccak256(
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple, (address(this), asset, amount, params, uint16(0))
            )
        );
        if (actualCalldataHash != expectedCalldataHash) {
            revert CallbackOriginMismatch(outerCallIndex, expectedCalldataHash, actualCalldataHash);
        }
    }

    /// @dev Runs a prevalidated callback plan under a fresh checkpoint invocation scope.
    /// @param outerCallIndex Callback-enabled outer call index used for dual-index errors.
    /// @param callbackCalls Prevalidated ordinary dynamic calls decoded from the envelope.
    function _executeCallbackPlan(uint256 outerCallIndex, DynamicCall[] memory callbackCalls) private {
        TransientCallback.setState(TransientCallback.CallbackState.ExecutingCallback);
        uint256 callbackInvocationId = _allocateInvocationId();
        uint256 callbackCallsLength = callbackCalls.length;
        for (uint256 callbackCallIndex = 0; callbackCallIndex < callbackCallsLength; ++callbackCallIndex) {
            _executeDynamicCall(
                callbackInvocationId, callbackCallIndex, callbackCalls[callbackCallIndex], true, outerCallIndex
            );
        }
    }

    /// @dev Checks principal-plus-premium coverage and installs the exact Pool repayment allowance.
    /// @param outerCallIndex Callback-enabled outer call index used for repayment errors.
    /// @param asset Flash-loaned ERC20 repayment asset.
    /// @param amount Flash-loan principal.
    /// @param premium Pool premium bounded by the decoded envelope.
    /// @param pool Authenticated direct Pool receiving repayment authority.
    function _prepareFlashLoanRepayment(
        uint256 outerCallIndex,
        address asset,
        uint256 amount,
        uint256 premium,
        address pool
    ) private {
        uint256 requiredRepayment = amount + premium;
        (bool balanceReadSuccess, bytes memory balanceReturnData, uint256 assetBalance) = _readBalance(asset);
        if (!balanceReadSuccess || balanceReturnData.length < 32) {
            revert FlashLoanRepaymentBalanceReadFailed(outerCallIndex, asset, balanceReturnData);
        }
        if (assetBalance < requiredRepayment) {
            revert FlashLoanRepaymentBalanceInsufficient(outerCallIndex, asset, assetBalance, requiredRepayment);
        }

        _approveFlashLoanRepayment(outerCallIndex, asset, pool, requiredRepayment);
        TransientCallback.setRepaymentToken(asset);
        TransientCallback.setState(TransientCallback.CallbackState.Consumed);
    }

    /// @dev Prevalidates that an outer batch requests at most one callback window.
    /// @param calls Ordered outer dynamic calls.
    function _validateOuterCallbackCount(DynamicCall[] calldata calls) private pure {
        bool callbackExpected = false;
        uint256 firstCallbackCallIndex = 0;
        uint256 callsLength = calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            if (!calls[i].expectsCallback) {
                continue;
            }
            if (callbackExpected) {
                revert MultipleExpectedCallbacks(firstCallbackCallIndex, i);
            }
            callbackExpected = true;
            firstCallbackCallIndex = i;
        }
    }

    /// @dev Executes one outer or callback-plan call through the shared patch/checkpoint/CALL engine.
    /// @param invocationId Checkpoint namespace retained by the active outer or callback frame.
    /// @param callIndex Index within the active outer or callback call array.
    /// @param dynamicCall Call descriptor copied to memory so decoded callback plans share this path.
    /// @param isCallbackCall Whether failures require dual outer/callback index attribution.
    /// @param outerCallIndex Active outer callback-enabled call index when `isCallbackCall` is true.
    function _executeDynamicCall(
        uint256 invocationId,
        uint256 callIndex,
        DynamicCall memory dynamicCall,
        bool isCallbackCall,
        uint256 outerCallIndex
    ) private {
        address target = dynamicCall.target;
        if (target == address(0) || target == address(this)) {
            revert InvalidTarget(callIndex, target);
        }
        bytes memory data = dynamicCall.data;
        BalanceCache memory cache = _newBalanceCache(dynamicCall.patches.length + dynamicCall.checkpointsBefore.length);
        _applyPatches(invocationId, callIndex, dynamicCall.patches, data, cache);
        _createCheckpoints(invocationId, callIndex, dynamicCall.checkpointsBefore, cache);

        if (dynamicCall.expectsCallback) {
            _openCallbackCommitment(callIndex, target, keccak256(data));
        }

        bool callSucceeded = Exec.call(target, dynamicCall.value, data, gasleft());
        if (!callSucceeded) {
            bytes memory reason = Exec.getReturnData(0);
            if (isCallbackCall) {
                revert CallbackDynamicCallFailed(outerCallIndex, callIndex, target, reason);
            }
            revert DynamicCallFailed(callIndex, target, reason);
        }

        if (dynamicCall.expectsCallback) {
            _finalizeCallbackCommitment(callIndex, target);
        }
    }

    /// @dev Rejects nested callback flags before the first callback-plan target call.
    /// @param outerCallIndex Callback-enabled outer call index.
    /// @param callbackCalls Entire decoded callback plan.
    function _validateCallbackPlan(uint256 outerCallIndex, DynamicCall[] memory callbackCalls) private pure {
        uint256 callbackCallsLength = callbackCalls.length;
        for (uint256 i = 0; i < callbackCallsLength; ++i) {
            if (callbackCalls[i].expectsCallback) {
                revert NestedCallbackNotSupported(outerCallIndex, i);
            }
        }
    }

    /// @dev Requires the lifecycle to be idle, then commits the exact direct target and fully patched
    ///      calldata immediately before its CALL.
    /// @param callIndex Index of the callback-enabled outer call.
    /// @param target Direct target that must later be the callback sender.
    /// @param calldataHash Hash of the fully patched bytes passed to the target.
    function _openCallbackCommitment(uint256 callIndex, address target, bytes32 calldataHash) internal {
        TransientCallback.CallbackState state = TransientCallback.state();
        if (state != TransientCallback.CallbackState.Idle) {
            revert CallbackNotAwaiting(callIndex, uint8(state));
        }

        TransientCallback.store(
            TransientCallback.CallbackState.AwaitingCallback, target, calldataHash, callIndex, address(0)
        );
    }

    /// @dev Requires one consumed callback, proves exact allowance consumption, and clears its commitment.
    /// @param callIndex Index of the callback-enabled outer call.
    /// @param target Committed Pool whose repayment allowance must be zero.
    function _finalizeCallbackCommitment(uint256 callIndex, address target) private {
        TransientCallback.CallbackState state = TransientCallback.state();
        if (state != TransientCallback.CallbackState.Consumed) {
            revert CallbackNotConsumed(callIndex, target, uint8(state));
        }

        address repaymentToken = TransientCallback.repaymentToken();
        (bool allowanceReadSuccess, bytes memory allowanceReturnData, uint256 remainingAllowance) =
            _readAllowance(repaymentToken, target);
        if (!allowanceReadSuccess || allowanceReturnData.length < 32) {
            revert FlashLoanAllowanceReadFailed(callIndex, repaymentToken, target, allowanceReturnData);
        }
        if (remainingAllowance != 0) {
            revert ResidualFlashLoanAllowance(callIndex, repaymentToken, target, remainingAllowance);
        }

        TransientCallback.reset();
    }

    /// @dev Installs an exact repayment allowance with an explicit zero-first sequence.
    /// @param callIndex Index of the callback-enabled outer call.
    /// @param asset Flash asset whose allowance is installed.
    /// @param pool Committed Pool receiving repayment authority.
    /// @param requiredRepayment Exact principal-plus-premium allowance.
    function _approveFlashLoanRepayment(uint256 callIndex, address asset, address pool, uint256 requiredRepayment)
        private
    {
        _callApprove(callIndex, asset, pool, 0);
        if (requiredRepayment != 0) {
            _callApprove(callIndex, asset, pool, requiredRepayment);
        }
    }

    /// @dev Calls `approve` and accepts empty return data or a first ABI word equal to one.
    /// @param callIndex Index of the callback-enabled outer call.
    /// @param asset Flash asset being approved.
    /// @param pool Committed Pool receiving the allowance.
    /// @param allowanceAmount Exact allowance requested by this approval step.
    function _callApprove(uint256 callIndex, address asset, address pool, uint256 allowanceAmount) private {
        (bool approvalSucceeded, bytes memory approvalReturnData) =
            asset.call(abi.encodeCall(IERC20.approve, (pool, allowanceAmount)));

        bool approvalAccepted = approvalReturnData.length == 0;
        if (approvalReturnData.length >= 32) {
            uint256 returnedWord;
            assembly ("memory-safe") {
                returnedWord := mload(add(approvalReturnData, 32))
            }
            approvalAccepted = returnedWord == 1;
        }
        if (!approvalSucceeded || !approvalAccepted) {
            revert FlashLoanRepaymentApprovalFailed(callIndex, asset, pool, approvalReturnData);
        }
    }

    /// @dev Reads the account-to-Pool allowance while preserving raw returndata for indexed errors.
    /// @param asset Flash asset whose allowance is queried.
    /// @param pool Committed Pool whose allowance is queried.
    /// @return success Whether the low-level allowance call succeeded.
    /// @return returnData Complete token returndata.
    /// @return allowanceAmount First returned word when at least 32 bytes are available.
    function _readAllowance(address asset, address pool)
        private
        view
        returns (bool success, bytes memory returnData, uint256 allowanceAmount)
    {
        (success, returnData) = asset.staticcall(abi.encodeCall(IERC20.allowance, (address(this), pool)));
        if (returnData.length >= 32) {
            assembly ("memory-safe") {
                allowanceAmount := mload(add(returnData, 32))
            }
        }
    }

    /// @dev Increments the transaction-scoped transient counter and returns this frame's checkpoint scope.
    ///      EVM revert semantics roll back the allocation together with the containing execution.
    /// @return invocationId Nonzero identifier retained by the active dynamic execution frame.
    function _allocateInvocationId() internal returns (uint256 invocationId) {
        TransientCounter.increment();
        return TransientCounter.counter();
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
        BalancePatch[] memory patches,
        bytes memory data,
        BalanceCache memory cache
    ) internal view {
        uint256 patchesLength = patches.length;
        uint256 previousOffset = 0;

        for (uint256 patchIndex = 0; patchIndex < patchesLength; ++patchIndex) {
            BalancePatch memory patch = patches[patchIndex];
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
        BalancePatch memory patch,
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
        BalancePatch memory patch,
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
        BalanceCheckpoint[] memory checkpoints,
        BalanceCache memory cache
    ) internal {
        uint256 checkpointsLength = checkpoints.length;
        for (uint256 checkpointIndex = 0; checkpointIndex < checkpointsLength; ++checkpointIndex) {
            BalanceCheckpoint memory checkpoint = checkpoints[checkpointIndex];
            address token = checkpoint.token;
            if (token == address(0)) {
                revert InvalidCheckpointToken(callIndex, checkpointIndex);
            }

            bytes32 checkpointId = checkpoint.id;
            if (checkpointId == bytes32(0)) {
                revert InvalidCheckpointId(callIndex, checkpointIndex);
            }

            bytes32 recordRoot = _recordRoot(invocationId, checkpointId);
            if (recordRoot.isPresent()) {
                revert CheckpointAlreadyExists(callIndex, checkpointIndex, checkpointId);
            }

            uint256 balance = _currentBalanceForCheckpoint(callIndex, checkpointIndex, token, cache);
            recordRoot.store(token, balance);
        }
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
        bytes32 recordRoot = _recordRoot(invocationId, checkpointId);
        if (!recordRoot.isPresent()) {
            revert CheckpointNotFound(callIndex, patchIndex, checkpointId);
        }

        address checkpointToken = recordRoot.token();
        if (checkpointToken != token) {
            revert CheckpointTokenMismatch(callIndex, patchIndex, checkpointId, token, checkpointToken);
        }

        return recordRoot.balance();
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

    function _recordRoot(uint256 invocationId, bytes32 checkpointId) internal pure returns (bytes32 recordRoot) {
        return _CHECKPOINT_TABLE_SLOT.deriveMapping(invocationId).deriveMapping(checkpointId);
    }

    /// @inheritdoc Simple7702Account
    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return id == type(IDefiSimplify7702Account).interfaceId || super.supportsInterface(id);
    }
}
