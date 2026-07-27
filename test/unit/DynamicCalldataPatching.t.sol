// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    DynamicPatchTarget,
    PatchBalanceToken,
    RevertingCheckpointToken,
    ShortReturnCheckpointToken
} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

contract DynamicCalldataPatchingTest is DelegatedAccountFixture {
    bytes32 private constant CHECKPOINT_A = keccak256("dynamic-patch-checkpoint-a");
    bytes32 private constant CHECKPOINT_B = keccak256("dynamic-patch-checkpoint-b");
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));

    DelegatedDefiSimplifyAccount private accountUnderTest;
    PatchBalanceToken private balanceToken;
    PatchBalanceToken private mismatchedCheckpointToken;
    DynamicExecutionTarget private recordingTarget;
    DynamicPatchTarget private calldataCaptureTarget;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        balanceToken = new PatchBalanceToken();
        mismatchedCheckpointToken = new PatchBalanceToken();
        recordingTarget = new DynamicExecutionTarget();
        calldataCaptureTarget = new DynamicPatchTarget();
    }

    function test_CurrentBalancePatchesSelectedWordAndIncludesExistingInventory() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 123_456);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(
            777,
            "inventory",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.total(), 123_456, "patched current balance");
        assertEq(recordingTarget.lastPayloadHash(), keccak256("inventory"), "unpatched dynamic payload");
    }

    function test_CheckpointDeltaConsumesOnlyBalanceProducedAfterEarlierCall() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.produce, (250)),
            DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A),
            DynamicCallTestBuilder.noPatches()
        );
        calls[1] = _buildRecordingCall(
            999,
            "delta",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.total(), 250, "pre-checkpoint inventory leaked into delta");
    }

    function test_SequentialConsumersReReadAfterEachTargetCall() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.produce, (400)),
            DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A),
            DynamicCallTestBuilder.noPatches()
        );
        calls[1] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.consume, (0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 5_000)
            )
        );
        calls[2] = _buildRecordingCall(
            0,
            "remaining",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(balanceToken.balanceOf(accountUnderTest.delegatedEoa), 1_200, "first consumer amount");
        assertEq(recordingTarget.total(), 200, "later call did not re-read current balance");
    }

    function test_MultipleSameCallPatchesUseOnePreCallBalanceAndChangeOnlySelectedWords() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 400);
        bytes memory original = abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(11), uint256(22), uint256(33));
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 2_500);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 68, 10_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget), original, DynamicCallTestBuilder.noCheckpoints(), patches
        );

        vm.expectCall(
            address(balanceToken), abi.encodeCall(IERC20.balanceOf, (accountUnderTest.delegatedEoa)), uint64(1)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        bytes memory observed = calldataCaptureTarget.observedData();
        assertEq(observed, abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(100), uint256(22), uint256(400)));
    }

    function test_SameCallCacheIsSharedByPatchesAndCheckpointCreation() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 500);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 5_000);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 36, 10_000);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = DynamicCallTestBuilder.checkpoint(address(balanceToken), CHECKPOINT_A);
        checkpoints[1] = DynamicCallTestBuilder.checkpoint(address(balanceToken), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0), uint256(0), uint256(7)),
            checkpoints,
            patches
        );

        vm.expectCall(
            address(balanceToken), abi.encodeCall(IERC20.balanceOf, (accountUnderTest.delegatedEoa)), uint64(1)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_ZeroPatchTokenRevertsWithIndices() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(0), 4, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchToken.selector, 0, 0)
        );
    }

    function test_OffsetBelowSelectorBoundaryReverts() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 3, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 3, 100)
        );
    }

    function test_UnalignedOffsetReverts() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 5, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 5, 100)
        );
    }

    function test_OutOfBoundsOffsetReverts() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 100, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 100, 100)
        );
    }

    function test_DuplicateOffsetRevertsWithPreviousAndCurrent() external {
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_000);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 0, 1, 4, 4));
        _executePatchesAndCaptureCalldata(patches);
    }

    function test_DescendingOffsetRevertsWithPreviousAndCurrent() external {
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 68, 10_000);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 36, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 0, 1, 68, 36));
        _executePatchesAndCaptureCalldata(patches);
    }

    function test_BpsZeroReverts() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 0),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 0, 0, 0)
        );
    }

    function test_BpsAboveTenThousandReverts() external {
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_001),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 0, 0, 10_001)
        );
    }

    function test_OneBasisPointMayResolveToZero() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 9_999);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(
            777,
            "zero",
            DynamicCallTestBuilder.singlePatch(DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 1))
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.total(), 0, "zero patch result rejected or rounded up");
    }

    function test_CurrentBalanceRejectsNonzeroCheckpointIdBeforeBalanceRead() external {
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(1, "must-not-read");
        IDefiSimplify7702Account.BalancePatch memory patch =
            DynamicCallTestBuilder.currentBalancePatch(address(revertingToken), 4, 10_000);
        patch.checkpointId = CHECKPOINT_A;

        _expectSinglePatchFailure(
            patch, abi.encodeWithSelector(IDefiSimplify7702Account.UnexpectedCheckpointId.selector, 0, 0, CHECKPOINT_A)
        );
    }

    function test_MissingCheckpointRevertsBeforeBalanceRead() external {
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(2, "must-not-read");
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.checkpointDeltaPatch(address(revertingToken), CHECKPOINT_A, 4, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
    }

    function test_SameCallCheckpointReferenceIsMissingBeforeCheckpointCreation() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("same-call"))),
            DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 10_000)
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_CheckpointTokenMismatchRevertsWithExpectedAndActualTokens() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildRecordingCall(1, "checkpoint", DynamicCallTestBuilder.noPatches());
        calls[0].checkpointsBefore = DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A);
        calls[1] = _buildRecordingCall(
            2,
            "mismatch",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(mismatchedCheckpointToken), CHECKPOINT_A, 4, 10_000)
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointTokenMismatch.selector,
                1,
                0,
                CHECKPOINT_A,
                address(mismatchedCheckpointToken),
                address(balanceToken)
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_BalanceBelowCheckpointRevertsWithoutClamping() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 100);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.consume, (60)),
            DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A),
            DynamicCallTestBuilder.noPatches()
        );
        calls[1] = _buildRecordingCall(
            0,
            "negative",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 10_000)
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.BalanceBelowCheckpoint.selector,
                1,
                0,
                address(balanceToken),
                CHECKPOINT_A,
                40,
                100
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(balanceToken.balanceOf(accountUnderTest.delegatedEoa), 100, "earlier consume did not roll back");
    }

    function test_PatchBalanceRevertPreservesReasonAndFirstTriggerIndex() external {
        bytes memory payload = "patch-read-revert";
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(77, payload);
        bytes memory nestedReason =
            abi.encodeWithSelector(RevertingCheckpointToken.BalanceReadFailure.selector, 77, payload);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_000);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(revertingToken), 36, 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.PatchBalanceReadFailed.selector, 0, 1, address(revertingToken), nestedReason
            )
        );
        _executePatchesAndCaptureCalldata(patches);
    }

    function test_ShortPatchBalanceReadPreservesMalformedBytesAndIndex() external {
        ShortReturnCheckpointToken shortToken = new ShortReturnCheckpointToken();
        _expectSinglePatchFailure(
            DynamicCallTestBuilder.currentBalancePatch(address(shortToken), 4, 10_000),
            abi.encodeWithSelector(
                IDefiSimplify7702Account.PatchBalanceReadFailed.selector, 0, 0, address(shortToken), hex"1234"
            )
        );
    }

    function test_LaterInvocationCannotConsumeStaleCheckpointWithSameId() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 100);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(1, "first", DynamicCallTestBuilder.noPatches());
        calls[0].checkpointsBefore = DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_A);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        calls[0] = _buildRecordingCall(
            0,
            "stale",
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_A, 4, 10_000)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_Golden_CurrentBalancePatchesExactAbiWord() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 0x123456789abcdef);
        string memory fixture = vm.readFile("abi/DynamicCalldataPatching.golden.json");
        bytes memory original = vm.parseJsonBytes(fixture, ".originalCalldata");
        bytes memory expected = vm.parseJsonBytes(fixture, ".patchedCalldata");
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget),
            original,
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 36, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(calldataCaptureTarget.observedData(), expected, "golden patched calldata");
        assertEq(
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 2, 5, 100),
            vm.parseJsonBytes(fixture, ".invalidPatchOffsetError"),
            "golden indexed error"
        );
    }

    function test_Gas_OneCheckpointDeltaLookup() external {
        _executeCheckpointLookupGasScenario(1);
    }

    function test_Gas_FourCheckpointDeltaLookups() external {
        _executeCheckpointLookupGasScenario(4);
    }

    function test_Gas_EightCheckpointDeltaLookups() external {
        _executeCheckpointLookupGasScenario(8);
    }

    function test_Gas_SixteenCheckpointDeltaLookups() external {
        _executeCheckpointLookupGasScenario(16);
    }

    function test_Gas_ThirtyTwoCheckpointDeltaLookups() external {
        _executeCheckpointLookupGasScenario(32);
    }

    function _executeCheckpointLookupGasScenario(uint256 checkpointCount) private {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](checkpointCount);
        IDefiSimplify7702Account.BalancePatch[] memory patches =
            new IDefiSimplify7702Account.BalancePatch[](checkpointCount);
        bytes memory patchData = new bytes(4 + checkpointCount * 32);
        uint32 offset = 4;
        for (uint256 i = 0; i < checkpointCount; ++i) {
            bytes32 checkpointId = bytes32(i + 1);
            checkpoints[i] = DynamicCallTestBuilder.checkpoint(address(balanceToken), checkpointId);
            patches[i] =
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), checkpointId, offset, 10_000);
            offset += 32;
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget), hex"deadbeef", checkpoints, DynamicCallTestBuilder.noPatches()
        );
        calls[1] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget), patchData, DynamicCallTestBuilder.noCheckpoints(), patches
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function _expectSinglePatchFailure(IDefiSimplify7702Account.BalancePatch memory patch, bytes memory reason)
        private
    {
        vm.expectRevert(reason);
        _executePatchesAndCaptureCalldata(DynamicCallTestBuilder.singlePatch(patch));
    }

    function _executePatchesAndCaptureCalldata(IDefiSimplify7702Account.BalancePatch[] memory patches) private {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(1), uint256(2), uint256(3)),
            DynamicCallTestBuilder.noCheckpoints(),
            patches
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function _buildRecordingCall(
        uint256 amount,
        bytes memory payload,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) private view returns (IDefiSimplify7702Account.DynamicCall memory) {
        return DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)),
            DynamicCallTestBuilder.noCheckpoints(),
            patches
        );
    }
}
