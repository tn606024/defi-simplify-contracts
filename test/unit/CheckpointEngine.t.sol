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

    DelegatedDefiSimplifyAccount private accountUnderTest;
    DynamicExecutionTarget private executionTarget;
    CheckpointBalanceToken private checkpointToken;
    CheckpointTableHarness private checkpointHarnessImplementation;
    address payable private harnessAccount;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        executionTarget = new DynamicExecutionTarget();
        checkpointToken = new CheckpointBalanceToken();
        checkpointHarnessImplementation = new CheckpointTableHarness(IEntryPoint(address(this)));
        harnessAccount =
            _attachCheckpointHarnessDelegation(address(checkpointHarnessImplementation), HARNESS_AUTHORITY_KEY);
    }

    function test_Gas_OneCheckpointUsesDelegatedAccountBalanceImmediatelyBeforeTarget() external {
        PreCallCheckpointToken preCallToken =
            new PreCallCheckpointToken(accountUnderTest.delegatedEoa, address(executionTarget), 0, 101);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(11, "one", _oneCheckpoint(address(preCallToken), CHECKPOINT_A));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.count(), 1, "target call count");
        assertEq(executionTarget.total(), 11, "target amount");
        assertEq(executionTarget.lastCaller(), accountUnderTest.delegatedEoa, "delegated caller");
    }

    function test_Gas_MultipleCheckpointsAreCreatedImmediatelyBeforeTheirTargets() external {
        PreCallCheckpointToken firstToken =
            new PreCallCheckpointToken(accountUnderTest.delegatedEoa, address(executionTarget), 0, 201);
        PreCallCheckpointToken secondToken =
            new PreCallCheckpointToken(accountUnderTest.delegatedEoa, address(executionTarget), 1, 202);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(13, "first", _oneCheckpoint(address(firstToken), CHECKPOINT_A));
        calls[1] = _buildRecordingCall(17, "second", _oneCheckpoint(address(secondToken), CHECKPOINT_B));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.count(), 2, "target call count");
        assertEq(executionTarget.total(), 30, "target amount");
    }

    function test_ZeroBalanceHasIndependentPresenceTokenAndBalanceFields() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(19, "zero", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));

        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        (bool present, address storedToken, uint256 balance) =
            _delegatedCheckpointHarnessView().checkpointRecord(1, CHECKPOINT_A);
        assertTrue(present, "zero balance checkpoint absent");
        assertEq(storedToken, address(checkpointToken), "stored token");
        assertEq(balance, 0, "stored zero balance");
    }

    function test_ZeroTokenRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(0), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(23, "rolled-back", _noCheckpoints());
        calls[1] = _buildRecordingCall(29, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointToken.selector, 1, 1));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.count(), 0, "earlier call must roll back");
    }

    function test_ZeroIdRevertsWithCallAndCheckpointIndices() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(checkpointToken), bytes32(0));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(31, "invalid", checkpoints);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointId.selector, 0, 1));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.count(), 0, "target must not execute");
    }

    function test_DuplicateIdOnSameTokenRevertsAtSecondCheckpoint() external {
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(37, "duplicate", checkpoints);

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 0, 1, CHECKPOINT_A)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_DuplicateIdAcrossDifferentTokensAndCallsRevertsInActiveScope() external {
        CheckpointBalanceToken otherToken = new CheckpointBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(41, "first", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));
        calls[1] = _buildRecordingCall(43, "duplicate", _oneCheckpoint(address(otherToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 1, 0, CHECKPOINT_A)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.count(), 0, "earlier call must roll back");
    }

    function test_SameTokenSupportsMultipleDistinctCheckpointIds() external {
        checkpointToken.setBalance(accountUnderTest.delegatedEoa, 47);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(checkpointToken), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(47, "same-token", checkpoints);

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(executionTarget.total(), 47, "target amount");
    }

    function test_SequentialInvocationsUseDisjointScopesAndMayReuseId() external {
        checkpointToken.setBalance(harnessAccount, 53);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(53, "first", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        checkpointToken.setBalance(harnessAccount, 59);
        calls[0] = _buildRecordingCall(59, "second", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        assertEq(_delegatedCheckpointHarnessView().invocationCounter(), 2, "invocation counter");
        (bool firstPresent, address firstToken, uint256 firstBalance) =
            _delegatedCheckpointHarnessView().checkpointRecord(1, CHECKPOINT_A);
        (bool secondPresent, address secondToken, uint256 secondBalance) =
            _delegatedCheckpointHarnessView().checkpointRecord(2, CHECKPOINT_A);
        assertTrue(firstPresent && secondPresent, "scoped records absent");
        assertEq(firstToken, address(checkpointToken), "first token");
        assertEq(secondToken, address(checkpointToken), "second token");
        assertEq(firstBalance, 53, "first balance");
        assertEq(secondBalance, 59, "second balance");
    }

    function test_RevertedInvocationRollsBackCounterAndRecordsTogether() external {
        checkpointToken.setBalance(harnessAccount, 61);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(61, "first", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        checkpointToken.setBalance(harnessAccount, 67);
        calls[0] = _buildDynamicCall(
            address(executionTarget),
            abi.encodeCall(DynamicExecutionTarget.fail, (67, bytes("rollback"))),
            _oneCheckpoint(address(checkpointToken), CHECKPOINT_B)
        );
        (bool success,) = harnessAccount.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        assertFalse(success, "failing invocation succeeded");

        assertEq(_delegatedCheckpointHarnessView().invocationCounter(), 1, "reverted counter persisted");
        (bool revertedPresent,,) = _delegatedCheckpointHarnessView().checkpointRecord(2, CHECKPOINT_B);
        assertFalse(revertedPresent, "reverted checkpoint persisted");

        calls[0] = _buildRecordingCall(71, "recovered", _oneCheckpoint(address(checkpointToken), CHECKPOINT_B));
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);
        assertEq(_delegatedCheckpointHarnessView().invocationCounter(), 2, "counter did not reuse rolled-back scope");
        (bool recoveredPresent,, uint256 recoveredBalance) =
            _delegatedCheckpointHarnessView().checkpointRecord(2, CHECKPOINT_B);
        assertTrue(recoveredPresent, "recovered checkpoint absent");
        assertEq(recoveredBalance, 67, "recovered checkpoint balance");
    }

    function test_ContainingFrameRevertRollsBackCounterAndRecords() external {
        RevertingCheckpointEntryPoint entryPoint = new RevertingCheckpointEntryPoint();
        CheckpointTableHarness implementation = new CheckpointTableHarness(IEntryPoint(address(entryPoint)));
        address payable account =
            _attachCheckpointHarnessDelegation(address(implementation), CONTAINED_HARNESS_AUTHORITY_KEY);
        checkpointToken.setBalance(account, 73);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(
            address(executionTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (73, bytes("contained"))),
            _oneCheckpoint(address(checkpointToken), CHECKPOINT_A)
        );

        (bool success,) =
            address(entryPoint).call(abi.encodeCall(RevertingCheckpointEntryPoint.invoke, (account, calls)));
        assertFalse(success, "containing frame unexpectedly succeeded");
        assertEq(executionTarget.count(), 0, "target state survived containing revert");

        vm.prank(account);
        assertEq(CheckpointTableHarness(account).invocationCounter(), 0, "counter survived containing revert");
        vm.prank(account);
        (bool present,,) = CheckpointTableHarness(account).checkpointRecord(1, CHECKPOINT_A);
        assertFalse(present, "record survived containing revert");
    }

    function test_OrdinaryCallTargetCannotSeeAccountTransientRecord() external {
        TransientProbeTarget probeTarget = new TransientProbeTarget();
        bytes32 recordRoot = _delegatedCheckpointHarnessView().checkpointRecordRoot(1, CHECKPOINT_A);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(
            address(probeTarget),
            abi.encodeCall(TransientProbeTarget.probe, (recordRoot)),
            _oneCheckpoint(address(checkpointToken), CHECKPOINT_A)
        );

        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        assertEq(probeTarget.lastObserved(), bytes32(0), "target observed account transient state");
        (bool present,,) = _delegatedCheckpointHarnessView().checkpointRecord(1, CHECKPOINT_A);
        assertTrue(present, "account record absent");
    }

    function test_CallbackCannotQueryCheckpointHarness() external {
        TransientProbeTarget probeTarget = new TransientProbeTarget();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(
            address(probeTarget),
            abi.encodeCall(TransientProbeTarget.queryCheckpointHarness, (harnessAccount, 1, CHECKPOINT_A)),
            _oneCheckpoint(address(checkpointToken), CHECKPOINT_A)
        );
        bytes memory authorizationReason = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector, address(probeTarget), harnessAccount, address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(probeTarget), authorizationReason
            )
        );
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);
    }

    function test_NamespacesAndNestedRecordLayoutAreDistinct() external view {
        (bytes32 dynamicExecutionLockSlot, bytes32 invocationCounterSlot, bytes32 checkpointTableRoot) =
            _delegatedCheckpointHarnessView().transientCheckpointLayout();
        bytes32 expectedRoot = checkpointTableRoot.deriveMapping(uint256(1)).deriveMapping(CHECKPOINT_A);
        bytes32 actualRoot = _delegatedCheckpointHarnessView().checkpointRecordRoot(1, CHECKPOINT_A);

        assertNotEq(dynamicExecutionLockSlot, invocationCounterSlot, "lock/counter collision");
        assertNotEq(dynamicExecutionLockSlot, checkpointTableRoot, "lock/table collision");
        assertNotEq(invocationCounterSlot, checkpointTableRoot, "counter/table collision");
        assertNotEq(actualRoot, dynamicExecutionLockSlot, "record/lock collision");
        assertNotEq(actualRoot, invocationCounterSlot, "record/counter collision");
        assertEq(actualRoot, expectedRoot, "nested mapping derivation");
        assertNotEq(bytes32(uint256(actualRoot) + 1), bytes32(uint256(actualRoot) + 2), "field collision");
    }

    function test_DifferentDelegatedEoasUsingSameImplementationRemainIsolated() external {
        address payable secondAccount =
            _attachCheckpointHarnessDelegation(address(checkpointHarnessImplementation), SECOND_HARNESS_AUTHORITY_KEY);
        checkpointToken.setBalance(harnessAccount, 79);
        checkpointToken.setBalance(secondAccount, 83);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(79, "first-account", _oneCheckpoint(address(checkpointToken), CHECKPOINT_A));
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        assertEq(CheckpointTableHarness(secondAccount).invocationCounter(), 0, "counter leaked to second EOA");
        (bool leaked,,) = CheckpointTableHarness(secondAccount).checkpointRecord(1, CHECKPOINT_A);
        assertFalse(leaked, "checkpoint leaked to second EOA");

        calls[0] = _buildDynamicCall(
            address(executionTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (83, bytes("second-account"))),
            _oneCheckpoint(address(checkpointToken), CHECKPOINT_A)
        );
        CheckpointTableHarness(secondAccount).executeBatchDynamic(calls);
        (, address secondToken, uint256 secondBalance) =
            CheckpointTableHarness(secondAccount).checkpointRecord(1, CHECKPOINT_A);
        assertEq(secondToken, address(checkpointToken), "second token");
        assertEq(secondBalance, 83, "second balance");
    }

    function test_RevertingBalanceReadPreservesReasonAndIndices() external {
        bytes memory payload = bytes("checkpoint-balance-revert");
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(89, payload);
        bytes memory reason = abi.encodeWithSelector(RevertingCheckpointToken.BalanceReadFailure.selector, 89, payload);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(checkpointToken), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(revertingToken), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(89, "rolled-back", _noCheckpoints());
        calls[1] = _buildRecordingCall(97, "revert", checkpoints);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 1, 1, address(revertingToken), reason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(executionTarget.count(), 0, "earlier target state must roll back");
    }

    function test_ShortSuccessfulBalanceReadPreservesMalformedBytes() external {
        ShortReturnCheckpointToken shortToken = new ShortReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(97, "short", _oneCheckpoint(address(shortToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(shortToken), hex"1234"
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_EmptySuccessfulBalanceReadFailsWithEmptyReason() external {
        EmptyReturnCheckpointToken emptyToken = new EmptyReturnCheckpointToken();
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(101, "empty", _oneCheckpoint(address(emptyToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 0, 0, address(emptyToken), bytes("")
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_UnauthorizedCallerFailsBeforeCounterOrBalanceRead() external {
        address randomCaller = address(0xCA11E2);
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(107, bytes("must-not-read"));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(107, "unauthorized", _oneCheckpoint(address(revertingToken), CHECKPOINT_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, accountUnderTest.delegatedEoa, address(this)
            )
        );
        vm.prank(randomCaller);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_Gas_CreateOneCheckpoint() external {
        _executeCheckpointGasScenario(1, 0);
    }

    function test_Gas_CreateFourCheckpoints() external {
        _executeCheckpointGasScenario(4, 0);
    }

    function test_Gas_CreateEightCheckpoints() external {
        _executeCheckpointGasScenario(8, 0);
    }

    function test_Gas_CreateSixteenCheckpoints() external {
        _executeCheckpointGasScenario(16, 0);
    }

    function test_Gas_CreateThirtyTwoCheckpoints() external {
        _executeCheckpointGasScenario(32, 0);
    }

    function test_Gas_LookupHeavyOneCheckpoint() external {
        _executeCheckpointGasScenario(1, 4);
    }

    function test_Gas_LookupHeavyFourCheckpoints() external {
        _executeCheckpointGasScenario(4, 4);
    }

    function test_Gas_LookupHeavyEightCheckpoints() external {
        _executeCheckpointGasScenario(8, 4);
    }

    function test_Gas_LookupHeavySixteenCheckpoints() external {
        _executeCheckpointGasScenario(16, 4);
    }

    function test_Gas_LookupHeavyThirtyTwoCheckpoints() external {
        _executeCheckpointGasScenario(32, 4);
    }

    function _executeCheckpointGasScenario(uint256 checkpointCount, uint256 lookupRepetitions) private {
        checkpointToken.setBalance(harnessAccount, 109);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](checkpointCount);
        bytes32[] memory checkpointIds = new bytes32[](checkpointCount);
        for (uint256 i = 0; i < checkpointCount; ++i) {
            bytes32 checkpointId = bytes32(i + 1);
            checkpointIds[i] = checkpointId;
            checkpoints[i] = _checkpoint(address(checkpointToken), checkpointId);
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(1, "gas", checkpoints);
        _delegatedCheckpointHarnessView().executeBatchDynamic(calls);

        if (lookupRepetitions != 0) {
            uint256 sum = _delegatedCheckpointHarnessView().probeCheckpoints(1, checkpointIds, lookupRepetitions);
            assertEq(sum, checkpointCount * lookupRepetitions * 109, "lookup sum");
        }
    }

    function _attachCheckpointHarnessDelegation(address implementation, uint256 authorityKey)
        private
        returns (address payable account)
    {
        account = payable(vm.addr(authorityKey));
        require(account.code.length == 0, "harness authority already has code");
        vm.signAndAttachDelegation(implementation, authorityKey);
        require(_delegationTarget(account) == implementation, "wrong harness delegation target");
    }

    function _delegatedCheckpointHarnessView() private view returns (CheckpointTableHarness) {
        return CheckpointTableHarness(harnessAccount);
    }

    function _buildRecordingCall(
        uint256 amount,
        bytes memory payload,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints
    ) private view returns (IDefiSimplify7702Account.DynamicCall memory) {
        return _buildDynamicCall(
            address(executionTarget), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)), checkpoints
        );
    }

    function _buildDynamicCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _oneCheckpoint(address checkpointTokenAddress, bytes32 id)
        private
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = _checkpoint(checkpointTokenAddress, id);
    }

    function _noCheckpoints() private pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _checkpoint(address checkpointTokenAddress, bytes32 id)
        private
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint memory)
    {
        return IDefiSimplify7702Account.BalanceCheckpoint({token: checkpointTokenAddress, id: id});
    }
}
