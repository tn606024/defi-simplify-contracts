// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";

/// @dev Canonical test-only constructors for the generic dynamic-execution ABI.
///
/// Protocol fixtures retain ownership of strategy order, asset roles, callback
/// semantics, and safety bounds. This library only removes repeated mechanical
/// allocation and struct construction from those reviewer-facing fixtures.
library DynamicCallTestBuilder {
    uint16 internal constant FULL_BALANCE_BPS = 10_000;

    /// @dev Constructs a DynamicCall with every ABI field supplied explicitly.
    function buildCall(
        address callTarget,
        uint256 callValue,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpointsBefore,
        IDefiSimplify7702Account.BalancePatch[] memory patches,
        bool expectsCallback
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall = IDefiSimplify7702Account.DynamicCall({
                target: callTarget,
                value: callValue,
                data: callData,
                checkpointsBefore: checkpointsBefore,
                patches: patches,
                expectsCallback: expectsCallback
            });
    }

    /// @dev Constructs a callback-free call with no checkpoints or patches.
    function buildOrdinaryCall(address callTarget, uint256 callValue, bytes memory callData)
        internal
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return buildCall(callTarget, callValue, callData, noCheckpoints(), noPatches(), false);
    }

    /// @dev Constructs a zero-value DynamicCall while retaining explicit callback and balance metadata.
    function buildZeroValueCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpointsBefore,
        IDefiSimplify7702Account.BalancePatch[] memory patches,
        bool expectsCallback
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory) {
        return buildCall(callTarget, 0, callData, checkpointsBefore, patches, expectsCallback);
    }

    /// @dev Constructs a callback-free zero-value call with no checkpoints or patches.
    function buildZeroValueOrdinaryCall(address callTarget, bytes memory callData)
        internal
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return buildOrdinaryCall(callTarget, 0, callData);
    }

    /// @dev Constructs a callback-free zero-value call with explicit balance metadata.
    function buildZeroValueBalanceAwareCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpointsBefore,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory) {
        return buildZeroValueCall(callTarget, callData, checkpointsBefore, patches, false);
    }

    /// @dev Constructs a callback-free zero-value call that only creates checkpoints.
    function buildZeroValueCheckpointingCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpointsBefore
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory) {
        return buildZeroValueBalanceAwareCall(callTarget, callData, checkpointsBefore, noPatches());
    }

    /// @dev Constructs a callback-free zero-value call that consumes one explicit patch.
    function buildZeroValueSinglePatchCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalancePatch memory patch
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory) {
        return buildZeroValueBalanceAwareCall(callTarget, callData, noCheckpoints(), singlePatch(patch));
    }

    /// @dev Constructs an empty dynamic-call list for an intentionally empty callback plan.
    function noCalls() internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        calls = new IDefiSimplify7702Account.DynamicCall[](0);
    }

    /// @dev Wraps one explicit DynamicCall into a one-call plan.
    function singleCall(IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        internal
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;
    }

    /// @dev Constructs an empty checkpoint list without hiding protocol semantics.
    function noCheckpoints() internal pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    /// @dev Wraps one explicit checkpoint for a call that creates one baseline.
    function singleCheckpoint(address checkpointToken, bytes32 checkpointId)
        internal
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = checkpoint(checkpointToken, checkpointId);
    }

    /// @dev Constructs one explicit balance-checkpoint descriptor.
    function checkpoint(address checkpointToken, bytes32 checkpointId)
        internal
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint memory)
    {
        return IDefiSimplify7702Account.BalanceCheckpoint({token: checkpointToken, id: checkpointId});
    }

    /// @dev Constructs an empty patch list without hiding protocol semantics.
    function noPatches() internal pure returns (IDefiSimplify7702Account.BalancePatch[] memory patches) {
        patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    /// @dev Wraps one explicit patch for a call that consumes one balance source.
    function singlePatch(IDefiSimplify7702Account.BalancePatch memory patch)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch[] memory patches)
    {
        patches = new IDefiSimplify7702Account.BalancePatch[](1);
        patches[0] = patch;
    }

    /// @dev Constructs a CurrentBalance patch with an explicit allocation BPS.
    function currentBalancePatch(address balanceToken, uint32 calldataOffset, uint16 bps)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory patch)
    {
        patch = IDefiSimplify7702Account.BalancePatch({
            token: balanceToken,
            checkpointId: bytes32(0),
            offset: calldataOffset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    /// @dev Constructs a CurrentBalance patch that intentionally uses 100% of the current balance.
    function fullCurrentBalancePatch(address balanceToken, uint32 calldataOffset)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return currentBalancePatch(balanceToken, calldataOffset, FULL_BALANCE_BPS);
    }

    /// @dev Constructs a CheckpointDelta patch with an explicit allocation BPS.
    function checkpointDeltaPatch(address balanceToken, bytes32 checkpointId, uint32 calldataOffset, uint16 bps)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory patch)
    {
        patch = IDefiSimplify7702Account.BalancePatch({
            token: balanceToken,
            checkpointId: checkpointId,
            offset: calldataOffset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
    }

    /// @dev Constructs a CheckpointDelta patch that intentionally uses 100% of the observed delta.
    function fullCheckpointDeltaPatch(address balanceToken, bytes32 checkpointId, uint32 calldataOffset)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return checkpointDeltaPatch(balanceToken, checkpointId, calldataOffset, FULL_BALANCE_BPS);
    }
}
