// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    CheckpointBalanceToken,
    CheckpointTableHarness,
    EmptyReturnCheckpointToken,
    PreCallCheckpointToken,
    RevertingCheckpointToken,
    ShortReturnCheckpointToken
} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CheckpointEngineTest is DelegatedAccountFixture {
    bytes32 private constant CHECKPOINT_A = keccak256("checkpoint-a");
    bytes32 private constant CHECKPOINT_B = keccak256("checkpoint-b");

    DelegatedPair private pair;
    DynamicExecutionTarget private target;
    CheckpointBalanceToken private token;
    CheckpointTableHarness private harness;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        target = new DynamicExecutionTarget();
        token = new CheckpointBalanceToken();
        harness = new CheckpointTableHarness();
    }

    function test_Gas_OneCheckpointUsesDelegatedAccountBalanceImmediatelyBeforeTarget() external {
        PreCallCheckpointToken preCallToken = new PreCallCheckpointToken(pair.customAccount, address(target), 0, 101);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(11, "one", _singleCheckpoint(address(preCallToken), CHECKPOINT_A));

        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 1, "target call count");
        assertEq(target.total(), 11, "target amount");
        assertEq(target.lastCaller(), pair.customAccount, "delegated caller");
    }

    function test_Gas_MultipleCheckpointsAreCreatedImmediatelyBeforeTheirTargets() external {
        PreCallCheckpointToken firstToken = new PreCallCheckpointToken(pair.customAccount, address(target), 0, 201);
        PreCallCheckpointToken secondToken = new PreCallCheckpointToken(pair.customAccount, address(target), 1, 202);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(13, "first", _singleCheckpoint(address(firstToken), CHECKPOINT_A));
        calls[1] = _recordCall(17, "second", _singleCheckpoint(address(secondToken), CHECKPOINT_B));

        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 2, "target call count");
        assertEq(target.total(), 30, "target amount");
    }

    function test_HarnessRecordsIdTokenAndZeroOrNonzeroBalance() external {
        CheckpointBalanceToken zeroBalanceToken = new CheckpointBalanceToken();
        token.setBalance(address(harness), 303);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(zeroBalanceToken), CHECKPOINT_B);

        DefiSimplify7702Account.CheckpointRecord[] memory records = harness.capture(checkpoints, 7);

        assertEq(records.length, 2, "record count");
        assertEq(records[0].id, CHECKPOINT_A, "first id");
        assertEq(records[0].token, address(token), "first token");
        assertEq(records[0].balance, 303, "first balance");
        assertEq(records[1].id, CHECKPOINT_B, "second id");
        assertEq(records[1].token, address(zeroBalanceToken), "second token");
        assertEq(records[1].balance, 0, "zero balance must be present");
    }

    function test_ZeroTokenRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(0), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(19, "rolled-back", _noCheckpoints());
        calls[1] = _recordCall(23, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointToken.selector, 1, 1));
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier call must roll back");
    }

    function test_ZeroIdRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), bytes32(0));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(29, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointId.selector, 0, 1));
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "target must not execute");
    }

    function test_DuplicateIdOnSameTokenRevertsAtSecondCheckpoint() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), CHECKPOINT_A);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(31, "duplicate", checkpoints);

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 0, 1, CHECKPOINT_A)
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_DuplicateIdAcrossDifferentTokensAndCallsRevertsGlobally() external {
        CheckpointBalanceToken otherToken = new CheckpointBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(37, "first", _singleCheckpoint(address(token), CHECKPOINT_A));
        calls[1] = _recordCall(41, "duplicate", _singleCheckpoint(address(otherToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 1, 0, CHECKPOINT_A)
        );
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier call must roll back");
    }

    function test_SameTokenSupportsMultipleDistinctCheckpointIds() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(43, "same-token", checkpoints);

        _custom().executeBatchDynamic(calls);

        assertEq(target.total(), 43, "target amount");
    }

    function test_SequentialSameTransactionInvocationsMayReuseId() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(47, "first", _singleCheckpoint(address(token), CHECKPOINT_A));
        _custom().executeBatchDynamic(calls);

        calls[0] = _recordCall(53, "second", _singleCheckpoint(address(token), CHECKPOINT_A));
        _custom().executeBatchDynamic(calls);

        assertEq(target.count(), 2, "both invocations execute");
        assertEq(target.total(), 100, "both amounts recorded");
    }

    function test_RevertingBalanceReadPreservesReasonAndIndices() external {
        bytes memory payload = bytes("checkpoint-balance-revert");
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(59, payload);
        bytes memory reason = abi.encodeWithSelector(RevertingCheckpointToken.BalanceReadFailure.selector, 59, payload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(61, "revert", _singleCheckpoint(address(revertingToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(revertingToken), reason
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_ShortSuccessfulBalanceReadPreservesMalformedBytes() external {
        ShortReturnCheckpointToken shortToken = new ShortReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(67, "short", _singleCheckpoint(address(shortToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(shortToken), hex"1234"
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_EmptySuccessfulBalanceReadFailsWithEmptyReason() external {
        EmptyReturnCheckpointToken emptyToken = new EmptyReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(71, "empty", _singleCheckpoint(address(emptyToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(emptyToken), bytes("")
            )
        );
        _custom().executeBatchDynamic(calls);
    }

    function test_RevertedTargetCannotLeakCheckpointIntoLaterInvocation() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.fail, (73, bytes("rollback"))),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );
        (bool success,) = pair.customAccount.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "producer invocation must fail");

        calls[0] = _recordCall(79, "after-revert", _singleCheckpoint(address(token), CHECKPOINT_A));
        _custom().executeBatchDynamic(calls);

        assertEq(target.total(), 79, "same id must be reusable after revert");
    }

    function test_CallbackFailureCannotPersistCheckpointRecords() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.callAccountDynamic, (pair.customAccount)),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );
        (bool success,) = pair.customAccount.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "callback invocation must fail");

        calls[0] = _recordCall(83, "after-callback", _singleCheckpoint(address(token), CHECKPOINT_A));
        _custom().executeBatchDynamic(calls);

        assertEq(target.total(), 83, "callback failure must not persist checkpoint records");
    }

    function test_UnauthorizedCallerFailsBeforeCheckpointBalanceRead() external {
        address randomCaller = address(0xCA11E2);
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(89, bytes("must-not-read"));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(89, "unauthorized", _singleCheckpoint(address(revertingToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, pair.customAccount, address(this)
            )
        );
        vm.prank(randomCaller);
        _custom().executeBatchDynamic(calls);
    }

    function _custom() private view returns (IDefiSimplify7702Account) {
        return IDefiSimplify7702Account(pair.customAccount);
    }

    function _recordCall(
        uint256 amount,
        bytes memory payload,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints
    ) private view returns (IDefiSimplify7702Account.DynamicCall memory) {
        return
            _dynamicCall(address(target), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)), checkpoints);
    }

    function _dynamicCall(
        address callTarget,
        bytes memory data,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _singleCheckpoint(address checkpointToken, bytes32 id)
        private
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = _checkpoint(checkpointToken, id);
    }

    function _noCheckpoints() private pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _checkpoint(address checkpointToken, bytes32 id)
        private
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint memory)
    {
        return IDefiSimplify7702Account.BalanceCheckpoint({token: checkpointToken, id: id});
    }
}
