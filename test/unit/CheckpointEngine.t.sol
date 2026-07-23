// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {
    CheckpointBalanceToken,
    CheckpointTableHarness,
    EmptyReturnCheckpointToken,
    PreCallCheckpointToken,
    RevertingCheckpointEntryPoint,
    RevertingCheckpointToken,
    ShortReturnCheckpointToken,
    TransientProbeTarget
} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CheckpointEngineTest is DelegatedAccountFixture {
    using SlotDerivation for bytes32;

    uint256 private constant HARNESS_AUTHORITY_KEY = 0x48A0;
    uint256 private constant SECOND_HARNESS_AUTHORITY_KEY = 0x48A1;
    uint256 private constant CONTAINED_HARNESS_AUTHORITY_KEY = 0x48A2;
    bytes32 private constant CHECKPOINT_A = keccak256("checkpoint-a");
    bytes32 private constant CHECKPOINT_B = keccak256("checkpoint-b");

    DelegatedPair private pair;
    DynamicExecutionTarget private target;
    CheckpointBalanceToken private token;
    CheckpointTableHarness private harnessImplementation;
    address payable private harnessAccount;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        target = new DynamicExecutionTarget();
        token = new CheckpointBalanceToken();
        harnessImplementation = new CheckpointTableHarness(IEntryPoint(address(this)));
        harnessAccount = _attachHarness(address(harnessImplementation), HARNESS_AUTHORITY_KEY);
    }

    function test_Gas_OneCheckpointUsesDelegatedAccountBalanceImmediatelyBeforeTarget() external {
        PreCallCheckpointToken preCallToken = new PreCallCheckpointToken(pair.customAccount, address(target), 0, 101);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(11, "one", _singleCheckpoint(address(preCallToken), CHECKPOINT_A));

        _dynamicAccount(pair).executeBatchDynamic(calls);

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

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.count(), 2, "target call count");
        assertEq(target.total(), 30, "target amount");
    }

    function test_ZeroBalanceHasIndependentPresenceTokenAndBalanceFields() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(19, "zero", _singleCheckpoint(address(token), CHECKPOINT_A));

        _harness().executeBatchDynamic(calls);

        (bool present, address storedToken, uint256 balance) = _harness().checkpointRecord(1, CHECKPOINT_A);
        assertTrue(present, "zero balance checkpoint absent");
        assertEq(storedToken, address(token), "stored token");
        assertEq(balance, 0, "stored zero balance");
    }

    function test_ZeroTokenRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(0), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(23, "rolled-back", _noCheckpoints());
        calls[1] = _recordCall(29, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointToken.selector, 1, 1));
        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier call must roll back");
    }

    function test_ZeroIdRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), bytes32(0));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(31, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointId.selector, 0, 1));
        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.count(), 0, "target must not execute");
    }

    function test_DuplicateIdOnSameTokenRevertsAtSecondCheckpoint() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), CHECKPOINT_A);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(37, "duplicate", checkpoints);

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 0, 1, CHECKPOINT_A)
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_DuplicateIdAcrossDifferentTokensAndCallsRevertsInActiveScope() external {
        CheckpointBalanceToken otherToken = new CheckpointBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(41, "first", _singleCheckpoint(address(token), CHECKPOINT_A));
        calls[1] = _recordCall(43, "duplicate", _singleCheckpoint(address(otherToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 1, 0, CHECKPOINT_A)
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.count(), 0, "earlier call must roll back");
    }

    function test_SameTokenSupportsMultipleDistinctCheckpointIds() external {
        token.setBalance(pair.customAccount, 47);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(47, "same-token", checkpoints);

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.total(), 47, "target amount");
    }

    function test_SequentialInvocationsUseDisjointScopesAndMayReuseId() external {
        token.setBalance(harnessAccount, 53);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(53, "first", _singleCheckpoint(address(token), CHECKPOINT_A));
        _harness().executeBatchDynamic(calls);

        token.setBalance(harnessAccount, 59);
        calls[0] = _recordCall(59, "second", _singleCheckpoint(address(token), CHECKPOINT_A));
        _harness().executeBatchDynamic(calls);

        assertEq(_harness().invocationCounter(), 2, "invocation counter");
        (bool firstPresent, address firstToken, uint256 firstBalance) = _harness().checkpointRecord(1, CHECKPOINT_A);
        (bool secondPresent, address secondToken, uint256 secondBalance) = _harness().checkpointRecord(2, CHECKPOINT_A);
        assertTrue(firstPresent && secondPresent, "scoped records absent");
        assertEq(firstToken, address(token), "first token");
        assertEq(secondToken, address(token), "second token");
        assertEq(firstBalance, 53, "first balance");
        assertEq(secondBalance, 59, "second balance");
    }

    function test_RevertedInvocationRollsBackCounterAndRecordsTogether() external {
        token.setBalance(harnessAccount, 61);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(61, "first", _singleCheckpoint(address(token), CHECKPOINT_A));
        _harness().executeBatchDynamic(calls);

        token.setBalance(harnessAccount, 67);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.fail, (67, bytes("rollback"))),
            _singleCheckpoint(address(token), CHECKPOINT_B)
        );
        (bool success,) = harnessAccount.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "failing invocation succeeded");

        assertEq(_harness().invocationCounter(), 1, "reverted counter persisted");
        (bool revertedPresent,,) = _harness().checkpointRecord(2, CHECKPOINT_B);
        assertFalse(revertedPresent, "reverted checkpoint persisted");

        calls[0] = _recordCall(71, "recovered", _singleCheckpoint(address(token), CHECKPOINT_B));
        _harness().executeBatchDynamic(calls);
        assertEq(_harness().invocationCounter(), 2, "counter did not reuse rolled-back scope");
        (bool recoveredPresent,, uint256 recoveredBalance) = _harness().checkpointRecord(2, CHECKPOINT_B);
        assertTrue(recoveredPresent, "recovered checkpoint absent");
        assertEq(recoveredBalance, 67, "recovered checkpoint balance");
    }

    function test_ContainingFrameRevertRollsBackCounterAndRecords() external {
        RevertingCheckpointEntryPoint entryPoint = new RevertingCheckpointEntryPoint();
        CheckpointTableHarness implementation = new CheckpointTableHarness(IEntryPoint(address(entryPoint)));
        address payable account = _attachHarness(address(implementation), CONTAINED_HARNESS_AUTHORITY_KEY);
        token.setBalance(account, 73);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (73, bytes("contained"))),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );

        (bool success,) =
            address(entryPoint).call(abi.encodeCall(RevertingCheckpointEntryPoint.invoke, (account, calls)));
        assertFalse(success, "containing frame unexpectedly succeeded");
        assertEq(target.count(), 0, "target state survived containing revert");

        vm.prank(account);
        assertEq(CheckpointTableHarness(account).invocationCounter(), 0, "counter survived containing revert");
        vm.prank(account);
        (bool present,,) = CheckpointTableHarness(account).checkpointRecord(1, CHECKPOINT_A);
        assertFalse(present, "record survived containing revert");
    }

    function test_OrdinaryCallTargetCannotSeeAccountTransientRecord() external {
        TransientProbeTarget probeTarget = new TransientProbeTarget();
        bytes32 recordRoot = _harness().checkpointRecordRoot(1, CHECKPOINT_A);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(probeTarget),
            abi.encodeCall(TransientProbeTarget.probe, (recordRoot)),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );

        _harness().executeBatchDynamic(calls);

        assertEq(probeTarget.lastObserved(), bytes32(0), "target observed account transient state");
        (bool present,,) = _harness().checkpointRecord(1, CHECKPOINT_A);
        assertTrue(present, "account record absent");
    }

    function test_CallbackCannotQueryCheckpointHarness() external {
        TransientProbeTarget probeTarget = new TransientProbeTarget();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(probeTarget),
            abi.encodeCall(TransientProbeTarget.queryCheckpointHarness, (harnessAccount, 1, CHECKPOINT_A)),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector, address(probeTarget), harnessAccount, address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(probeTarget), authorizationReason
            )
        );
        _harness().executeBatchDynamic(calls);
    }

    function test_NamespacesAndNestedRecordLayoutAreDistinct() external view {
        (bytes32 lockSlot, bytes32 counterSlot, bytes32 tableNamespace) = _harness().checkpointNamespaces();
        bytes32 expectedRoot = tableNamespace.deriveMapping(uint256(1)).deriveMapping(CHECKPOINT_A);
        bytes32 actualRoot = _harness().checkpointRecordRoot(1, CHECKPOINT_A);

        assertNotEq(lockSlot, counterSlot, "lock/counter collision");
        assertNotEq(lockSlot, tableNamespace, "lock/table collision");
        assertNotEq(counterSlot, tableNamespace, "counter/table collision");
        assertNotEq(actualRoot, lockSlot, "record/lock collision");
        assertNotEq(actualRoot, counterSlot, "record/counter collision");
        assertEq(actualRoot, expectedRoot, "nested mapping derivation");
        assertNotEq(bytes32(uint256(actualRoot) + 1), bytes32(uint256(actualRoot) + 2), "field collision");
    }

    function test_DifferentDelegatedEoasUsingSameImplementationRemainIsolated() external {
        address payable secondAccount = _attachHarness(address(harnessImplementation), SECOND_HARNESS_AUTHORITY_KEY);
        token.setBalance(harnessAccount, 79);
        token.setBalance(secondAccount, 83);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(79, "first-account", _singleCheckpoint(address(token), CHECKPOINT_A));
        _harness().executeBatchDynamic(calls);

        assertEq(CheckpointTableHarness(secondAccount).invocationCounter(), 0, "counter leaked to second EOA");
        (bool leaked,,) = CheckpointTableHarness(secondAccount).checkpointRecord(1, CHECKPOINT_A);
        assertFalse(leaked, "checkpoint leaked to second EOA");

        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (83, bytes("second-account"))),
            _singleCheckpoint(address(token), CHECKPOINT_A)
        );
        CheckpointTableHarness(secondAccount).executeBatchDynamic(calls);
        (, address secondToken, uint256 secondBalance) =
            CheckpointTableHarness(secondAccount).checkpointRecord(1, CHECKPOINT_A);
        assertEq(secondToken, address(token), "second token");
        assertEq(secondBalance, 83, "second balance");
    }

    function test_RevertingBalanceReadPreservesReasonAndIndices() external {
        bytes memory payload = bytes("checkpoint-balance-revert");
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(89, payload);
        bytes memory reason = abi.encodeWithSelector(RevertingCheckpointToken.BalanceReadFailure.selector, 89, payload);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(revertingToken), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(89, "rolled-back", _noCheckpoints());
        calls[1] = _recordCall(97, "revert", checkpoints);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 1, 1, address(revertingToken), reason
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
        assertEq(target.count(), 0, "earlier target state must roll back");
    }

    function test_ShortSuccessfulBalanceReadPreservesMalformedBytes() external {
        ShortReturnCheckpointToken shortToken = new ShortReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(97, "short", _singleCheckpoint(address(shortToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(shortToken), hex"1234"
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_EmptySuccessfulBalanceReadFailsWithEmptyReason() external {
        EmptyReturnCheckpointToken emptyToken = new EmptyReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(101, "empty", _singleCheckpoint(address(emptyToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(emptyToken), bytes("")
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_UnauthorizedCallerFailsBeforeCounterOrBalanceRead() external {
        address randomCaller = address(0xCA11E2);
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(107, bytes("must-not-read"));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(107, "unauthorized", _singleCheckpoint(address(revertingToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, pair.customAccount, address(this)
            )
        );
        vm.prank(randomCaller);
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_Gas_CreateOneCheckpoint() external {
        _executeGasPlan(1, 0);
    }

    function test_Gas_CreateFourCheckpoints() external {
        _executeGasPlan(4, 0);
    }

    function test_Gas_CreateEightCheckpoints() external {
        _executeGasPlan(8, 0);
    }

    function test_Gas_CreateSixteenCheckpoints() external {
        _executeGasPlan(16, 0);
    }

    function test_Gas_CreateThirtyTwoCheckpoints() external {
        _executeGasPlan(32, 0);
    }

    function test_Gas_LookupHeavyOneCheckpoint() external {
        _executeGasPlan(1, 4);
    }

    function test_Gas_LookupHeavyFourCheckpoints() external {
        _executeGasPlan(4, 4);
    }

    function test_Gas_LookupHeavyEightCheckpoints() external {
        _executeGasPlan(8, 4);
    }

    function test_Gas_LookupHeavySixteenCheckpoints() external {
        _executeGasPlan(16, 4);
    }

    function test_Gas_LookupHeavyThirtyTwoCheckpoints() external {
        _executeGasPlan(32, 4);
    }

    function _executeGasPlan(uint256 checkpointCount, uint256 lookupRepetitions) private {
        token.setBalance(harnessAccount, 109);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](checkpointCount);
        bytes32[] memory checkpointIds = new bytes32[](checkpointCount);
        for (uint256 i = 0; i < checkpointCount; ++i) {
            bytes32 checkpointId = bytes32(i + 1);
            checkpointIds[i] = checkpointId;
            checkpoints[i] = _checkpoint(address(token), checkpointId);
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(1, "gas", checkpoints);
        _harness().executeBatchDynamic(calls);

        if (lookupRepetitions != 0) {
            uint256 sum = _harness().probeCheckpoints(1, checkpointIds, lookupRepetitions);
            assertEq(sum, checkpointCount * lookupRepetitions * 109, "lookup sum");
        }
    }

    function _attachHarness(address implementation, uint256 authorityKey) private returns (address payable account) {
        account = payable(vm.addr(authorityKey));
        require(account.code.length == 0, "harness authority already has code");
        vm.signAndAttachDelegation(implementation, authorityKey);
        require(_delegationTarget(account) == implementation, "wrong harness delegation target");
    }

    function _harness() private view returns (CheckpointTableHarness) {
        return CheckpointTableHarness(harnessAccount);
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
