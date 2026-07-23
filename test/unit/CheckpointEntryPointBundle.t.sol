// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {CheckpointTableHarness, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CheckpointEntryPointBundleTest is DelegatedAccountFixture {
    uint256 private constant ACCOUNT_AUTHORITY_KEY = 0x48B0;
    address private constant BUNDLER = address(0xB0D1E);
    address payable private constant BENEFICIARY = payable(address(0xBEEF));
    bytes32 private constant REUSED_CHECKPOINT_ID = keccak256("bundle-reused-checkpoint");

    EntryPoint private entryPoint;
    CheckpointTableHarness private checkpointHarnessImplementation;
    address payable private delegatedEoa;
    PatchBalanceToken private balanceToken;
    DynamicExecutionTarget private recordingTarget;

    function setUp() external {
        entryPoint = new EntryPoint();
        checkpointHarnessImplementation = new CheckpointTableHarness(entryPoint);
        delegatedEoa = payable(vm.addr(ACCOUNT_AUTHORITY_KEY));
        require(delegatedEoa.code.length == 0, "authority already has code");
        vm.signAndAttachDelegation(address(checkpointHarnessImplementation), ACCOUNT_AUTHORITY_KEY);
        require(_delegationTarget(delegatedEoa) == address(checkpointHarnessImplementation), "wrong delegation target");

        balanceToken = new PatchBalanceToken();
        recordingTarget = new DynamicExecutionTarget();
        balanceToken.setBalance(delegatedEoa, 211);
    }

    function test_MultipleValidUserOperationsReceiveSuccessiveScopesInOneBundle() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](2);
        operations[0] = _buildSignedUserOperation(0, _buildSuccessfulCheckpointCall(1, "first"));
        operations[1] = _buildSignedUserOperation(1, _buildSuccessfulCheckpointCall(2, "second"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(recordingTarget.count(), 2, "both UserOperations must execute");
        assertEq(recordingTarget.total(), 3, "bundle target total");
        vm.prank(delegatedEoa);
        assertEq(CheckpointTableHarness(delegatedEoa).invocationCounter(), 2, "bundle invocation counter");
        vm.prank(delegatedEoa);
        (bool firstPresent,, uint256 firstBalance) =
            CheckpointTableHarness(delegatedEoa).checkpointRecord(1, REUSED_CHECKPOINT_ID);
        vm.prank(delegatedEoa);
        (bool secondPresent,, uint256 secondBalance) =
            CheckpointTableHarness(delegatedEoa).checkpointRecord(2, REUSED_CHECKPOINT_ID);
        assertTrue(firstPresent && secondPresent, "bundle scopes absent");
        assertEq(firstBalance, 211, "first scope balance");
        assertEq(secondBalance, 211, "second scope balance");
    }

    function test_RevertedUserOperationBetweenSuccessesRollsBackTentativeScope() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](3);
        operations[0] = _buildSignedUserOperation(0, _buildSuccessfulCheckpointCall(3, "before-revert"));
        operations[1] = _buildSignedUserOperation(1, _buildRevertingCheckpointCall(5, "reverted"));
        operations[2] = _buildSignedUserOperation(2, _buildSuccessfulCheckpointCall(7, "after-revert"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(recordingTarget.count(), 2, "bundle must continue after failed execution");
        assertEq(recordingTarget.total(), 10, "only successful operations count");
        vm.prank(delegatedEoa);
        assertEq(CheckpointTableHarness(delegatedEoa).invocationCounter(), 2, "failed scope consumed counter");
        vm.prank(delegatedEoa);
        (bool secondPresent,, uint256 secondBalance) =
            CheckpointTableHarness(delegatedEoa).checkpointRecord(2, REUSED_CHECKPOINT_ID);
        vm.prank(delegatedEoa);
        (bool thirdPresent,,) = CheckpointTableHarness(delegatedEoa).checkpointRecord(3, REUSED_CHECKPOINT_ID);
        assertTrue(secondPresent, "post-revert scope absent");
        assertEq(secondBalance, 211, "post-revert scope balance");
        assertFalse(thirdPresent, "failed operation left an extra scope");
    }

    function test_PatchesConsumeOnlyTheirOwnCheckpointScopeAcrossBundledUserOperations() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](2);
        operations[0] = _buildSignedPatchedUserOperation(0, 10, false);
        operations[1] = _buildSignedPatchedUserOperation(1, 20, false);

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(recordingTarget.count(), 2, "both patched UserOperations must execute");
        assertEq(recordingTarget.total(), 30, "each patch must use its invocation-local delta");
        assertEq(balanceToken.balanceOf(delegatedEoa), 241, "both producers must commit");
    }

    function test_RevertedPatchedUserOperationRollsBackScopeAndBalanceBeforeNextPatch() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](3);
        operations[0] = _buildSignedPatchedUserOperation(0, 10, false);
        operations[1] = _buildSignedPatchedUserOperation(1, 90, true);
        operations[2] = _buildSignedPatchedUserOperation(2, 20, false);

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(recordingTarget.count(), 2, "failed patched operation must not stop bundle");
        assertEq(recordingTarget.total(), 30, "post-revert patch consumed stale or rolled-back delta");
        assertEq(balanceToken.balanceOf(delegatedEoa), 241, "failed producer balance survived rollback");
        vm.prank(delegatedEoa);
        assertEq(CheckpointTableHarness(delegatedEoa).invocationCounter(), 2, "failed patched scope consumed counter");
    }

    function _buildSignedUserOperation(uint256 nonce, IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;

        return _buildSignedUserOperation(nonce, calls);
    }

    function _buildSignedUserOperation(uint256 nonce, IDefiSimplify7702Account.DynamicCall[] memory calls)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        operation.sender = delegatedEoa;
        operation.nonce = nonce;
        operation.callData = abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls));
        operation.accountGasLimits = bytes32((uint256(1_000_000) << 128) | uint256(1_000_000));
        operation.preVerificationGas = 100_000;
        operation.gasFees = bytes32(0);
        operation.signature = _signature(ACCOUNT_AUTHORITY_KEY, entryPoint.getUserOpHash(operation));
    }

    function _buildSignedPatchedUserOperation(uint256 nonce, uint256 producedAmount, bool mustFail)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0].target = address(balanceToken);
        calls[0].data = abi.encodeCall(PatchBalanceToken.produce, (producedAmount));
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        calls[0].checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: address(balanceToken), id: REUSED_CHECKPOINT_ID});
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);

        calls[1].target = address(recordingTarget);
        calls[1].data = mustFail
            ? abi.encodeCall(DynamicExecutionTarget.fail, (uint256(0), bytes("patched-revert")))
            : abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("patched-success")));
        calls[1].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        calls[1].patches = new IDefiSimplify7702Account.BalancePatch[](1);
        calls[1].patches[0] = IDefiSimplify7702Account.BalancePatch({
            token: address(balanceToken),
            checkpointId: REUSED_CHECKPOINT_ID,
            offset: 4,
            bps: 10_000,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });

        return _buildSignedUserOperation(nonce, calls);
    }

    function _buildSuccessfulCheckpointCall(uint256 amount, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall = _buildCheckpointedTargetCall(abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)));
    }

    function _buildRevertingCheckpointCall(uint256 code, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall = _buildCheckpointedTargetCall(abi.encodeCall(DynamicExecutionTarget.fail, (code, payload)));
    }

    function _buildCheckpointedTargetCall(bytes memory callData)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = address(recordingTarget);
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        dynamicCall.checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: address(balanceToken), id: REUSED_CHECKPOINT_ID});
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
