// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {
    AssertionBalanceToken,
    AssertionCaller,
    EmptyReturnAssertionBalanceToken,
    FlowAssertionsHarness,
    RevertingAssertionBalanceToken,
    ShortReturnAssertionBalanceToken
} from "../mocks/FlowAssertionsMocks.sol";

contract FlowAssertionsTest is Test {
    bytes32 private constant CHECKPOINT_A_ID = keccak256("flow-assertion-a");
    bytes32 private constant CHECKPOINT_B_ID = keccak256("flow-assertion-b");

    FlowAssertionsHarness private flowAssertions;
    AssertionBalanceToken private balanceToken;

    function setUp() external {
        flowAssertions = new FlowAssertionsHarness();
        balanceToken = new AssertionBalanceToken();
    }

    function test_SnapshotStoresIndependentPresenceTokenAndBalanceFields() external {
        balanceToken.setBalance(address(this), 101);

        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            flowAssertions.snapshotRecord(address(this), CHECKPOINT_A_ID);
        assertTrue(present, "snapshot presence");
        assertEq(snapshotToken, address(balanceToken), "snapshot token");
        assertEq(snapshotBalance, 101, "snapshot balance");
    }

    function test_ZeroBalanceStillCreatesPresentSnapshot() external {
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            flowAssertions.snapshotRecord(address(this), CHECKPOINT_A_ID);
        assertTrue(present, "zero-balance presence");
        assertEq(snapshotToken, address(balanceToken), "zero-balance token");
        assertEq(snapshotBalance, 0, "zero-balance value");
    }

    function test_ZeroTokenIsRejectedBeforeAnySnapshotLookupOrBalanceRead() external {
        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        flowAssertions.snapshotBalance(address(0), CHECKPOINT_A_ID);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        flowAssertions.assertBalanceAtLeast(address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        flowAssertions.assertBalanceIncreaseAtLeast(address(0), CHECKPOINT_A_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        flowAssertions.assertBalanceDecreaseAtMost(address(0), CHECKPOINT_A_ID, 0);
    }

    function test_ZeroCheckpointIdIsRejectedWhenSnapshotIsCreated() external {
        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionCheckpointId.selector, bytes32(0)));
        flowAssertions.snapshotBalance(address(balanceToken), bytes32(0));
    }

    function test_DuplicateIdForSameSenderRevertsBeforeSecondBalanceRead() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(7, "unread");
        balanceToken.setBalance(address(this), 103);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AssertionCheckpointAlreadyExists.selector, address(this), CHECKPOINT_A_ID
            )
        );
        flowAssertions.snapshotBalance(address(revertingToken), CHECKPOINT_A_ID);
    }

    function test_DifferentSendersMayReuseTheSameCheckpointId() external {
        AssertionCaller first = new AssertionCaller();
        AssertionCaller second = new AssertionCaller();
        balanceToken.setBalance(address(first), 107);
        balanceToken.setBalance(address(second), 109);

        first.snapshot(flowAssertions, address(balanceToken), CHECKPOINT_A_ID);
        second.snapshot(flowAssertions, address(balanceToken), CHECKPOINT_A_ID);

        (bool firstPresent, address firstToken, uint256 firstBalance) =
            flowAssertions.snapshotRecord(address(first), CHECKPOINT_A_ID);
        (bool secondPresent, address secondToken, uint256 secondBalance) =
            flowAssertions.snapshotRecord(address(second), CHECKPOINT_A_ID);
        assertTrue(firstPresent && secondPresent, "sender-scoped snapshots");
        assertEq(firstToken, address(balanceToken), "first token");
        assertEq(secondToken, address(balanceToken), "second token");
        assertEq(firstBalance, 107, "first balance");
        assertEq(secondBalance, 109, "second balance");
    }

    function test_OneSenderCannotConsumeAnotherSendersSnapshot() external {
        AssertionCaller first = new AssertionCaller();
        AssertionCaller second = new AssertionCaller();
        first.snapshot(flowAssertions, address(balanceToken), CHECKPOINT_A_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AssertionCheckpointNotFound.selector, address(second), CHECKPOINT_A_ID
            )
        );
        second.assertIncrease(flowAssertions, address(balanceToken), CHECKPOINT_A_ID, 0);
    }

    function test_DistinctCheckpointIdsForOneSenderRemainIndependent() external {
        balanceToken.setBalance(address(this), 113);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 127);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_B_ID);

        (, address tokenA, uint256 balanceA) = flowAssertions.snapshotRecord(address(this), CHECKPOINT_A_ID);
        (, address tokenB, uint256 balanceB) = flowAssertions.snapshotRecord(address(this), CHECKPOINT_B_ID);
        assertEq(tokenA, address(balanceToken), "checkpoint A token");
        assertEq(tokenB, address(balanceToken), "checkpoint B token");
        assertEq(balanceA, 113, "checkpoint A balance");
        assertEq(balanceB, 127, "checkpoint B balance");
    }

    function test_BalanceAtLeastPassesAtEqualityAndAboveIncludingZero() external {
        balanceToken.setBalance(address(this), 233);

        flowAssertions.assertBalanceAtLeast(address(balanceToken), 0);
        flowAssertions.assertBalanceAtLeast(address(balanceToken), 232);
        flowAssertions.assertBalanceAtLeast(address(balanceToken), 233);
    }

    function test_BalanceAtLeastReadsTheDirectCaller() external {
        AssertionCaller caller = new AssertionCaller();
        balanceToken.setBalance(address(this), 1);
        balanceToken.setBalance(address(caller), 131);

        caller.assertAtLeast(flowAssertions, address(balanceToken), 131);
    }

    function test_BalanceBelowMinimumReportsActualAndRequiredValues() external {
        balanceToken.setBalance(address(this), 137);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.BalanceBelowMinimum.selector, address(balanceToken), 137, 139)
        );
        flowAssertions.assertBalanceAtLeast(address(balanceToken), 139);
    }

    function test_IncreaseAtLeastUsesExactPositiveDeltaAndReportsFailure() external {
        balanceToken.setBalance(address(this), 149);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 160);

        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 11);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.BalanceIncreaseTooSmall.selector, address(balanceToken), CHECKPOINT_A_ID, 11, 12
            )
        );
        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 12);
    }

    function test_IncreaseAtLeastSaturatesToZeroWhenBalanceFalls() external {
        balanceToken.setBalance(address(this), 163);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 151);

        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.BalanceIncreaseTooSmall.selector, address(balanceToken), CHECKPOINT_A_ID, 0, 1
            )
        );
        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 1);
    }

    function test_IncreaseAtLeastSaturatesToZeroAtEqualBalance() external {
        balanceToken.setBalance(address(this), 167);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 0);
    }

    function test_DecreaseAtMostUsesExactPositiveDeltaAndReportsFailure() external {
        balanceToken.setBalance(address(this), 173);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 160);

        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 13);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.BalanceDecreaseTooLarge.selector, address(balanceToken), CHECKPOINT_A_ID, 13, 12
            )
        );
        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 12);
    }

    function test_DecreaseAtMostSaturatesToZeroWhenBalanceRises() external {
        balanceToken.setBalance(address(this), 179);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 191);

        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 0);
    }

    function test_DecreaseAtMostSaturatesToZeroAtEqualBalance() external {
        balanceToken.setBalance(address(this), 193);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 0);
    }

    function test_SuccessfulAssertionsDoNotConsumeSnapshot() external {
        balanceToken.setBalance(address(this), 197);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        balanceToken.setBalance(address(this), 211);

        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 14);
        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 14);
        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 0);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            flowAssertions.snapshotRecord(address(this), CHECKPOINT_A_ID);
        assertTrue(present, "snapshot consumed");
        assertEq(snapshotToken, address(balanceToken), "snapshot token changed");
        assertEq(snapshotBalance, 197, "snapshot balance changed");
    }

    function test_MissingCheckpointRevertsBeforeCurrentBalanceReadAndThreshold() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(17, "must-not-read");

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), CHECKPOINT_A_ID)
        );
        flowAssertions.assertBalanceIncreaseAtLeast(address(revertingToken), CHECKPOINT_A_ID, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), CHECKPOINT_A_ID)
        );
        flowAssertions.assertBalanceDecreaseAtMost(address(revertingToken), CHECKPOINT_A_ID, type(uint256).max);
    }

    function test_TokenMismatchRevertsBeforeCurrentBalanceReadAndThreshold() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(19, "must-not-read");
        balanceToken.setBalance(address(this), 223);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);

        bytes memory mismatch = abi.encodeWithSelector(
            IFlowAssertions.AssertionCheckpointTokenMismatch.selector,
            address(this),
            CHECKPOINT_A_ID,
            address(revertingToken),
            address(balanceToken)
        );
        vm.expectRevert(mismatch);
        flowAssertions.assertBalanceIncreaseAtLeast(address(revertingToken), CHECKPOINT_A_ID, type(uint256).max);

        vm.expectRevert(mismatch);
        flowAssertions.assertBalanceDecreaseAtMost(address(revertingToken), CHECKPOINT_A_ID, type(uint256).max);
    }

    function test_ZeroCheckpointReferenceIsReportedAsMissing() external {
        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), bytes32(0))
        );
        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), bytes32(0), 0);
    }

    function test_RevertingBalanceReadPreservesCompleteReason() external {
        bytes memory payload = bytes("assertion-balance-revert");
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(23, payload);
        bytes memory reason =
            abi.encodeWithSelector(RevertingAssertionBalanceToken.BalanceReadFailure.selector, 23, payload);
        bytes memory wrapped = abi.encodeWithSelector(
            IFlowAssertions.AssertionBalanceReadFailed.selector, address(revertingToken), reason
        );

        vm.expectRevert(wrapped);
        flowAssertions.snapshotBalance(address(revertingToken), CHECKPOINT_A_ID);

        vm.expectRevert(wrapped);
        flowAssertions.assertBalanceAtLeast(address(revertingToken), 0);
    }

    function test_ShortSuccessfulBalanceReadPreservesMalformedBytes() external {
        ShortReturnAssertionBalanceToken shortToken = new ShortReturnAssertionBalanceToken();

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, address(shortToken), hex"1234")
        );
        flowAssertions.snapshotBalance(address(shortToken), CHECKPOINT_A_ID);
    }

    function test_EmptySuccessfulBalanceReadAndEoaReadPreserveEmptyReason() external {
        EmptyReturnAssertionBalanceToken emptyToken = new EmptyReturnAssertionBalanceToken();
        address noCode = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, address(emptyToken), bytes(""))
        );
        flowAssertions.assertBalanceAtLeast(address(emptyToken), 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, noCode, bytes("")));
        flowAssertions.assertBalanceAtLeast(noCode, 0);
    }

    function test_SnapshotAndAssertionsEmitNoCustomEvents() external {
        balanceToken.setBalance(address(this), 227);

        vm.recordLogs();
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_A_ID);
        flowAssertions.assertBalanceAtLeast(address(balanceToken), 227);
        flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_A_ID, 0);
        flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_A_ID, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected assertion event");
    }
}

contract FlowAssertionsTransactionLifetimeTest is Test {
    bytes32 private constant REUSED_CHECKPOINT_ID = keccak256("transaction-lifetime");

    FlowAssertionsHarness private flowAssertions;
    AssertionBalanceToken private balanceToken;

    function setUp() external {
        flowAssertions = new FlowAssertionsHarness();
        balanceToken = new AssertionBalanceToken();
        balanceToken.setBalance(address(this), 229);
        flowAssertions.snapshotBalance(address(balanceToken), REUSED_CHECKPOINT_ID);
    }

    function test_SnapshotFromSetUpTransactionDoesNotSurviveIntoTestTransaction() external {
        flowAssertions.snapshotBalance(address(balanceToken), REUSED_CHECKPOINT_ID);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            flowAssertions.snapshotRecord(address(this), REUSED_CHECKPOINT_ID);
        assertTrue(present, "test-transaction snapshot absent");
        assertEq(snapshotToken, address(balanceToken), "test-transaction token");
        assertEq(snapshotBalance, 229, "test-transaction balance");
    }
}
