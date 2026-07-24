// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

library TransientCallback {
    using SlotDerivation for bytes32;

    // keccak256("DefiSimplify7702Account.transientCallback");
    bytes32 internal constant _TRANSIENT_CALLBACK_SLOT =
        0x913b242caca8be0a556cae73d64400cb5ea37c718456bfa10a7a900b903642a9;
    uint256 internal constant _CALLBACK_STATE_OFFSET = 0;
    uint256 internal constant _CALLBACK_TARGET_OFFSET = 1;
    uint256 internal constant _CALLBACK_CALLDATA_HASH_OFFSET = 2;
    uint256 internal constant _CALLBACK_CALL_INDEX_OFFSET = 3;
    uint256 internal constant _CALLBACK_REPAYMENT_TOKEN_OFFSET = 4;

    /// @dev Single-use callback lifecycle shared by the outer executor and Aave receiver.
    enum CallbackState {
        Idle,
        AwaitingCallback,
        ExecutingCallback,
        Consumed
    }

    function state() internal view returns (CallbackState storeState) {
        bytes32 stateSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_STATE_OFFSET);
        assembly ("memory-safe") {
            storeState := tload(stateSlot)
        }
        return storeState;
    }

    function setState(CallbackState newState) internal {
        bytes32 stateSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_STATE_OFFSET);
        assembly ("memory-safe") {
            tstore(stateSlot, newState)
        }
    }

    function target() internal view returns (address storeTarget) {
        bytes32 targetSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_TARGET_OFFSET);
        assembly ("memory-safe") {
            storeTarget := tload(targetSlot)
        }
        return storeTarget;
    }

    function setTarget(address newTarget) internal {
        bytes32 targetSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_TARGET_OFFSET);
        assembly ("memory-safe") {
            tstore(targetSlot, newTarget)
        }
    }

    function calldataHash() internal view returns (bytes32 storeCalldataHash) {
        bytes32 calldataHashSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALLDATA_HASH_OFFSET);
        assembly ("memory-safe") {
            storeCalldataHash := tload(calldataHashSlot)
        }
        return storeCalldataHash;
    }

    function setCalldataHash(bytes32 newCalldataHash) internal {
        bytes32 calldataHashSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALLDATA_HASH_OFFSET);
        assembly ("memory-safe") {
            tstore(calldataHashSlot, newCalldataHash)
        }
    }

    function callIndex() internal view returns (uint256 storeCallIndex) {
        bytes32 callIndexSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALL_INDEX_OFFSET);
        assembly ("memory-safe") {
            storeCallIndex := tload(callIndexSlot)
        }
        return storeCallIndex;
    }

    function setCallIndex(uint256 newCallIndex) internal {
        bytes32 callIndexSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALL_INDEX_OFFSET);
        assembly ("memory-safe") {
            tstore(callIndexSlot, newCallIndex)
        }
    }

    function repaymentToken() internal view returns (address storeRepaymentToken) {
        bytes32 repaymentTokenSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_REPAYMENT_TOKEN_OFFSET);
        assembly ("memory-safe") {
            storeRepaymentToken := tload(repaymentTokenSlot)
        }
        return storeRepaymentToken;
    }

    function setRepaymentToken(address newRepaymentToken) internal {
        bytes32 repaymentTokenSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_REPAYMENT_TOKEN_OFFSET);
        assembly ("memory-safe") {
            tstore(repaymentTokenSlot, newRepaymentToken)
        }
    }

    function reset() internal {
        bytes32 stateSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_STATE_OFFSET);
        bytes32 targetSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_TARGET_OFFSET);
        bytes32 calldataHashSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALLDATA_HASH_OFFSET);
        bytes32 callIndexSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALL_INDEX_OFFSET);
        bytes32 repaymentTokenSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_REPAYMENT_TOKEN_OFFSET);

        CallbackState idleState = CallbackState.Idle;

        assembly ("memory-safe") {
            tstore(stateSlot, idleState)
            tstore(targetSlot, 0)
            tstore(calldataHashSlot, 0)
            tstore(callIndexSlot, 0)
            tstore(repaymentTokenSlot, 0)
        }
    }

    function store(
        CallbackState newState,
        address newTarget,
        bytes32 newCalldataHash,
        uint256 newCallIndex,
        address newRepaymentToken
    ) internal {
        bytes32 stateSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_STATE_OFFSET);
        bytes32 targetSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_TARGET_OFFSET);
        bytes32 calldataHashSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALLDATA_HASH_OFFSET);
        bytes32 callIndexSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_CALL_INDEX_OFFSET);
        bytes32 repaymentTokenSlot = _TRANSIENT_CALLBACK_SLOT.offset(_CALLBACK_REPAYMENT_TOKEN_OFFSET);
        assembly ("memory-safe") {
            tstore(stateSlot, newState)
            tstore(targetSlot, newTarget)
            tstore(calldataHashSlot, newCalldataHash)
            tstore(callIndexSlot, newCallIndex)
            tstore(repaymentTokenSlot, newRepaymentToken)
        }
    }
}
