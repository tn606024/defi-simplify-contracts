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
    CheckpointTableHarness public account;
    /// @dev Token whose modeled balances drive checkpoint and patch actions.
    PatchBalanceToken public immutable token;
    /// @dev Stateful target compared with the handler's successful-call model.
    DynamicExecutionTarget public immutable target;
    /// @dev Calldata capture target used for checkpoint-only invocations.
    DynamicPatchTarget public immutable patchTarget;

    /// @dev Number of target records expected from successful modeled actions.
    uint256 public modelTargetCount;
    /// @dev Sum of target amounts expected from successful modeled actions.
    uint256 public modelTargetTotal;

    constructor() {
        _initializer = msg.sender;
        token = new PatchBalanceToken();
        target = new DynamicExecutionTarget();
        patchTarget = new DynamicPatchTarget();
    }

    /// @dev Binds the one delegated account after its implementation has been constructed
    ///      with this handler as EntryPoint. This test-only initialization is single use.
    /// @param delegatedAccount The EOA carrying the test implementation delegation.
    function initialize(address payable delegatedAccount) external {
        require(msg.sender == _initializer, "not invariant initializer");
        require(address(account) == address(0), "invariant account initialized");
        account = CheckpointTableHarness(delegatedAccount);
    }

    /// @dev Exercises a CurrentBalance patch and updates the successful-call model.
    /// @param balance The modeled account token balance.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    function exerciseCurrentBalance(uint128 balance, uint16 rawBps) external {
        uint16 bps = _validBps(rawBps);
        token.setBalance(address(account), balance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(_singlePatch(_currentPatch(4, bps)));
        account.executeBatchDynamic(calls);

        modelTargetCount += 1;
        modelTargetTotal += Math.mulDiv(uint256(balance), uint256(bps), 10_000);
    }

    /// @dev Exercises a producer checkpoint followed by a CheckpointDelta consumer.
    /// @param inventory Token inventory that must be excluded from the resolved delta.
    /// @param produced Token amount produced after checkpoint creation.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseCheckpointDelta(uint128 inventory, uint128 produced, uint16 rawBps, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint16 bps = _validBps(rawBps);
        token.setBalance(address(account), inventory);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(produced))),
            _singleCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _recordCall(_singlePatch(_deltaPatch(checkpointId, 4, bps)));
        account.executeBatchDynamic(calls);

        modelTargetCount += 1;
        modelTargetTotal += Math.mulDiv(uint256(produced), uint256(bps), 10_000);
    }

    /// @dev Reuses one logical checkpoint ID across two invocation scopes.
    /// @param firstBalance Balance recorded by the first invocation.
    /// @param secondBalance Balance recorded by the second invocation.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseSameIdSequentialInvocations(uint128 firstBalance, uint128 secondBalance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = account.invocationCounter();
        IDefiSimplify7702Account.DynamicCall[] memory calls = _checkpointOnlyCall(checkpointId);

        token.setBalance(address(account), firstBalance);
        account.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        token.setBalance(address(account), secondBalance);
        account.executeBatchDynamic(calls);
        _requireRecord(baseline + 2, checkpointId, secondBalance);
        require(account.invocationCounter() == baseline + 2, "sequential counter mismatch");
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
        uint256 baseline = account.invocationCounter();
        IDefiSimplify7702Account.DynamicCall[] memory calls = _checkpointOnlyCall(checkpointId);

        token.setBalance(address(account), firstBalance);
        account.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        token.setBalance(address(account), failedBalance);
        calls[0] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.fail, (uint256(51), bytes("invariant-rollback"))),
            _singleCheckpoint(checkpointId),
            _noPatches()
        );
        bytes memory targetReason =
            abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 51, bytes("invariant-rollback"));
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(target), targetReason
            )
        );

        require(account.invocationCounter() == baseline + 1, "reverted counter persisted");
        (bool revertedPresent,,) = account.checkpointRecord(baseline + 2, checkpointId);
        require(!revertedPresent, "reverted record persisted");

        token.setBalance(address(account), recoveredBalance);
        calls = _checkpointOnlyCall(checkpointId);
        account.executeBatchDynamic(calls);
        _requireRecord(baseline + 2, checkpointId, recoveredBalance);
    }

    /// @dev Proves a later invocation cannot consume a prior invocation's checkpoint.
    /// @param firstBalance Balance recorded in the stale scope.
    /// @param recoveredBalance Balance recorded after the rejected lookup rolls back.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseStaleScopeRejection(uint128 firstBalance, uint128 recoveredBalance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = account.invocationCounter();
        token.setBalance(address(account), firstBalance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = _checkpointOnlyCall(checkpointId);
        account.executeBatchDynamic(calls);
        _requireRecord(baseline + 1, checkpointId, firstBalance);

        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(_singlePatch(_deltaPatch(checkpointId, 4, 10_000)));
        _requireExecutionRevert(
            calls, abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, checkpointId)
        );
        require(account.invocationCounter() == baseline + 1, "stale lookup counter persisted");

        token.setBalance(address(account), recoveredBalance);
        calls = _checkpointOnlyCall(checkpointId);
        account.executeBatchDynamic(calls);
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
        uint256 baseline = account.invocationCounter();
        uint256 targetCountBefore = target.count();
        uint256 targetTotalBefore = target.total();
        token.setBalance(address(account), checkpointBalance);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.consume, (consumed)),
            _singleCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _recordCall(_singlePatch(_deltaPatch(checkpointId, 4, 10_000)));
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.BalanceBelowCheckpoint.selector,
                1,
                0,
                address(token),
                checkpointId,
                currentBalance,
                checkpointBalance
            )
        );

        require(account.invocationCounter() == baseline, "negative-delta counter persisted");
        require(token.balanceOf(address(account)) == checkpointBalance, "negative-delta token state persisted");
        require(target.count() == targetCountBefore, "negative-delta target count changed");
        require(target.total() == targetTotalBefore, "negative-delta target total changed");
    }

    /// @dev Proves duplicate checkpoint IDs revert the invocation counter and records.
    /// @param balance Balance available when both checkpoints attempt to read.
    /// @param rawId Unbounded checkpoint identifier normalized away from zero.
    function exerciseDuplicateIdRollback(uint128 balance, bytes32 rawId) external {
        bytes32 checkpointId = _validId(rawId);
        uint256 baseline = account.invocationCounter();
        token.setBalance(address(account), balance);

        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(checkpointId);
        checkpoints[1] = _checkpoint(checkpointId);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(address(patchTarget), hex"deadbeef", checkpoints, _noPatches());

        _requireExecutionRevert(
            calls, abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 0, 1, checkpointId)
        );
        require(account.invocationCounter() == baseline, "duplicate-id counter persisted");
    }

    /// @dev Proves a later target failure rolls back an earlier target mutation.
    /// @param amount Amount recorded by the call that must be rolled back.
    /// @param rawPayload Arbitrary nested revert payload material.
    function exerciseAtomicTargetRollback(uint128 amount, bytes32 rawPayload) external {
        uint256 baseline = account.invocationCounter();
        uint256 targetCountBefore = target.count();
        uint256 targetTotalBefore = target.total();
        bytes memory payload = abi.encodePacked(rawPayload);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(amount), bytes("must-roll-back"))),
            _noCheckpoints(),
            _noPatches()
        );
        calls[1] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.fail, (uint256(52), payload)),
            _noCheckpoints(),
            _noPatches()
        );
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 52, payload);
        _requireExecutionRevert(
            calls,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(target), targetReason
            )
        );

        require(account.invocationCounter() == baseline, "target-revert counter persisted");
        require(target.count() == targetCountBefore, "target-revert count persisted");
        require(target.total() == targetTotalBefore, "target-revert total persisted");
    }

    function _requireRecord(uint256 invocationId, bytes32 checkpointId, uint256 expectedBalance) private view {
        (bool present, address storedToken, uint256 storedBalance) =
            account.checkpointRecord(invocationId, checkpointId);
        require(present, "checkpoint record missing");
        require(storedToken == address(token), "checkpoint token mismatch");
        require(storedBalance == expectedBalance, "checkpoint balance mismatch");
    }

    function _requireExecutionRevert(IDefiSimplify7702Account.DynamicCall[] memory calls, bytes memory expectedReason)
        private
    {
        (bool success, bytes memory reason) =
            address(account).call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        require(!success, "expected dynamic execution revert");
        require(keccak256(reason) == keccak256(expectedReason), "unexpected dynamic execution revert");
    }

    function _checkpointOnlyCall(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(address(patchTarget), hex"deadbeef", _singleCheckpoint(checkpointId), _noPatches());
    }

    function _recordCall(IDefiSimplify7702Account.BalancePatch[] memory patches)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("invariant"))),
            _noCheckpoints(),
            patches
        );
    }

    function _call(
        address callTarget,
        bytes memory data,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = patches;
    }

    function _checkpoint(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.BalanceCheckpoint memory)
    {
        return IDefiSimplify7702Account.BalanceCheckpoint({token: address(token), id: checkpointId});
    }

    function _singleCheckpoint(bytes32 checkpointId)
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

    function _singlePatch(IDefiSimplify7702Account.BalancePatch memory patch)
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

    function _currentPatch(uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(token),
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    function _deltaPatch(bytes32 checkpointId, uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(token),
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

    DynamicEngineInvariantHandler private handler;
    CheckpointTableHarness private implementation;
    address payable private account;

    /// @dev Installs a real EIP-7702 delegation and restricts the invariant runner
    ///      to the handler's modeled actions.
    function setUp() external {
        handler = new DynamicEngineInvariantHandler();
        implementation = new CheckpointTableHarness(IEntryPoint(address(handler)));
        account = payable(vm.addr(INVARIANT_AUTHORITY_KEY));
        require(account.code.length == 0, "invariant authority already has code");
        vm.signAndAttachDelegation(address(implementation), INVARIANT_AUTHORITY_KEY);
        require(_delegationTarget(account) == address(implementation), "wrong invariant delegation target");
        handler.initialize(account);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.exerciseCurrentBalance.selector;
        selectors[1] = handler.exerciseCheckpointDelta.selector;
        selectors[2] = handler.exerciseSameIdSequentialInvocations.selector;
        selectors[3] = handler.exerciseRevertedScopeRollback.selector;
        selectors[4] = handler.exerciseStaleScopeRejection.selector;
        selectors[5] = handler.exerciseNegativeDeltaRollback.selector;
        selectors[6] = handler.exerciseDuplicateIdRollback.selector;
        selectors[7] = handler.exerciseAtomicTargetRollback.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Target state must equal only the handler actions that returned successfully.
    function invariant_TargetStateMatchesSuccessfulActionModel() external view {
        DynamicExecutionTarget target = handler.target();
        assertEq(target.count(), handler.modelTargetCount(), "invariant target count");
        assertEq(target.total(), handler.modelTargetTotal(), "invariant target total");
        if (target.count() != 0) {
            assertEq(target.lastCaller(), account, "invariant delegated caller");
        }
    }

    /// @dev Dynamic activity must never replace or remove the EIP-7702 delegation.
    function invariant_DelegationTargetRemainsInstalled() external view {
        assertEq(account.code.length, 23, "delegation indicator length");
        assertEq(_delegationTarget(account), address(implementation), "delegation target changed");
    }

    /// @dev Records SSTORE access to prove dynamic execution has no permanent account writes.
    function test_DynamicExecutionWritesNoPermanentAccountStorage() external {
        PatchBalanceToken token = handler.token();
        token.setBalance(account, 123);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(handler.patchTarget());
        calls[0].data = hex"deadbeef";
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        calls[0].checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: address(token), id: bytes32(uint256(1))});
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);

        vm.record();
        vm.prank(address(handler));
        IDefiSimplify7702Account(account).executeBatchDynamic(calls);
        (, bytes32[] memory permanentWrites) = vm.accesses(account);

        assertEq(permanentWrites.length, 0, "dynamic execution wrote permanent account storage");
    }

    /// @dev Proves inherited static execution remains usable around a dynamic invocation.
    function test_InheritedStaticExecutionRemainsUsableBeforeAndAfterDynamicInvocation() external {
        DynamicExecutionTarget target = handler.target();

        vm.prank(account);
        BaseAccount(account)
            .execute(
                address(target), 0, abi.encodeCall(DynamicExecutionTarget.record, (uint256(11), bytes("static-before")))
            );

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(target);
        calls[0].data = abi.encodeCall(DynamicExecutionTarget.record, (uint256(13), bytes("dynamic")));
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
        vm.prank(account);
        IDefiSimplify7702Account(account).executeBatchDynamic(calls);

        vm.prank(account);
        BaseAccount(account)
            .execute(
                address(target), 0, abi.encodeCall(DynamicExecutionTarget.record, (uint256(17), bytes("static-after")))
            );

        assertEq(target.count(), 3, "static/dynamic/static count");
        assertEq(target.total(), 41, "static/dynamic/static total");
        assertEq(target.lastCaller(), account, "static/dynamic/static delegated caller");
    }
}
