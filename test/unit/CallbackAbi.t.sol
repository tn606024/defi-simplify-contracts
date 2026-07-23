// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Proves the final callback-enabled ABI and DSC-78's fail-closed transition.
contract CallbackAbiTest is DelegatedAccountFixture {
    bytes4 private constant HISTORICAL_EXECUTE_BATCH_DYNAMIC_SELECTOR = 0x146c3297;
    bytes4 private constant CALLBACK_ENABLED_EXECUTE_BATCH_DYNAMIC_SELECTOR = 0xecadebe3;

    struct HistoricalDynamicCall {
        address target;
        uint256 value;
        bytes data;
        IDefiSimplify7702Account.BalanceCheckpoint[] checkpointsBefore;
        IDefiSimplify7702Account.BalancePatch[] patches;
    }

    DelegatedDefiSimplifyAccount private accountUnderTest;
    DynamicExecutionTarget private recordingTarget;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        recordingTarget = new DynamicExecutionTarget();
    }

    function test_OrdinaryCallsRemainExecutableWhenEveryCallbackFlagIsFalse() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildThreeRecordingCalls();

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 3, "every ordinary target should execute");
        assertEq(recordingTarget.total(), 60, "ordinary calls should preserve order and values");
    }

    function test_CallbackFlagAtFirstIndexFailsBeforeAnyTargetExecutes() external {
        _assertSingleCallbackFlagFailsBeforeAnyTarget(0);
    }

    function test_CallbackFlagAtMiddleIndexFailsBeforeAnyTargetExecutes() external {
        _assertSingleCallbackFlagFailsBeforeAnyTarget(1);
    }

    function test_CallbackFlagAtLastIndexFailsBeforeAnyTargetExecutes() external {
        _assertSingleCallbackFlagFailsBeforeAnyTarget(2);
    }

    function test_MultipleCallbackFlagsReportBothIndicesBeforeAnyTargetExecutes() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildThreeRecordingCalls();
        calls[0].expectsCallback = true;
        calls[2].expectsCallback = true;

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.MultipleExpectedCallbacks.selector, 0, 2));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "prevalidation should run before the first target");
    }

    function test_DirectExecuteOperationFailsBeforeMalformedParamsAreDecoded() external {
        bytes memory malformedEnvelope = hex"deadbeef";

        vm.expectRevert(IDefiSimplify7702Account.CallbackOutsideDynamicExecution.selector);
        vm.prank(address(0xBADCA11));
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeOperation(address(0xA55E7), 100 ether, 1 ether, accountUnderTest.delegatedEoa, malformedEnvelope);

        assertEq(recordingTarget.count(), 0, "direct callback must not execute plan data");
    }

    function test_FinalSelectorRejectsHistoricalTupleWithoutCallbackFlag() external {
        HistoricalDynamicCall[] memory historicalCalls = _buildHistoricalCalls();
        bytes memory malformedFinalCalldata =
            bytes.concat(CALLBACK_ENABLED_EXECUTE_BATCH_DYNAMIC_SELECTOR, abi.encode(historicalCalls));

        vm.prank(accountUnderTest.delegatedEoa);
        (bool success,) = accountUnderTest.delegatedEoa.call(malformedFinalCalldata);

        assertFalse(success, "final selector must reject a tuple missing expectsCallback");
        assertEq(recordingTarget.count(), 0, "malformed final calldata must not reach its target");
    }

    function test_HistoricalSelectorUsesInheritedInertFallbackInsteadOfLegacyExecution() external {
        HistoricalDynamicCall[] memory historicalCalls = _buildHistoricalCalls();
        bytes memory historicalCalldata =
            bytes.concat(HISTORICAL_EXECUTE_BATCH_DYNAMIC_SELECTOR, abi.encode(historicalCalls));

        vm.prank(accountUnderTest.delegatedEoa);
        (bool success, bytes memory returnData) = accountUnderTest.delegatedEoa.call(historicalCalldata);

        assertTrue(success, "upstream EOA-style fallback should accept unknown historical selector");
        assertEq(returnData.length, 0, "inert fallback should return no data");
        assertEq(recordingTarget.count(), 0, "historical selector must not execute a dynamic batch");
    }

    function test_CallbackEnvelopeEncodingCanRepresentZeroOneAndManyCalls() external pure {
        IDefiSimplify7702Account.CallbackEnvelope memory emptyEnvelope;
        emptyEnvelope.maxPremium = 1;
        emptyEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](0);

        IDefiSimplify7702Account.CallbackEnvelope memory oneCallEnvelope;
        oneCallEnvelope.maxPremium = 2;
        oneCallEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        oneCallEnvelope.callbackCalls[0] = _buildCall(address(0x1111), 11, false);

        IDefiSimplify7702Account.CallbackEnvelope memory manyCallEnvelope;
        manyCallEnvelope.maxPremium = 3;
        manyCallEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        manyCallEnvelope.callbackCalls[0] = _buildCall(address(0x2222), 22, false);
        manyCallEnvelope.callbackCalls[1] = _buildCall(address(0x3333), 33, true);

        assertEq(abi.decode(abi.encode(emptyEnvelope), (IDefiSimplify7702Account.CallbackEnvelope)).maxPremium, 1);
        assertEq(
            abi.decode(abi.encode(oneCallEnvelope), (IDefiSimplify7702Account.CallbackEnvelope)).callbackCalls.length, 1
        );
        IDefiSimplify7702Account.CallbackEnvelope memory decodedMany =
            abi.decode(abi.encode(manyCallEnvelope), (IDefiSimplify7702Account.CallbackEnvelope));
        assertEq(decodedMany.callbackCalls.length, 2);
        assertTrue(decodedMany.callbackCalls[1].expectsCallback, "nested callback flag must remain ABI-visible");
    }

    function _assertSingleCallbackFlagFailsBeforeAnyTarget(uint256 callbackCallIndex) private {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildThreeRecordingCalls();
        calls[callbackCallIndex].expectsCallback = true;

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CallbackNotConsumed.selector,
                callbackCallIndex,
                address(recordingTarget),
                uint8(0)
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "callback transition must fail before every target");
    }

    function _buildThreeRecordingCalls() private view returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _buildCall(address(recordingTarget), 10, false);
        calls[1] = _buildCall(address(recordingTarget), 20, false);
        calls[2] = _buildCall(address(recordingTarget), 30, false);
    }

    function _buildHistoricalCalls() private view returns (HistoricalDynamicCall[] memory calls) {
        calls = new HistoricalDynamicCall[](1);
        calls[0].target = address(recordingTarget);
        calls[0].data = abi.encodeCall(DynamicExecutionTarget.record, (99, bytes("historical")));
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _buildCall(address target, uint256 amount, bool expectsCallback)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = target;
        dynamicCall.data = abi.encodeCall(DynamicExecutionTarget.record, (amount, bytes("callback-abi")));
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
        dynamicCall.expectsCallback = expectsCallback;
    }
}
