// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Vm} from "forge-std/Vm.sol";
import {DynamicExecutionAdversary} from "../mocks/DynamicExecutionAdversary.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract DynamicExecutionScaffoldTest is DelegatedAccountFixture {
    uint256 private constant REENTRANT_UPSTREAM_AUTHORITY_KEY = 0xD1A0;
    uint256 private constant REENTRANT_CUSTOM_AUTHORITY_KEY = 0xD1A1;
    uint256 private constant RETURNDATA_BOMB_SIZE = 2 * 1024 * 1024;
    uint256 private constant RETURNDATA_BOMB_GAS = 30_000_000;

    DelegatedPair private pair;
    DynamicExecutionTarget private target;
    DynamicExecutionAdversary private adversary;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        target = new DynamicExecutionTarget();
        adversary = new DynamicExecutionAdversary();
        vm.deal(pair.customAccount, 10 ether);
    }

    function test_InterfaceIdIsFrozenEntrypointSelector() external view {
        assertEq(
            bytes32(type(IDefiSimplify7702Account).interfaceId),
            bytes32(IDefiSimplify7702Account.executeBatchDynamic.selector),
            "unexpected dynamic interface id"
        );
        assertTrue(IERC165(pair.customAccount).supportsInterface(type(IDefiSimplify7702Account).interfaceId));
        assertFalse(IERC165(pair.upstreamAccount).supportsInterface(type(IDefiSimplify7702Account).interfaceId));
    }

    function test_BalanceSourceOrdinalsAreFrozen() external pure {
        assertEq(uint256(IDefiSimplify7702Account.BalanceSource.CurrentBalance), 0, "CurrentBalance ordinal");
        assertEq(uint256(IDefiSimplify7702Account.BalanceSource.CheckpointDelta), 1, "CheckpointDelta ordinal");
    }

    function test_ConfiguredEntryPointCanExecuteOneAndManyCallsWithValue() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(11, 0.25 ether, "one");
        _custom().executeBatchDynamic(calls);

        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(13, 0, "many-a");
        calls[1] = _recordCall(17, 0.5 ether, "many-b");
        _custom().executeBatchDynamic(calls);

        assertEq(target.lastCaller(), pair.customAccount, "target caller");
        assertEq(target.count(), 3, "target call count");
        assertEq(target.total(), 41, "target total");
        assertEq(target.totalCallValue(), 0.75 ether, "target call value");
        assertEq(target.lastPayloadHash(), keccak256("many-b"), "target call order");
    }

    function test_DelegatedAccountSelfCanExecuteDynamicBatch() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(23, 0, "self");

        vm.prank(pair.customAccount);
        _custom().executeBatchDynamic(calls);

        assertEq(target.lastCaller(), pair.customAccount, "self path target caller");
        assertEq(target.total(), 23, "self path target total");
    }

    function test_RandomCallerFailsAuthorizationBeforeEmptyBatchValidation() external {
        address randomCaller = address(0xCA11E2);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, pair.customAccount, address(this)
            )
        );
        vm.prank(randomCaller);
        _custom().executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackFailsAuthorizationBeforeReadingActiveDynamicLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(target), abi.encodeCall(DynamicExecutionTarget.callAccountDynamic, (pair.customAccount))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector, address(target), pair.customAccount, address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(target), authorizationReason
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackCannotEnterInheritedExecute() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(adversary), abi.encodeCall(DynamicExecutionAdversary.callAccountExecute, (pair.customAccount))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector, address(adversary), pair.customAccount, address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(adversary), authorizationReason
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_MaliciousCallbackCannotEnterInheritedExecuteBatch() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(adversary), abi.encodeCall(DynamicExecutionAdversary.callAccountExecuteBatch, (pair.customAccount))
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector, address(adversary), pair.customAccount, address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(adversary), authorizationReason
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_EmptyBatchReverts() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](0);

        vm.expectRevert(IDefiSimplify7702Account.EmptyDynamicBatch.selector);
        _custom().executeBatchDynamic(calls);
    }

    function test_ZeroTargetRevertsWithCallIndex() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(29, 0, "rolled-back");
        calls[1] = _emptyDynamicCall(address(0), "");

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 1, address(0)));
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier target state should roll back");
    }

    function test_SelfTargetRevertsWithCallIndex() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(pair.customAccount, "");

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 0, pair.customAccount));
        _custom().executeBatchDynamic(calls);
    }

    function test_FailedCallWrapsIndexTargetAndCompleteReason() external {
        bytes memory payload = bytes("complete-nested-revert-data");
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 31, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(37, 0, "rolled-back");
        calls[1] = _emptyDynamicCall(address(target), abi.encodeCall(DynamicExecutionTarget.fail, (31, payload)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(target), targetReason
            )
        );
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier target state should roll back");
    }

    function test_BoundedLargeRevertDataIsPreservedExactly() external {
        bytes memory payload = new bytes(8_192);
        payload[0] = 0x11;
        payload[4_095] = 0x22;
        payload[8_191] = 0x33;
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 61, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(67, 0.2 ether, "rolled-back-large-revert");
        calls[1] = _emptyDynamicCall(address(target), abi.encodeCall(DynamicExecutionTarget.fail, (61, payload)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(target), targetReason
            )
        );
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier target state should roll back");
        assertEq(address(target).balance, 0, "earlier target value should roll back");
    }

    function test_ReturndataBombCanExhaustGasBeforeIndexedWrapping() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(71, 0.2 ether, "rolled-back-returndata-bomb");
        calls[1] = _emptyDynamicCall(
            address(adversary), abi.encodeCall(DynamicExecutionAdversary.failWithReturnDataSize, (RETURNDATA_BOMB_SIZE))
        );

        (bool success, bytes memory reason) = pair.customAccount.call{gas: RETURNDATA_BOMB_GAS}(
            abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls))
        );

        assertFalse(success, "returndata bomb should fail execution");
        assertEq(reason.length, 0, "out-of-gas path should lose indexed attribution");
        assertEq(target.count(), 0, "returndata bomb should roll back earlier state");
        assertEq(address(target).balance, 0, "returndata bomb should roll back earlier value");
    }

    function test_InsufficientNativeBalanceWrapsEmptyReasonAndRollsBackBatch() external {
        vm.deal(pair.customAccount, 1 ether);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(73, 0.4 ether, "rolled-back-insufficient-balance");
        calls[1] = _recordCall(79, 0.7 ether, "insufficient-balance");

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(target), bytes(""))
        );
        _custom().executeBatchDynamic(calls);

        assertEq(pair.customAccount.balance, 1 ether, "account value should roll back");
        assertEq(address(target).balance, 0, "target value should roll back");
        assertEq(target.count(), 0, "target state should roll back");
    }

    function test_LaterAssertionFailureRollsBackEarlierStateAndValue() external {
        bytes memory payload = bytes("post-condition-failed");
        bytes memory targetReason =
            abi.encodeWithSelector(DynamicExecutionAdversary.TargetAssertionFailed.selector, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(83, 0.3 ether, "rolled-back-assertion");
        calls[1] = _emptyDynamicCall(
            address(adversary), abi.encodeCall(DynamicExecutionAdversary.assertCondition, (false, payload))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(adversary), targetReason
            )
        );
        _custom().executeBatchDynamic(calls);

        assertEq(pair.customAccount.balance, 10 ether, "account value should roll back");
        assertEq(address(target).balance, 0, "target value should roll back");
        assertEq(target.count(), 0, "target state should roll back");
    }

    function test_InvalidLaterPatchRollsBackEarlierCall() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(89, 0.1 ether, "rolled-back-invalid-patch");
        calls[1] = _recordCall(97, 0, "invalid-patch");
        calls[1].patches = new IDefiSimplify7702Account.BalancePatch[](1);
        calls[1].patches[0] = IDefiSimplify7702Account.BalancePatch({
            token: address(target),
            checkpointId: bytes32(0),
            offset: 5,
            bps: 10_000,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 0, 5, calls[1].data.length)
        );
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier target state should roll back");
        assertEq(address(target).balance, 0, "earlier target value should roll back");
    }

    function test_SuccessfulReturnDataIsDiscardedAndLaterCallContinues() external {
        bytes memory payload = new bytes(8_192);
        payload[0] = 0xA1;
        payload[8_191] = 0xB2;
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] =
            _emptyDynamicCall(address(adversary), abi.encodeCall(DynamicExecutionAdversary.returnPayload, (payload)));
        calls[1] = _recordCall(101, 0, "after-return-data");

        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 1, "later call should execute");
        assertEq(target.total(), 101, "success returndata should not affect execution");
    }

    function test_AuthorizedCrossFrameReentrySeesTransientLock() external {
        DelegatedPair memory reentrantPair = _deployDelegatedPair(
            IEntryPoint(address(target)), REENTRANT_UPSTREAM_AUTHORITY_KEY, REENTRANT_CUSTOM_AUTHORITY_KEY
        );
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(target), abi.encodeCall(DynamicExecutionTarget.callAccountDynamic, (reentrantPair.customAccount))
        );
        bytes memory reentryReason = abi.encodeWithSelector(IDefiSimplify7702Account.DynamicExecutionReentered.selector);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(target), reentryReason
            )
        );
        vm.prank(reentrantPair.customAccount);
        IDefiSimplify7702Account(reentrantPair.customAccount).executeBatchDynamic(calls);
    }

    function test_SuccessfulReturnClearsTransientLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(41, 0, "first");
        _custom().executeBatchDynamic(calls);

        calls[0] = _recordCall(43, 0, "second");
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 2, "second invocation should not see stale lock");
        assertEq(target.total(), 84, "both invocations should execute");
    }

    function test_RevertRollsBackTransientLock() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] =
            _emptyDynamicCall(address(target), abi.encodeCall(DynamicExecutionTarget.fail, (47, bytes("rollback"))));
        (bool success,) = pair.customAccount.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "first invocation should fail");

        calls[0] = _recordCall(53, 0, "after-revert");
        _custom().executeBatchDynamic(calls);

        assertEq(target.total(), 53, "reverted invocation should not leave stale lock");
    }

    function test_SuccessEmitsOnlyTargetEvents() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(59, 0, "event");

        vm.recordLogs();
        _custom().executeBatchDynamic(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "unexpected custom account event");
        assertEq(logs[0].emitter, address(target), "event emitter");
    }

    function _custom() private view returns (IDefiSimplify7702Account) {
        return IDefiSimplify7702Account(pair.customAccount);
    }

    function _recordCall(uint256 amount, uint256 value, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return
            _emptyDynamicCall(address(target), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)), value);
    }

    function _emptyDynamicCall(address callTarget, bytes memory data)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _emptyDynamicCall(callTarget, data, 0);
    }

    function _emptyDynamicCall(address callTarget, bytes memory data, uint256 value)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = callTarget;
        dynamicCall.value = value;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
