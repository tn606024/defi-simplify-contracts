// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Vm} from "forge-std/Vm.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract DynamicExecutionScaffoldTest is DelegatedAccountFixture {
    uint256 private constant REENTRANT_UPSTREAM_AUTHORITY_KEY = 0xD1A0;
    uint256 private constant REENTRANT_CUSTOM_AUTHORITY_KEY = 0xD1A1;

    DelegatedPair private pair;
    DynamicExecutionTarget private target;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        target = new DynamicExecutionTarget();
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
