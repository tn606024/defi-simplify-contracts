// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Exec} from "@account-abstraction/contracts/utils/Exec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    bytes32 internal constant _DYNAMIC_EXECUTION_LOCK_SLOT =
        keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");
    bytes32 internal constant _DYNAMIC_INVOCATION_COUNTER_SLOT =
        keccak256("DefiSimplify7702Account.dynamicInvocationCounter.v1");
    bytes32 internal constant _CHECKPOINT_TABLE_NAMESPACE = keccak256("DefiSimplify7702Account.checkpointTable.v1");

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

            // IAN-49 resolves patches into this memory copy before same-call
            // checkpoints are created, without changing the frozen ABI.
            bytes memory data = dynamicCall.data;
            _createCheckpoints(invocationId, i, dynamicCall.checkpointsBefore);

            bool success = Exec.call(target, dynamicCall.value, data, gasleft());
            if (!success) {
                revert DynamicCallFailed(i, target, Exec.getReturnData(0));
            }
        }

        lockSlot.tstore(false);
    }

    function _allocateInvocationId() internal returns (uint256 invocationId) {
        TransientSlot.Uint256Slot counterSlot = _DYNAMIC_INVOCATION_COUNTER_SLOT.asUint256();
        invocationId = counterSlot.tload() + 1;
        counterSlot.tstore(invocationId);
    }

    function _createCheckpoints(uint256 invocationId, uint256 callIndex, BalanceCheckpoint[] calldata checkpoints)
        internal
    {
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

            uint256 balance = _readCheckpointBalance(callIndex, checkpointIndex, token);
            presenceSlot.tstore(true);
            tokenSlot.tstore(token);
            balanceSlot.tstore(balance);
        }
    }

    function _checkpointRecordRoot(uint256 invocationId, bytes32 checkpointId) internal pure returns (bytes32) {
        return _CHECKPOINT_TABLE_NAMESPACE.deriveMapping(invocationId).deriveMapping(checkpointId);
    }

    function _readCheckpointBalance(uint256 callIndex, uint256 checkpointIndex, address token)
        internal
        view
        returns (uint256 tokenBalance)
    {
        (bool success, bytes memory returnData) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!success || returnData.length < 32) {
            revert CheckpointBalanceReadFailed(callIndex, checkpointIndex, token, returnData);
        }

        assembly ("memory-safe") {
            tokenBalance := mload(add(returnData, 32))
        }
    }

    /// @inheritdoc Simple7702Account
    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return id == type(IDefiSimplify7702Account).interfaceId || super.supportsInterface(id);
    }
}
