// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title TransientCallbackCommitment
/// @notice Physical transient record for one authenticated DeFi Simplify callback commitment.
/// @dev The ERC-7201-derived root owns five adjacent fields:
///      offset 0 = state, offset 1 = target, offset 2 = calldata hash,
///      offset 3 = outer call index, and offset 4 = repayment token.
///      The library owns layout and typed access only. The account owns valid state transitions,
///      callback authorization, error policy, and Aave-specific repayment behavior.
library TransientCallbackCommitment {
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    // keccak256(abi.encode(uint256(keccak256(
    //     "DefiSimplify7702Account.transient.callbackCommitment.v1"
    // )) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _COMMITMENT_ROOT = 0xb2c22bae38e6ca5557b6a5ff8d9d659718a979e1a4ae76ee038af18f20a7f500;

    uint256 private constant _STATE_OFFSET = 0;
    uint256 private constant _TARGET_OFFSET = 1;
    uint256 private constant _CALLDATA_HASH_OFFSET = 2;
    uint256 private constant _CALL_INDEX_OFFSET = 3;
    uint256 private constant _REPAYMENT_TOKEN_OFFSET = 4;

    /// @dev Single-use callback lifecycle shared by the outer executor and Aave receiver.
    ///      Ordinals are frozen as Idle=0, AwaitingCallback=1, ExecutingCallback=2, Consumed=3
    ///      because indexed callback errors expose the raw state as `uint8`.
    enum CallbackState {
        Idle,
        AwaitingCallback,
        ExecutingCallback,
        Consumed
    }

    /// @notice Returns the frozen callback commitment root for independent layout verification.
    /// @return commitmentRoot ERC-7201-derived root at record offset zero.
    function root() internal pure returns (bytes32 commitmentRoot) {
        return _COMMITMENT_ROOT;
    }

    /// @notice Returns the current callback lifecycle state.
    /// @return currentState State stored at commitment offset zero.
    function state() internal view returns (CallbackState currentState) {
        return CallbackState(_COMMITMENT_ROOT.offset(_STATE_OFFSET).asUint256().tload());
    }

    /// @notice Stores one account-validated callback lifecycle transition.
    /// @param newState State selected by the account's transition policy.
    function setState(CallbackState newState) internal {
        _COMMITMENT_ROOT.offset(_STATE_OFFSET).asUint256().tstore(uint256(newState));
    }

    /// @notice Returns the direct outer target permitted to call back.
    /// @return committedTarget Address stored at commitment offset one.
    function target() internal view returns (address committedTarget) {
        return _COMMITMENT_ROOT.offset(_TARGET_OFFSET).asAddress().tload();
    }

    /// @notice Returns the hash of the fully patched outer calldata.
    /// @return committedCalldataHash Hash stored at commitment offset two.
    function calldataHash() internal view returns (bytes32 committedCalldataHash) {
        return _COMMITMENT_ROOT.offset(_CALLDATA_HASH_OFFSET).asBytes32().tload();
    }

    /// @notice Returns the callback-enabled outer call index.
    /// @return committedCallIndex Index stored at commitment offset three.
    function callIndex() internal view returns (uint256 committedCallIndex) {
        return _COMMITMENT_ROOT.offset(_CALL_INDEX_OFFSET).asUint256().tload();
    }

    /// @notice Returns the flash asset used for post-call allowance verification.
    /// @return committedRepaymentToken Token stored at commitment offset four.
    function repaymentToken() internal view returns (address committedRepaymentToken) {
        return _COMMITMENT_ROOT.offset(_REPAYMENT_TOKEN_OFFSET).asAddress().tload();
    }

    /// @notice Stores all callback commitment fields except lifecycle state.
    /// @dev The account publishes `AwaitingCallback` only after this function returns, so a
    ///      published commitment always has complete target, hash, index, and repayment fields.
    /// @param newTarget Direct outer target expected to call back.
    /// @param newCalldataHash Hash of fully patched calldata sent to `newTarget`.
    /// @param newCallIndex Index of the callback-enabled outer call.
    /// @param newRepaymentToken Initial repayment token, normally zero until callback completion.
    function storeFields(address newTarget, bytes32 newCalldataHash, uint256 newCallIndex, address newRepaymentToken)
        internal
    {
        _COMMITMENT_ROOT.offset(_TARGET_OFFSET).asAddress().tstore(newTarget);
        _COMMITMENT_ROOT.offset(_CALLDATA_HASH_OFFSET).asBytes32().tstore(newCalldataHash);
        _COMMITMENT_ROOT.offset(_CALL_INDEX_OFFSET).asUint256().tstore(newCallIndex);
        _COMMITMENT_ROOT.offset(_REPAYMENT_TOKEN_OFFSET).asAddress().tstore(newRepaymentToken);
    }

    /// @notice Stores the repayment token before the account publishes `Consumed`.
    /// @param newRepaymentToken Flash asset approved for exact repayment.
    function setRepaymentToken(address newRepaymentToken) internal {
        _COMMITMENT_ROOT.offset(_REPAYMENT_TOKEN_OFFSET).asAddress().tstore(newRepaymentToken);
    }

    /// @notice Clears all commitment fields and returns the lifecycle to `Idle`.
    /// @dev Data fields are cleared before `Idle` is published. No external call occurs between writes.
    function reset() internal {
        _COMMITMENT_ROOT.offset(_TARGET_OFFSET).asAddress().tstore(address(0));
        _COMMITMENT_ROOT.offset(_CALLDATA_HASH_OFFSET).asBytes32().tstore(bytes32(0));
        _COMMITMENT_ROOT.offset(_CALL_INDEX_OFFSET).asUint256().tstore(0);
        _COMMITMENT_ROOT.offset(_REPAYMENT_TOKEN_OFFSET).asAddress().tstore(address(0));
        setState(CallbackState.Idle);
    }
}
