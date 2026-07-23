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

contract DynamicCalldataPatchingTest is DelegatedAccountFixture {
    bytes32 private constant CHECKPOINT_A = keccak256("dynamic-patch-checkpoint-a");
    bytes32 private constant CHECKPOINT_B = keccak256("dynamic-patch-checkpoint-b");
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));

    DelegatedPair private pair;
    PatchBalanceToken private token;
    PatchBalanceToken private otherToken;
    DynamicExecutionTarget private target;
    DynamicPatchTarget private patchTarget;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        token = new PatchBalanceToken();
        otherToken = new PatchBalanceToken();
        target = new DynamicExecutionTarget();
        patchTarget = new DynamicPatchTarget();
    }

    function test_CurrentBalancePatchesSelectedWordAndIncludesExistingInventory() external {
        token.setBalance(pair.customAccount, 123_456);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(777, "inventory", _singlePatch(_currentPatch(address(token), 4, 10_000)));

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.total(), 123_456, "patched current balance");
        assertEq(target.lastPayloadHash(), keccak256("inventory"), "unpatched dynamic payload");
    }

    function test_CheckpointDeltaConsumesOnlyBalanceProducedAfterEarlierCall() external {
        token.setBalance(pair.customAccount, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (250)),
            _singleCheckpoint(address(token), CHECKPOINT_A),
            _noPatches()
        );
        calls[1] = _recordCall(999, "delta", _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 10_000)));

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.total(), 250, "pre-checkpoint inventory leaked into delta");
    }

    function test_SequentialConsumersReReadAfterEachTargetCall() external {
        token.setBalance(pair.customAccount, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (400)),
            _singleCheckpoint(address(token), CHECKPOINT_A),
            _noPatches()
        );
        calls[1] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.consume, (0)),
            _noCheckpoints(),
            _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 5_000))
        );
        calls[2] = _recordCall(0, "remaining", _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 10_000)));

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(token.balanceOf(pair.customAccount), 1_200, "first consumer amount");
        assertEq(target.total(), 200, "later call did not re-read current balance");
    }

    function test_MultipleSameCallPatchesUseOnePreCallBalanceAndChangeOnlySelectedWords() external {
        token.setBalance(pair.customAccount, 400);
        bytes memory original = abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(11), uint256(22), uint256(33));
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _currentPatch(address(token), 4, 2_500);
        patches[1] = _currentPatch(address(token), 68, 10_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(address(patchTarget), original, _noCheckpoints(), patches);

        vm.expectCall(address(token), abi.encodeCall(IERC20.balanceOf, (pair.customAccount)), uint64(1));
        _dynamicAccount(pair).executeBatchDynamic(calls);

        bytes memory observed = patchTarget.observedData();
        assertEq(observed, abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(100), uint256(22), uint256(400)));
    }

    function test_SameCallCacheIsSharedByPatchesAndCheckpointCreation() external {
        token.setBalance(pair.customAccount, 500);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _currentPatch(address(token), 4, 5_000);
        patches[1] = _currentPatch(address(token), 36, 10_000);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](2);
        checkpoints[0] = _checkpoint(address(token), CHECKPOINT_A);
        checkpoints[1] = _checkpoint(address(token), CHECKPOINT_B);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(
            address(patchTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0), uint256(0), uint256(7)),
            checkpoints,
            patches
        );

        vm.expectCall(address(token), abi.encodeCall(IERC20.balanceOf, (pair.customAccount)), uint64(1));
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_ZeroPatchTokenRevertsWithIndices() external {
        _expectSinglePatchRevert(
            _currentPatch(address(0), 4, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchToken.selector, 0, 0)
        );
    }

    function test_OffsetBelowSelectorBoundaryReverts() external {
        _expectSinglePatchRevert(
            _currentPatch(address(token), 3, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 3, 100)
        );
    }

    function test_UnalignedOffsetReverts() external {
        _expectSinglePatchRevert(
            _currentPatch(address(token), 5, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 5, 100)
        );
    }

    function test_OutOfBoundsOffsetReverts() external {
        _expectSinglePatchRevert(
            _currentPatch(address(token), 100, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 0, 0, 100, 100)
        );
    }

    function test_DuplicateOffsetRevertsWithPreviousAndCurrent() external {
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _currentPatch(address(token), 4, 10_000);
        patches[1] = _currentPatch(address(token), 4, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 0, 1, 4, 4));
        _executeCapture(patches);
    }

    function test_DescendingOffsetRevertsWithPreviousAndCurrent() external {
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _currentPatch(address(token), 68, 10_000);
        patches[1] = _currentPatch(address(token), 36, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 0, 1, 68, 36));
        _executeCapture(patches);
    }

    function test_BpsZeroReverts() external {
        _expectSinglePatchRevert(
            _currentPatch(address(token), 4, 0),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 0, 0, 0)
        );
    }

    function test_BpsAboveTenThousandReverts() external {
        _expectSinglePatchRevert(
            _currentPatch(address(token), 4, 10_001),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 0, 0, 10_001)
        );
    }

    function test_OneBasisPointMayResolveToZero() external {
        token.setBalance(pair.customAccount, 9_999);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(777, "zero", _singlePatch(_currentPatch(address(token), 4, 1)));

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(target.total(), 0, "zero patch result rejected or rounded up");
    }

    function test_CurrentBalanceRejectsNonzeroCheckpointIdBeforeBalanceRead() external {
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(1, "must-not-read");
        IDefiSimplify7702Account.BalancePatch memory patch = _currentPatch(address(revertingToken), 4, 10_000);
        patch.checkpointId = CHECKPOINT_A;

        _expectSinglePatchRevert(
            patch, abi.encodeWithSelector(IDefiSimplify7702Account.UnexpectedCheckpointId.selector, 0, 0, CHECKPOINT_A)
        );
    }

    function test_MissingCheckpointRevertsBeforeBalanceRead() external {
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(2, "must-not-read");
        _expectSinglePatchRevert(
            _deltaPatch(address(revertingToken), CHECKPOINT_A, 4, 10_000),
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
    }

    function test_SameCallCheckpointReferenceIsMissingBeforeCheckpointCreation() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("same-call"))),
            _singleCheckpoint(address(token), CHECKPOINT_A),
            _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 10_000))
        );

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_CheckpointTokenMismatchRevertsWithExpectedAndActualTokens() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _recordCall(1, "checkpoint", _noPatches());
        calls[0].checkpointsBefore = _singleCheckpoint(address(token), CHECKPOINT_A);
        calls[1] = _recordCall(2, "mismatch", _singlePatch(_deltaPatch(address(otherToken), CHECKPOINT_A, 4, 10_000)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointTokenMismatch.selector,
                1,
                0,
                CHECKPOINT_A,
                address(otherToken),
                address(token)
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_BalanceBelowCheckpointRevertsWithoutClamping() external {
        token.setBalance(pair.customAccount, 100);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.consume, (60)),
            _singleCheckpoint(address(token), CHECKPOINT_A),
            _noPatches()
        );
        calls[1] = _recordCall(0, "negative", _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 10_000)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.BalanceBelowCheckpoint.selector, 1, 0, address(token), CHECKPOINT_A, 40, 100
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
        assertEq(token.balanceOf(pair.customAccount), 100, "earlier consume did not roll back");
    }

    function test_PatchBalanceRevertPreservesReasonAndFirstTriggerIndex() external {
        bytes memory payload = "patch-read-revert";
        RevertingCheckpointToken revertingToken = new RevertingCheckpointToken(77, payload);
        bytes memory nestedReason =
            abi.encodeWithSelector(RevertingCheckpointToken.BalanceReadFailure.selector, 77, payload);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _currentPatch(address(token), 4, 10_000);
        patches[1] = _currentPatch(address(revertingToken), 36, 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.PatchBalanceReadFailed.selector, 0, 1, address(revertingToken), nestedReason
            )
        );
        _executeCapture(patches);
    }

    function test_ShortPatchBalanceReadPreservesMalformedBytesAndIndex() external {
        ShortReturnCheckpointToken shortToken = new ShortReturnCheckpointToken();
        _expectSinglePatchRevert(
            _currentPatch(address(shortToken), 4, 10_000),
            abi.encodeWithSelector(
                IDefiSimplify7702Account.PatchBalanceReadFailed.selector, 0, 0, address(shortToken), hex"1234"
            )
        );
    }

    function test_LaterInvocationCannotConsumeStaleCheckpointWithSameId() external {
        token.setBalance(pair.customAccount, 100);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordCall(1, "first", _noPatches());
        calls[0].checkpointsBefore = _singleCheckpoint(address(token), CHECKPOINT_A);
        _dynamicAccount(pair).executeBatchDynamic(calls);

        calls[0] = _recordCall(0, "stale", _singlePatch(_deltaPatch(address(token), CHECKPOINT_A, 4, 10_000)));
        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, CHECKPOINT_A)
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function test_Golden_CurrentBalancePatchesExactAbiWord() external {
        token.setBalance(pair.customAccount, 0x123456789abcdef);
        string memory fixture = vm.readFile("abi/DynamicCalldataPatching.golden.json");
        bytes memory original = vm.parseJsonBytes(fixture, ".originalCalldata");
        bytes memory expected = vm.parseJsonBytes(fixture, ".patchedCalldata");
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(
            address(patchTarget), original, _noCheckpoints(), _singlePatch(_currentPatch(address(token), 36, 10_000))
        );

        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(patchTarget.observedData(), expected, "golden patched calldata");
        assertEq(
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 2, 5, 100),
            vm.parseJsonBytes(fixture, ".invalidPatchOffsetError"),
            "golden indexed error"
        );
    }

    function test_Gas_OneCheckpointDeltaLookup() external {
        _executeLookupGasPlan(1);
    }

    function test_Gas_FourCheckpointDeltaLookups() external {
        _executeLookupGasPlan(4);
    }

    function test_Gas_EightCheckpointDeltaLookups() external {
        _executeLookupGasPlan(8);
    }

    function test_Gas_SixteenCheckpointDeltaLookups() external {
        _executeLookupGasPlan(16);
    }

    function test_Gas_ThirtyTwoCheckpointDeltaLookups() external {
        _executeLookupGasPlan(32);
    }

    function _executeLookupGasPlan(uint256 checkpointCount) private {
        token.setBalance(pair.customAccount, 1_000);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](checkpointCount);
        IDefiSimplify7702Account.BalancePatch[] memory patches =
            new IDefiSimplify7702Account.BalancePatch[](checkpointCount);
        bytes memory patchData = new bytes(4 + checkpointCount * 32);
        uint32 offset = 4;
        for (uint256 i = 0; i < checkpointCount; ++i) {
            bytes32 checkpointId = bytes32(i + 1);
            checkpoints[i] = _checkpoint(address(token), checkpointId);
            patches[i] = _deltaPatch(address(token), checkpointId, offset, 10_000);
            offset += 32;
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(address(patchTarget), hex"deadbeef", checkpoints, _noPatches());
        calls[1] = _call(address(patchTarget), patchData, _noCheckpoints(), patches);

        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function _expectSinglePatchRevert(IDefiSimplify7702Account.BalancePatch memory patch, bytes memory reason) private {
        vm.expectRevert(reason);
        _executeCapture(_singlePatch(patch));
    }

    function _executeCapture(IDefiSimplify7702Account.BalancePatch[] memory patches) private {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(
            address(patchTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(1), uint256(2), uint256(3)),
            _noCheckpoints(),
            patches
        );
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function _recordCall(uint256 amount, bytes memory payload, IDefiSimplify7702Account.BalancePatch[] memory patches)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _call(
            address(target), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)), _noCheckpoints(), patches
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

    function _currentPatch(address patchToken, uint32 offset, uint16 bps)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: patchToken,
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    function _deltaPatch(address patchToken, bytes32 checkpointId, uint32 offset, uint16 bps)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: patchToken,
            checkpointId: checkpointId,
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
    }
}
