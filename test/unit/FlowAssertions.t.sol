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
    bytes32 private constant CHECKPOINT_A = keccak256("flow-assertion-a");
    bytes32 private constant CHECKPOINT_B = keccak256("flow-assertion-b");

    FlowAssertionsHarness private assertions;
    AssertionBalanceToken private token;

    function setUp() external {
        assertions = new FlowAssertionsHarness();
        token = new AssertionBalanceToken();
    }

    function test_SnapshotStoresIndependentPresenceTokenAndBalanceFields() external {
        token.setBalance(address(this), 101);

        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            assertions.snapshotRecord(address(this), CHECKPOINT_A);
        assertTrue(present, "snapshot presence");
        assertEq(snapshotToken, address(token), "snapshot token");
        assertEq(snapshotBalance, 101, "snapshot balance");
    }

    function test_ZeroBalanceStillCreatesPresentSnapshot() external {
        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            assertions.snapshotRecord(address(this), CHECKPOINT_A);
        assertTrue(present, "zero-balance presence");
        assertEq(snapshotToken, address(token), "zero-balance token");
        assertEq(snapshotBalance, 0, "zero-balance value");
    }

    function test_ZeroTokenIsRejectedBeforeAnySnapshotLookupOrBalanceRead() external {
        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        assertions.snapshotBalance(address(0), CHECKPOINT_A);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        assertions.assertBalanceAtLeast(address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        assertions.assertBalanceIncreaseAtLeast(address(0), CHECKPOINT_A, 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionToken.selector, address(0)));
        assertions.assertBalanceDecreaseAtMost(address(0), CHECKPOINT_A, 0);
    }

    function test_ZeroCheckpointIdIsRejectedWhenSnapshotIsCreated() external {
        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.InvalidAssertionCheckpointId.selector, bytes32(0)));
        assertions.snapshotBalance(address(token), bytes32(0));
    }

    function test_DuplicateIdForSameSenderRevertsBeforeSecondBalanceRead() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(7, "unread");
        token.setBalance(address(this), 103);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AssertionCheckpointAlreadyExists.selector, address(this), CHECKPOINT_A
            )
        );
        assertions.snapshotBalance(address(revertingToken), CHECKPOINT_A);
    }

    function test_DifferentSendersMayReuseTheSameCheckpointId() external {
        AssertionCaller first = new AssertionCaller();
        AssertionCaller second = new AssertionCaller();
        token.setBalance(address(first), 107);
        token.setBalance(address(second), 109);

        first.snapshot(assertions, address(token), CHECKPOINT_A);
        second.snapshot(assertions, address(token), CHECKPOINT_A);

        (bool firstPresent, address firstToken, uint256 firstBalance) =
            assertions.snapshotRecord(address(first), CHECKPOINT_A);
        (bool secondPresent, address secondToken, uint256 secondBalance) =
            assertions.snapshotRecord(address(second), CHECKPOINT_A);
        assertTrue(firstPresent && secondPresent, "sender-scoped snapshots");
        assertEq(firstToken, address(token), "first token");
        assertEq(secondToken, address(token), "second token");
        assertEq(firstBalance, 107, "first balance");
        assertEq(secondBalance, 109, "second balance");
    }

    function test_OneSenderCannotConsumeAnotherSendersSnapshot() external {
        AssertionCaller first = new AssertionCaller();
        AssertionCaller second = new AssertionCaller();
        first.snapshot(assertions, address(token), CHECKPOINT_A);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(second), CHECKPOINT_A)
        );
        second.assertIncrease(assertions, address(token), CHECKPOINT_A, 0);
    }

    function test_DistinctCheckpointIdsForOneSenderRemainIndependent() external {
        token.setBalance(address(this), 113);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 127);
        assertions.snapshotBalance(address(token), CHECKPOINT_B);

        (, address tokenA, uint256 balanceA) = assertions.snapshotRecord(address(this), CHECKPOINT_A);
        (, address tokenB, uint256 balanceB) = assertions.snapshotRecord(address(this), CHECKPOINT_B);
        assertEq(tokenA, address(token), "checkpoint A token");
        assertEq(tokenB, address(token), "checkpoint B token");
        assertEq(balanceA, 113, "checkpoint A balance");
        assertEq(balanceB, 127, "checkpoint B balance");
    }

    function test_BalanceAtLeastPassesAtEqualityAndAboveIncludingZero() external {
        token.setBalance(address(this), 233);

        assertions.assertBalanceAtLeast(address(token), 0);
        assertions.assertBalanceAtLeast(address(token), 232);
        assertions.assertBalanceAtLeast(address(token), 233);
    }

    function test_BalanceAtLeastReadsTheDirectCaller() external {
        AssertionCaller caller = new AssertionCaller();
        token.setBalance(address(this), 1);
        token.setBalance(address(caller), 131);

        caller.assertAtLeast(assertions, address(token), 131);
    }

    function test_BalanceBelowMinimumReportsActualAndRequiredValues() external {
        token.setBalance(address(this), 137);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.BalanceBelowMinimum.selector, address(token), 137, 139));
        assertions.assertBalanceAtLeast(address(token), 139);
    }

    function test_IncreaseAtLeastUsesExactPositiveDeltaAndReportsFailure() external {
        token.setBalance(address(this), 149);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 160);

        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 11);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.BalanceIncreaseTooSmall.selector, address(token), CHECKPOINT_A, 11, 12
            )
        );
        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 12);
    }

    function test_IncreaseAtLeastSaturatesToZeroWhenBalanceFalls() external {
        token.setBalance(address(this), 163);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 151);

        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.BalanceIncreaseTooSmall.selector, address(token), CHECKPOINT_A, 0, 1)
        );
        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 1);
    }

    function test_IncreaseAtLeastSaturatesToZeroAtEqualBalance() external {
        token.setBalance(address(this), 167);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 0);
    }

    function test_DecreaseAtMostUsesExactPositiveDeltaAndReportsFailure() external {
        token.setBalance(address(this), 173);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 160);

        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 13);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.BalanceDecreaseTooLarge.selector, address(token), CHECKPOINT_A, 13, 12
            )
        );
        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 12);
    }

    function test_DecreaseAtMostSaturatesToZeroWhenBalanceRises() external {
        token.setBalance(address(this), 179);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 191);

        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 0);
    }

    function test_DecreaseAtMostSaturatesToZeroAtEqualBalance() external {
        token.setBalance(address(this), 193);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 0);
    }

    function test_SuccessfulAssertionsDoNotConsumeSnapshot() external {
        token.setBalance(address(this), 197);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        token.setBalance(address(this), 211);

        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 14);
        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 14);
        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 0);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            assertions.snapshotRecord(address(this), CHECKPOINT_A);
        assertTrue(present, "snapshot consumed");
        assertEq(snapshotToken, address(token), "snapshot token changed");
        assertEq(snapshotBalance, 197, "snapshot balance changed");
    }

    function test_MissingCheckpointRevertsBeforeCurrentBalanceReadAndThreshold() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(17, "must-not-read");

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), CHECKPOINT_A)
        );
        assertions.assertBalanceIncreaseAtLeast(address(revertingToken), CHECKPOINT_A, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), CHECKPOINT_A)
        );
        assertions.assertBalanceDecreaseAtMost(address(revertingToken), CHECKPOINT_A, type(uint256).max);
    }

    function test_TokenMismatchRevertsBeforeCurrentBalanceReadAndThreshold() external {
        RevertingAssertionBalanceToken revertingToken = new RevertingAssertionBalanceToken(19, "must-not-read");
        token.setBalance(address(this), 223);
        assertions.snapshotBalance(address(token), CHECKPOINT_A);

        bytes memory mismatch = abi.encodeWithSelector(
            IFlowAssertions.AssertionCheckpointTokenMismatch.selector,
            address(this),
            CHECKPOINT_A,
            address(revertingToken),
            address(token)
        );
        vm.expectRevert(mismatch);
        assertions.assertBalanceIncreaseAtLeast(address(revertingToken), CHECKPOINT_A, type(uint256).max);

        vm.expectRevert(mismatch);
        assertions.assertBalanceDecreaseAtMost(address(revertingToken), CHECKPOINT_A, type(uint256).max);
    }

    function test_ZeroCheckpointReferenceIsReportedAsMissing() external {
        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionCheckpointNotFound.selector, address(this), bytes32(0))
        );
        assertions.assertBalanceIncreaseAtLeast(address(token), bytes32(0), 0);
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
        assertions.snapshotBalance(address(revertingToken), CHECKPOINT_A);

        vm.expectRevert(wrapped);
        assertions.assertBalanceAtLeast(address(revertingToken), 0);
    }

    function test_ShortSuccessfulBalanceReadPreservesMalformedBytes() external {
        ShortReturnAssertionBalanceToken shortToken = new ShortReturnAssertionBalanceToken();

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, address(shortToken), hex"1234")
        );
        assertions.snapshotBalance(address(shortToken), CHECKPOINT_A);
    }

    function test_EmptySuccessfulBalanceReadAndEoaReadPreserveEmptyReason() external {
        EmptyReturnAssertionBalanceToken emptyToken = new EmptyReturnAssertionBalanceToken();
        address noCode = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, address(emptyToken), bytes(""))
        );
        assertions.assertBalanceAtLeast(address(emptyToken), 0);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.AssertionBalanceReadFailed.selector, noCode, bytes("")));
        assertions.assertBalanceAtLeast(noCode, 0);
    }

    function test_SnapshotAndAssertionsEmitNoCustomEvents() external {
        token.setBalance(address(this), 227);

        vm.recordLogs();
        assertions.snapshotBalance(address(token), CHECKPOINT_A);
        assertions.assertBalanceAtLeast(address(token), 227);
        assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT_A, 0);
        assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT_A, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected assertion event");
    }
}

contract FlowAssertionsTransactionLifetimeTest is Test {
    bytes32 private constant REUSED_CHECKPOINT = keccak256("transaction-lifetime");

    FlowAssertionsHarness private assertions;
    AssertionBalanceToken private token;

    function setUp() external {
        assertions = new FlowAssertionsHarness();
        token = new AssertionBalanceToken();
        token.setBalance(address(this), 229);
        assertions.snapshotBalance(address(token), REUSED_CHECKPOINT);
    }

    function test_SnapshotFromSetUpTransactionDoesNotSurviveIntoTestTransaction() external {
        assertions.snapshotBalance(address(token), REUSED_CHECKPOINT);

        (bool present, address snapshotToken, uint256 snapshotBalance) =
            assertions.snapshotRecord(address(this), REUSED_CHECKPOINT);
        assertTrue(present, "test-transaction snapshot absent");
        assertEq(snapshotToken, address(token), "test-transaction token");
        assertEq(snapshotBalance, 229, "test-transaction balance");
    }
}
