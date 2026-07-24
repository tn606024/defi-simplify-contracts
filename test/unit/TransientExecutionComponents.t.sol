// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TransientCallbackCommitment} from "../../src/libraries/TransientCallbackCommitment.sol";
import {TransientDynamicExecutionLock} from "../../src/libraries/TransientDynamicExecutionLock.sol";
import {TransientInvocationCounter} from "../../src/libraries/TransientInvocationCounter.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

contract TransientExecutionComponentsHarness {
    using TransientSlot for *;

    function dynamicExecutionIsLocked() external view returns (bool) {
        return TransientDynamicExecutionLock.isLocked();
    }

    function enterDynamicExecutionLock() external {
        TransientDynamicExecutionLock.lock();
    }

    function leaveDynamicExecutionLock() external {
        TransientDynamicExecutionLock.unlock();
    }

    function currentInvocationId() external view returns (uint256) {
        return TransientInvocationCounter.current();
    }

    function allocateInvocationId() external returns (uint256) {
        return TransientInvocationCounter.increment();
    }

    function seedInvocationCounter(uint256 value) external {
        TransientInvocationCounter.slot().asUint256().tstore(value);
    }

    function callbackCommitment()
        external
        view
        returns (
            TransientCallbackCommitment.CallbackState state,
            address target,
            bytes32 calldataHash,
            uint256 callIndex,
            address repaymentToken
        )
    {
        return (
            TransientCallbackCommitment.state(),
            TransientCallbackCommitment.target(),
            TransientCallbackCommitment.calldataHash(),
            TransientCallbackCommitment.callIndex(),
            TransientCallbackCommitment.repaymentToken()
        );
    }

    function storeCallbackFields(address target, bytes32 calldataHash, uint256 callIndex) external {
        TransientCallbackCommitment.storeFields(target, calldataHash, callIndex, address(0));
    }

    function setCallbackState(TransientCallbackCommitment.CallbackState state) external {
        TransientCallbackCommitment.setState(state);
    }

    function setCallbackRepaymentToken(address repaymentToken) external {
        TransientCallbackCommitment.setRepaymentToken(repaymentToken);
    }

    function resetCallbackCommitment() external {
        TransientCallbackCommitment.reset();
    }
}

contract TransientExecutionComponentsTest is Test {
    address private constant CALLBACK_TARGET = address(0xA11CE);
    address private constant REPAYMENT_TOKEN = address(0xB0B);
    bytes32 private constant PATCHED_CALLDATA_HASH = keccak256("patched flash-loan calldata");
    uint256 private constant CALLBACK_CALL_INDEX = 4;

    TransientExecutionComponentsHarness private executionComponents;

    function setUp() external {
        executionComponents = new TransientExecutionComponentsHarness();
    }

    function test_DynamicExecutionLock_EntersAndLeavesTheSameTransientSlot() external {
        assertFalse(executionComponents.dynamicExecutionIsLocked(), "initial lock state");

        executionComponents.enterDynamicExecutionLock();
        assertTrue(executionComponents.dynamicExecutionIsLocked(), "entered lock state");

        executionComponents.leaveDynamicExecutionLock();
        assertFalse(executionComponents.dynamicExecutionIsLocked(), "released lock state");
    }

    function test_InvocationCounter_AllocatesSequentialNonzeroIds() external {
        assertEq(executionComponents.currentInvocationId(), 0, "initial invocation counter");
        assertEq(executionComponents.allocateInvocationId(), 1, "first invocation id");
        assertEq(executionComponents.allocateInvocationId(), 2, "second invocation id");
        assertEq(executionComponents.currentInvocationId(), 2, "stored invocation counter");
    }

    function test_InvocationCounter_WhenAtUint256Maximum_RevertsInsteadOfWrappingToZero() external {
        executionComponents.seedInvocationCounter(type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        executionComponents.allocateInvocationId();

        assertEq(executionComponents.currentInvocationId(), type(uint256).max, "counter after failed allocation");
    }

    function test_CallbackStateOrdinals_RemainFrozenForIndexedErrorAttribution() external pure {
        assertEq(uint256(TransientCallbackCommitment.CallbackState.Idle), 0, "Idle ordinal");
        assertEq(uint256(TransientCallbackCommitment.CallbackState.AwaitingCallback), 1, "AwaitingCallback ordinal");
        assertEq(uint256(TransientCallbackCommitment.CallbackState.ExecutingCallback), 2, "ExecutingCallback ordinal");
        assertEq(uint256(TransientCallbackCommitment.CallbackState.Consumed), 3, "Consumed ordinal");
    }

    function test_CallbackCommitment_FieldsRemainUnpublishedUntilStateIsSet() external {
        executionComponents.storeCallbackFields(CALLBACK_TARGET, PATCHED_CALLDATA_HASH, CALLBACK_CALL_INDEX);

        (
            TransientCallbackCommitment.CallbackState state,
            address target,
            bytes32 calldataHash,
            uint256 callIndex,
            address repaymentToken
        ) = executionComponents.callbackCommitment();

        assertEq(uint256(state), uint256(TransientCallbackCommitment.CallbackState.Idle), "unpublished state");
        assertEq(target, CALLBACK_TARGET, "stored callback target");
        assertEq(calldataHash, PATCHED_CALLDATA_HASH, "stored calldata hash");
        assertEq(callIndex, CALLBACK_CALL_INDEX, "stored outer call index");
        assertEq(repaymentToken, address(0), "initial repayment token");
    }

    function test_CallbackCommitment_ResetClearsEveryFieldAndReturnsToIdle() external {
        executionComponents.storeCallbackFields(CALLBACK_TARGET, PATCHED_CALLDATA_HASH, CALLBACK_CALL_INDEX);
        executionComponents.setCallbackState(TransientCallbackCommitment.CallbackState.AwaitingCallback);
        executionComponents.setCallbackRepaymentToken(REPAYMENT_TOKEN);
        executionComponents.setCallbackState(TransientCallbackCommitment.CallbackState.Consumed);

        executionComponents.resetCallbackCommitment();

        (
            TransientCallbackCommitment.CallbackState state,
            address target,
            bytes32 calldataHash,
            uint256 callIndex,
            address repaymentToken
        ) = executionComponents.callbackCommitment();

        assertEq(uint256(state), uint256(TransientCallbackCommitment.CallbackState.Idle), "reset state");
        assertEq(target, address(0), "reset callback target");
        assertEq(calldataHash, bytes32(0), "reset calldata hash");
        assertEq(callIndex, 0, "reset outer call index");
        assertEq(repaymentToken, address(0), "reset repayment token");
    }
}
