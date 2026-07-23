// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CheckpointTableHarness, DynamicPatchTarget, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Stateful action handler configured as the delegated account's mock EntryPoint.
///      Each action executes one transaction-local scenario and checks the active
///      transient scope before returning control to Foundry's invariant runner.
contract DynamicEngineInvariantHandler {
    address private immutable _initializer;

    /// @dev Delegated EOA viewed through the test-only checkpoint inspector ABI.
    CheckpointTableHarness public delegatedAccount;
    /// @dev Token whose modeled balances drive checkpoint and patch actions.
    PatchBalanceToken public immutable balanceToken;
    /// @dev Stateful target compared with the handler's successful-call model.
    DynamicExecutionTarget public immutable recordingTarget;
    /// @dev Calldata capture target used for checkpoint-only invocations.
    DynamicPatchTarget public immutable calldataCaptureTarget;

    /// @dev Number of target records expected from successful modeled actions.
    uint256 public expectedSuccessfulCallCount;
    /// @dev Sum of target amounts expected from successful modeled actions.
    uint256 public expectedSuccessfulAmountTotal;

    constructor() {
        _initializer = msg.sender;
        balanceToken = new PatchBalanceToken();
        recordingTarget = new DynamicExecutionTarget();
        calldataCaptureTarget = new DynamicPatchTarget();
    }

    /// @dev Binds the one delegated account after its implementation has been constructed
    ///      with this handler as EntryPoint. This test-only initialization is single use.
    /// @param delegatedEoa The EOA carrying the test implementation delegation.
    function initialize(address payable delegatedEoa) external {
        require(msg.sender == _initializer, "not invariant initializer");
        require(address(delegatedAccount) == address(0), "invariant account initialized");
        delegatedAccount = CheckpointTableHarness(delegatedEoa);
    }

    /// @dev Exercises a CurrentBalance patch and updates the successful-call model.
    /// @param balance The modeled account token balance.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    function exerciseCurrentBalance(uint128 balance, uint16 rawBps) external {
        uint16 bps = _validBps(rawBps);
        balanceToken.setBalance(address(delegatedAccount), balance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(_onePatch(_currentBalancePatch(4, bps)));
        delegatedAccount.executeBatchDynamic(calls);

        expectedSuccessfulCallCount += 1;
        expectedSuccessfulAmountTotal += Math.mulDiv(uint256(balance), uint256(bps), 10_000);
    }

    /// @dev Exercises a producer checkpoint followed by a CheckpointDelta consumer.
    /// @param inventory Token inventory that must be excluded from the resolved delta.
    /// @param produced Token amount produced after checkpoint creation.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseCheckpointDelta(uint128 inventory, uint128 produced, uint16 rawBps, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint16 bps = _validBps(rawBps);
        balanceToken.setBalance(address(delegatedAccount), inventory);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildDynamicCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(produced))),
            _oneCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _buildRecordingCall(_onePatch(_checkpointDeltaPatch(checkpointId, 4, bps)));
        delegatedAccount.executeBatchDynamic(calls);

        expectedSuccessfulCallCount += 1;
        expectedSuccessfulAmountTotal += Math.mulDiv(uint256(produced), uint256(bps), 10_000);
    }

    /// @dev Reuses one logical checkpoint ID across two invocation scopes.
    /// @param firstBalance Balance recorded by the first invocation.
    /// @param secondBalance Balance recorded by the second invocation.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseSameIdSequentialInvocations(uint128 firstBalance, uint128 secondBalance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = delegatedAccount.invocationCounter();
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildCheckpointOnlyBatch(checkpointId);

        balanceToken.setBalance(address(delegatedAccount), firstBalance);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        balanceToken.setBalance(address(delegatedAccount), secondBalance);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 2, checkpointId, secondBalance);
        require(delegatedAccount.invocationCounter() == baseline + 2, "sequential counter mismatch");
    }

    /// @dev Proves failed invocation records and counter increments roll back atomically.
    /// @param firstBalance Balance committed by the preceding successful invocation.
    /// @param failedBalance Balance observed only inside the reverted invocation.
    /// @param recoveredBalance Balance recorded when the rolled-back scope is reused.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseRevertedScopeRollback(
        uint128 firstBalance,
        uint128 failedBalance,
        uint128 recoveredBalance,
        bytes32 rawId
    ) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = delegatedAccount.invocationCounter();
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildCheckpointOnlyBatch(checkpointId);

        balanceToken.setBalance(address(delegatedAccount), firstBalance);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        balanceToken.setBalance(address(delegatedAccount), failedBalance);
        calls[0] = _buildDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.fail, (uint256(51), bytes("invariant-rollback"))),
            _oneCheckpoint(checkpointId),
            _noPatches()
        );
        bytes memory targetReason =
            abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 51, bytes("invariant-rollback"));
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(recordingTarget), targetReason
            )
        );

        require(delegatedAccount.invocationCounter() == baseline + 1, "reverted counter persisted");
        (bool revertedPresent,,) = delegatedAccount.checkpointRecord(baseline + 2, checkpointId);
        require(!revertedPresent, "reverted record persisted");

        balanceToken.setBalance(address(delegatedAccount), recoveredBalance);
        calls = _buildCheckpointOnlyBatch(checkpointId);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 2, checkpointId, recoveredBalance);
    }

    /// @dev Proves a later invocation cannot consume a prior invocation's checkpoint.
    /// @param firstBalance Balance recorded in the stale scope.
    /// @param recoveredBalance Balance recorded after the rejected lookup rolls back.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseStaleScopeRejection(uint128 firstBalance, uint128 recoveredBalance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = delegatedAccount.invocationCounter();
        balanceToken.setBalance(address(delegatedAccount), firstBalance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildCheckpointOnlyBatch(checkpointId);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(_onePatch(_checkpointDeltaPatch(checkpointId, 4, 10_000)));
        _requireExecutionRevert(
            calls, abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, checkpointId)
        );
        require(delegatedAccount.invocationCounter() == baseline + 1, "stale lookup counter persisted");

        balanceToken.setBalance(address(delegatedAccount), recoveredBalance);
        calls = _buildCheckpointOnlyBatch(checkpointId);
        delegatedAccount.executeBatchDynamic(calls);
        _requireRecord(baseline + 2, checkpointId, recoveredBalance);
    }

    /// @dev Proves a negative checkpoint delta reverts all transient and token state.
    /// @param rawBalance Input used to derive a nonzero checkpoint balance.
    /// @param rawConsumed Input used to derive an amount consumed after the checkpoint.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseNegativeDeltaRollback(uint128 rawBalance, uint128 rawConsumed, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 checkpointBalance = uint256(rawBalance) + 1;
        uint256 consumed = uint256(rawConsumed) % checkpointBalance + 1;
        uint256 currentBalance = checkpointBalance - consumed;
        uint256 baseline = delegatedAccount.invocationCounter();
        uint256 targetCountBefore = recordingTarget.count();
        uint256 targetTotalBefore = recordingTarget.total();
        balanceToken.setBalance(address(delegatedAccount), checkpointBalance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildDynamicCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.consume, (consumed)),
            _oneCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _buildRecordingCall(_onePatch(_checkpointDeltaPatch(checkpointId, 4, 10_000)));
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.BalanceBelowCheckpoint.selector,
                1,
                0,
                address(balanceToken),
                checkpointId,
                currentBalance,
                checkpointBalance
            )
        );

        require(delegatedAccount.invocationCounter() == baseline, "negative-delta counter persisted");
        require(
            balanceToken.balanceOf(address(delegatedAccount)) == checkpointBalance,
            "negative-delta token state persisted"
        );
        require(recordingTarget.count() == targetCountBefore, "negative-delta target count changed");
        require(recordingTarget.total() == targetTotalBefore, "negative-delta target total changed");
    }

    /// @dev Proves duplicate checkpoint IDs revert the invocation counter and records.
    /// @param balance Balance available when both checkpoints attempt to read.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseDuplicateIdRollback(uint128 balance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = delegatedAccount.invocationCounter();
        balanceToken.setBalance(address(delegatedAccount), balance);

        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(checkpointId);
        checkpoints[1] = _checkpoint(checkpointId);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(address(calldataCaptureTarget), hex"deadbeef", checkpoints, _noPatches());

        _requireExecutionRevert(
            calls, abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 0, 1, checkpointId)
        );
        require(delegatedAccount.invocationCounter() == baseline, "duplicate-id counter persisted");
    }

    /// @dev Proves a later target failure rolls back an earlier target mutation.
    /// @param amount Amount recorded by the call that must be rolled back.
    /// @param rawPayload Arbitrary nested revert payload material.
    function exerciseAtomicTargetRollback(uint128 amount, bytes32 rawPayload) external {
        uint256 baseline = delegatedAccount.invocationCounter();
        uint256 targetCountBefore = recordingTarget.count();
        uint256 targetTotalBefore = recordingTarget.total();
        bytes memory payload = abi.encodePacked(rawPayload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(amount), bytes("must-roll-back"))),
            _noCheckpoints(),
            _noPatches()
        );
        calls[1] = _buildDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.fail, (uint256(52), payload)),
            _noCheckpoints(),
            _noPatches()
        );
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 52, payload);
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(recordingTarget), targetReason
            )
        );

        require(delegatedAccount.invocationCounter() == baseline, "target-revert counter persisted");
        require(recordingTarget.count() == targetCountBefore, "target-revert count persisted");
        require(recordingTarget.total() == targetTotalBefore, "target-revert total persisted");
    }

    function _requireRecord(uint256 invocationId, bytes32 checkpointId, uint256 expectedBalance) private view {
        (bool present, address storedToken, uint256 storedBalance) =
            delegatedAccount.checkpointRecord(invocationId, checkpointId);
        require(present, "checkpoint record missing");
        require(storedToken == address(balanceToken), "checkpoint token mismatch");
        require(storedBalance == expectedBalance, "checkpoint balance mismatch");
    }

    function _requireExecutionRevert(IDefiSimplify7702Account.DynamicCall[] memory calls, bytes memory expectedReason)
        private
    {
        (bool success, bytes memory reason) =
            address(delegatedAccount).call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        require(!success, "expected dynamic execution revert");
        require(keccak256(reason) == keccak256(expectedReason), "unexpected dynamic execution revert");
    }

    function _buildCheckpointOnlyBatch(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(
            address(calldataCaptureTarget), hex"deadbeef", _oneCheckpoint(checkpointId), _noPatches()
        );
    }

    function _buildRecordingCall(IDefiSimplify7702Account.BalancePatch[] memory patches)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _buildDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("invariant"))),
            _noCheckpoints(),
            patches
        );
    }

    function _buildDynamicCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = patches;
    }

    function _checkpoint(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.BalanceCheckpoint memory)
    {
        return IDefiSimplify7702Account.BalanceCheckpoint({token: address(balanceToken), id: checkpointId});
    }

    function _oneCheckpoint(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = _checkpoint(checkpointId);
    }

    function _noCheckpoints() private pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _onePatch(IDefiSimplify7702Account.BalancePatch memory patch)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch[] memory patches)
    {
        patches = new IDefiSimplify7702Account.BalancePatch[](1);
        patches[0] = patch;
    }

    function _noPatches() private pure returns (IDefiSimplify7702Account.BalancePatch[] memory patches) {
        patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _currentBalancePatch(uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(balanceToken),
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    function _checkpointDeltaPatch(bytes32 checkpointId, uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(balanceToken),
            checkpointId: checkpointId,
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
    }

    function _validBps(uint16 rawBps) private pure returns (uint16) {
        return uint16(uint256(rawBps) % 10_000 + 1);
    }

    function _validId(bytes32 rawId) private pure returns (bytes32) {
        return rawId == bytes32(0) ? bytes32(uint256(1)) : rawId;
    }
}

/// @dev Stateful and deterministic verification for the complete dynamic engine.
contract DynamicEngineInvariantTest is DelegatedAccountFixture {
    uint256 private constant INVARIANT_AUTHORITY_KEY =
        0x71f99d742cecae7c01849d43c198ee58613bf258a1b696f2dadc695a67b90f42;

    DynamicEngineInvariantHandler private scenarioHandler;
    CheckpointTableHarness private checkpointHarnessImplementation;
    address payable private delegatedEoa;

    /// @dev Installs a real EIP-7702 delegation and restricts the invariant runner
    ///      to the handler's modeled actions.
    function setUp() external {
        scenarioHandler = new DynamicEngineInvariantHandler();
        checkpointHarnessImplementation = new CheckpointTableHarness(IEntryPoint(address(scenarioHandler)));
        delegatedEoa = payable(vm.addr(INVARIANT_AUTHORITY_KEY));
        require(delegatedEoa.code.length == 0, "invariant authority already has code");
        vm.signAndAttachDelegation(address(checkpointHarnessImplementation), INVARIANT_AUTHORITY_KEY);
        require(
            _delegationTarget(delegatedEoa) == address(checkpointHarnessImplementation),
            "wrong invariant delegation target"
        );
        scenarioHandler.initialize(delegatedEoa);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = scenarioHandler.exerciseCurrentBalance.selector;
        selectors[1] = scenarioHandler.exerciseCheckpointDelta.selector;
        selectors[2] = scenarioHandler.exerciseSameIdSequentialInvocations.selector;
        selectors[3] = scenarioHandler.exerciseRevertedScopeRollback.selector;
        selectors[4] = scenarioHandler.exerciseStaleScopeRejection.selector;
        selectors[5] = scenarioHandler.exerciseNegativeDeltaRollback.selector;
        selectors[6] = scenarioHandler.exerciseDuplicateIdRollback.selector;
        selectors[7] = scenarioHandler.exerciseAtomicTargetRollback.selector;
        targetContract(address(scenarioHandler));
        targetSelector(FuzzSelector({addr: address(scenarioHandler), selectors: selectors}));
    }

    /// @dev Target state must equal only the handler actions that returned successfully.
    function invariant_TargetStateMatchesSuccessfulActionModel() external view {
        DynamicExecutionTarget recordingTarget = scenarioHandler.recordingTarget();
        assertEq(recordingTarget.count(), scenarioHandler.expectedSuccessfulCallCount(), "invariant target count");
        assertEq(recordingTarget.total(), scenarioHandler.expectedSuccessfulAmountTotal(), "invariant target total");
        if (recordingTarget.count() != 0) {
            assertEq(recordingTarget.lastCaller(), delegatedEoa, "invariant delegated caller");
        }
    }

    /// @dev Dynamic activity must never replace or remove the EIP-7702 delegation.
    function invariant_DelegationTargetRemainsInstalled() external view {
        assertEq(delegatedEoa.code.length, 23, "delegation indicator length");
        assertEq(_delegationTarget(delegatedEoa), address(checkpointHarnessImplementation), "delegation target changed");
    }

    /// @dev Records SSTORE access to prove dynamic execution has no permanent account writes.
    function test_DynamicExecutionWritesNoPermanentAccountStorage() external {
        PatchBalanceToken balanceToken = scenarioHandler.balanceToken();
        balanceToken.setBalance(delegatedEoa, 123);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(scenarioHandler.calldataCaptureTarget());
        calls[0].data = hex"deadbeef";
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        calls[0].checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: address(balanceToken), id: bytes32(uint256(1))});
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);

        vm.record();
        vm.prank(address(scenarioHandler));
        IDefiSimplify7702Account(delegatedEoa).executeBatchDynamic(calls);
        (, bytes32[] memory permanentWrites) = vm.accesses(delegatedEoa);

        assertEq(permanentWrites.length, 0, "dynamic execution wrote permanent delegatedEoa storage");
    }

    /// @dev Proves inherited static execution remains usable around a dynamic invocation.
    function test_InheritedStaticExecutionRemainsUsableBeforeAndAfterDynamicInvocation() external {
        DynamicExecutionTarget recordingTarget = scenarioHandler.recordingTarget();

        vm.prank(delegatedEoa);
        BaseAccount(delegatedEoa)
            .execute(
                address(recordingTarget),
                0,
                abi.encodeCall(DynamicExecutionTarget.record, (uint256(11), bytes("static-before")))
            );

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(recordingTarget);
        calls[0].data = abi.encodeCall(DynamicExecutionTarget.record, (uint256(13), bytes("dynamic")));
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
        vm.prank(delegatedEoa);
        IDefiSimplify7702Account(delegatedEoa).executeBatchDynamic(calls);

        vm.prank(delegatedEoa);
        BaseAccount(delegatedEoa)
            .execute(
                address(recordingTarget),
                0,
                abi.encodeCall(DynamicExecutionTarget.record, (uint256(17), bytes("static-after")))
            );

        assertEq(recordingTarget.count(), 3, "static/dynamic/static count");
        assertEq(recordingTarget.total(), 41, "static/dynamic/static total");
        assertEq(recordingTarget.lastCaller(), delegatedEoa, "static/dynamic/static delegated caller");
    }
}
