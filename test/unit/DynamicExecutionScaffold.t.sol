// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Vm} from "forge-std/Vm.sol";
import {DynamicExecutionAdversary} from "../mocks/DynamicExecutionAdversary.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract DynamicExecutionScaffoldTest is DelegatedAccountFixture {
    uint256 private constant REENTRANT_ACCOUNT_AUTHORITY_KEY = 0xD1A1;
    uint256 private constant RETURNDATA_BOMB_SIZE = 2 * 1024 * 1024;
    uint256 private constant RETURNDATA_BOMB_GAS = 30_000_000;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    DynamicExecutionTarget private recordingTarget;
    DynamicExecutionAdversary private adversarialTarget;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        recordingTarget = new DynamicExecutionTarget();
        adversarialTarget = new DynamicExecutionAdversary();
        vm.deal(accountUnderTest.delegatedEoa, 10 ether);
    }

    function test_DynamicInterfaceId_EqualsSingleEntrypointSelector_AndOnlyDefiSimplifyAccountSupportsIt() external {
        DelegatedUpstreamAccount memory upstreamAccount = _deployDelegatedUpstreamAccount(IEntryPoint(address(this)));

        assertEq(
            bytes32(type(IDefiSimplify7702Account).interfaceId),
            bytes32(IDefiSimplify7702Account.executeBatchDynamic.selector),
            "unexpected dynamic interface id"
        );
        assertTrue(IERC165(accountUnderTest.delegatedEoa).supportsInterface(type(IDefiSimplify7702Account).interfaceId));
        assertFalse(IERC165(upstreamAccount.delegatedEoa).supportsInterface(type(IDefiSimplify7702Account).interfaceId));
    }

    function test_BalanceSourceOrdinalsAreFrozen() external pure {
        assertEq(uint256(IDefiSimplify7702Account.BalanceSource.CurrentBalance), 0, "CurrentBalance ordinal");
        assertEq(uint256(IDefiSimplify7702Account.BalanceSource.CheckpointDelta), 1, "CheckpointDelta ordinal");
    }

    function test_ConfiguredEntryPointCanExecuteOneAndManyCallsWithValue() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(11, 0.25 ether, "one");
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(13, 0, "many-a");
        calls[1] = _buildRecordingCall(17, 0.5 ether, "many-b");
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.lastCaller(), accountUnderTest.delegatedEoa, "target caller");
        assertEq(recordingTarget.count(), 3, "target call count");
        assertEq(recordingTarget.total(), 41, "target total");
        assertEq(recordingTarget.totalCallValue(), 0.75 ether, "target call value");
        assertEq(recordingTarget.lastPayloadHash(), keccak256("many-b"), "target call order");
    }

    function test_DelegatedAccountSelfCanExecuteDynamicBatch() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(23, 0, "self");

        vm.prank(accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.lastCaller(), accountUnderTest.delegatedEoa, "self path target caller");
        assertEq(recordingTarget.total(), 23, "self path target total");
    }

    function test_RandomCallerFailsAuthorizationBeforeEmptyBatchValidation() external {
        address randomCaller = address(0xCA11E2);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, accountUnderTest.delegatedEoa, address(this)
            )
        );
        vm.prank(randomCaller);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackFailsAuthorizationBeforeReadingActiveDynamicLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.callAccountDynamic, (accountUnderTest.delegatedEoa))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector,
            address(recordingTarget),
            accountUnderTest.delegatedEoa,
            address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(recordingTarget), authorizationReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackCannotEnterInheritedExecute() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(adversarialTarget),
            abi.encodeCall(DynamicExecutionAdversary.callAccountExecute, (accountUnderTest.delegatedEoa))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector,
            address(adversarialTarget),
            accountUnderTest.delegatedEoa,
            address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(adversarialTarget), authorizationReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackCannotEnterInheritedExecuteBatch() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(adversarialTarget),
            abi.encodeCall(DynamicExecutionAdversary.callAccountExecuteBatch, (accountUnderTest.delegatedEoa))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector,
            address(adversarialTarget),
            accountUnderTest.delegatedEoa,
            address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(adversarialTarget), authorizationReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_EmptyBatchReverts() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](0);

        vm.expectRevert(IDefiSimplify7702Account.EmptyDynamicBatch.selector);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_ZeroTargetRevertsWithCallIndex() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(29, 0, "rolled-back");
        calls[1] = _buildUnpatchedDynamicCall(address(0), "");

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 1, address(0)));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "earlier target state should roll back");
    }

    function test_SelfTargetRevertsWithCallIndex() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(accountUnderTest.delegatedEoa, "");

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 0, accountUnderTest.delegatedEoa)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_FailedCallWrapsIndexTargetAndCompleteReason() external {
        bytes memory payload = bytes("complete-nested-revert-data");
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 31, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(37, 0, "rolled-back");
        calls[1] = _buildUnpatchedDynamicCall(
            address(recordingTarget), abi.encodeCall(DynamicExecutionTarget.fail, (31, payload))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(recordingTarget), targetReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "earlier target state should roll back");
    }

    function test_BoundedLargeRevertDataIsPreservedExactly() external {
        bytes memory payload = new bytes(8_192);
        payload[0] = 0x11;
        payload[4_095] = 0x22;
        payload[8_191] = 0x33;
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 61, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(67, 0.2 ether, "rolled-back-large-revert");
        calls[1] = _buildUnpatchedDynamicCall(
            address(recordingTarget), abi.encodeCall(DynamicExecutionTarget.fail, (61, payload))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(recordingTarget), targetReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "earlier target state should roll back");
        assertEq(address(recordingTarget).balance, 0, "earlier target value should roll back");
    }

    function test_ReturndataBombCanExhaustGasBeforeIndexedWrapping() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(71, 0.2 ether, "rolled-back-returndata-bomb");
        calls[1] = _buildUnpatchedDynamicCall(
            address(adversarialTarget),
            abi.encodeCall(DynamicExecutionAdversary.failWithReturnDataSize, (RETURNDATA_BOMB_SIZE))
        );

        (bool success, bytes memory reason) = accountUnderTest.delegatedEoa.call{gas: RETURNDATA_BOMB_GAS}(
            abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls))
        );

        assertFalse(success, "returndata bomb should fail execution");
        assertEq(reason.length, 0, "out-of-gas path should lose indexed attribution");
        assertEq(recordingTarget.count(), 0, "returndata bomb should roll back earlier state");
        assertEq(address(recordingTarget).balance, 0, "returndata bomb should roll back earlier value");
    }

    function test_InsufficientNativeBalanceWrapsEmptyReasonAndRollsBackBatch() external {
        vm.deal(accountUnderTest.delegatedEoa, 1 ether);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(73, 0.4 ether, "rolled-back-insufficient-balance");
        calls[1] = _buildRecordingCall(79, 0.7 ether, "insufficient-balance");

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(recordingTarget), bytes("")
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(accountUnderTest.delegatedEoa.balance, 1 ether, "account value should roll back");
        assertEq(address(recordingTarget).balance, 0, "target value should roll back");
        assertEq(recordingTarget.count(), 0, "target state should roll back");
    }

    function test_LaterAssertionFailureRollsBackEarlierStateAndValue() external {
        bytes memory payload = bytes("post-condition-failed");
        bytes memory targetReason =
            abi.encodeWithSelector(DynamicExecutionAdversary.TargetAssertionFailed.selector, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(83, 0.3 ether, "rolled-back-assertion");
        calls[1] = _buildUnpatchedDynamicCall(
            address(adversarialTarget), abi.encodeCall(DynamicExecutionAdversary.assertCondition, (false, payload))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(adversarialTarget), targetReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(accountUnderTest.delegatedEoa.balance, 10 ether, "account value should roll back");
        assertEq(address(recordingTarget).balance, 0, "target value should roll back");
        assertEq(recordingTarget.count(), 0, "target state should roll back");
    }

    function test_InvalidLaterPatchRollsBackEarlierCall() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(89, 0.1 ether, "rolled-back-invalid-patch");
        calls[1] = _buildRecordingCall(97, 0, "invalid-patch");
        calls[1].patches = new IDefiSimplify7702Account.BalancePatch[](1);
        calls[1].patches[0] = IDefiSimplify7702Account.BalancePatch({
            token: address(recordingTarget),
            checkpointId: bytes32(0),
            offset: 5,
            bps: 10_000,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 0, 5, calls[1].data.length)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "earlier target state should roll back");
        assertEq(address(recordingTarget).balance, 0, "earlier target value should roll back");
    }

    function test_SuccessfulReturnDataIsDiscardedAndLaterCallContinues() external {
        bytes memory payload = new bytes(8_192);
        payload[0] = 0xA1;
        payload[8_191] = 0xB2;
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildUnpatchedDynamicCall(
            address(adversarialTarget), abi.encodeCall(DynamicExecutionAdversary.returnPayload, (payload))
        );
        calls[1] = _buildRecordingCall(101, 0, "after-return-data");

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 1, "later call should execute");
        assertEq(recordingTarget.total(), 101, "success returndata should not affect execution");
    }

    function test_AuthorizedCrossFrameReentrySeesTransientLock() external {
        DelegatedDefiSimplifyAccount memory reentrantAccount =
            _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(recordingTarget)), REENTRANT_ACCOUNT_AUTHORITY_KEY);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.callAccountDynamic, (reentrantAccount.delegatedEoa))
        );
        bytes memory reentryReason = abi.encodeWithSelector(IDefiSimplify7702Account.DynamicExecutionReentered.selector);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(recordingTarget), reentryReason
            )
        );
        vm.prank(reentrantAccount.delegatedEoa);
        _dynamicExecutionInterfaceView(reentrantAccount.delegatedEoa).executeBatchDynamic(calls);
    }

    function test_SuccessfulReturnClearsTransientLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(41, 0, "first");
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        calls[0] = _buildRecordingCall(43, 0, "second");
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 2, "second invocation should not see stale lock");
        assertEq(recordingTarget.total(), 84, "both invocations should execute");
    }

    function test_RevertRollsBackTransientLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(recordingTarget), abi.encodeCall(DynamicExecutionTarget.fail, (47, bytes("rollback")))
        );
        (bool success,) =
            accountUnderTest.delegatedEoa.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "first invocation should fail");

        calls[0] = _buildRecordingCall(53, 0, "after-revert");
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.total(), 53, "reverted invocation should not leave stale lock");
    }

    function test_SuccessEmitsOnlyTargetEvents() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(59, 0, "event");

        vm.recordLogs();
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "unexpected custom account event");
        assertEq(logs[0].emitter, address(recordingTarget), "event emitter");
    }

    function _buildRecordingCall(uint256 amount, uint256 value, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _buildUnpatchedDynamicCall(
            address(recordingTarget), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)), value
        );
    }

    function _buildUnpatchedDynamicCall(address callTarget, bytes memory callData)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _buildUnpatchedDynamicCall(callTarget, callData, 0);
    }

    function _buildUnpatchedDynamicCall(address callTarget, bytes memory callData, uint256 callValue)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = callTarget;
        dynamicCall.value = callValue;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
