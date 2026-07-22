// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CheckpointTableHarness, DynamicPatchTarget, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Property coverage for amount resolution, checkpoint isolation, and patch writes.
contract DynamicCalldataPatchingFuzzTest is DelegatedAccountFixture {
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));

    DelegatedPair private pair;
    PatchBalanceToken private token;
    DynamicExecutionTarget private target;
    DynamicPatchTarget private patchTarget;
    CheckpointTableHarness private checkpointHarness;

    /// @dev Installs delegated-account, token, target, and slot-derivation fixtures.
    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        token = new PatchBalanceToken();
        target = new DynamicExecutionTarget();
        patchTarget = new DynamicPatchTarget();
        checkpointHarness = new CheckpointTableHarness(IEntryPoint(address(this)));
    }

    /// @dev Compares CurrentBalance resolution with the canonical full-precision calculation.
    /// @param balance Arbitrary token balance, including values that overflow naive multiplication.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    function testFuzz_FullPrecisionCurrentBalanceMathMatchesMulDiv(uint256 balance, uint16 rawBps) external {
        uint16 bps = uint16(bound(rawBps, 1, 10_000));
        token.setBalance(pair.customAccount, balance);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("muldiv"))),
            _patch(4, bps)
        );

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(target.total(), Math.mulDiv(balance, uint256(bps), 10_000), "full-precision result");
    }

    /// @dev Proves patching mutates exactly one selected ABI word and no surrounding bytes.
    /// @param first Arbitrary original first word.
    /// @param second Arbitrary original second word.
    /// @param third Arbitrary original third word.
    /// @param balance Arbitrary balance resolved into the patched amount.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    /// @param rawWordIndex Unbounded input normalized into one of three ABI words.
    function testFuzz_PatchChangesExactlyOneSelectedWord(
        bytes32 first,
        bytes32 second,
        bytes32 third,
        uint256 balance,
        uint16 rawBps,
        uint8 rawWordIndex
    ) external {
        uint16 bps = uint16(bound(rawBps, 1, 10_000));
        uint32 offset = 4 + uint32(rawWordIndex % 3) * 32;
        token.setBalance(pair.customAccount, balance);

        bytes memory original = abi.encodeWithSelector(CAPTURE_SELECTOR, first, second, third);
        bytes memory expected = abi.encodeWithSelector(CAPTURE_SELECTOR, first, second, third);
        uint256 amount = Math.mulDiv(balance, uint256(bps), 10_000);
        assembly ("memory-safe") {
            mstore(add(add(expected, 32), offset), amount)
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(address(patchTarget), original, _patch(offset, bps));

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(patchTarget.observedData(), expected, "bytes outside selected word changed");
    }

    /// @dev Proves CheckpointDelta excludes inventory held before the producer call.
    /// @param inventory Arbitrary pre-checkpoint token inventory.
    /// @param produced Arbitrary token amount produced after the checkpoint.
    /// @param rawBps Unbounded input normalized into the valid BPS interval.
    /// @param rawCheckpointId Unbounded checkpoint identifier normalized away from zero.
    function testFuzz_CheckpointDeltaExcludesArbitraryStartingInventory(
        uint128 inventory,
        uint128 produced,
        uint16 rawBps,
        bytes32 rawCheckpointId
    ) external {
        bytes32 checkpointId = _validId(rawCheckpointId);
        uint16 bps = uint16(bound(rawBps, 1, 10_000));
        token.setBalance(pair.customAccount, inventory);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(produced))),
            _singleCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("fuzz-delta"))),
            _noCheckpoints(),
            _singlePatch(_deltaPatch(checkpointId, 4, bps))
        );

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(target.total(), Math.mulDiv(uint256(produced), uint256(bps), 10_000), "inventory leaked");
    }

    /// @dev Proves later calls re-read balances after an earlier consumer changes token state.
    /// @param inventory Arbitrary pre-checkpoint token inventory.
    /// @param produced Arbitrary token amount produced after the checkpoint.
    /// @param rawFirstBps Unbounded BPS input for the first consumer.
    /// @param rawCheckpointId Unbounded checkpoint identifier normalized away from zero.
    function testFuzz_SequentialConsumersReReadAfterEachTarget(
        uint128 inventory,
        uint128 produced,
        uint16 rawFirstBps,
        bytes32 rawCheckpointId
    ) external {
        bytes32 checkpointId = _validId(rawCheckpointId);
        uint16 firstBps = uint16(bound(rawFirstBps, 1, 10_000));
        token.setBalance(pair.customAccount, inventory);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(produced))),
            _singleCheckpoint(checkpointId),
            _noPatches()
        );
        calls[1] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.consume, (uint256(0))),
            _noCheckpoints(),
            _singlePatch(_deltaPatch(checkpointId, 4, firstBps))
        );
        calls[2] = _call(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("fuzz-remaining"))),
            _noCheckpoints(),
            _singlePatch(_deltaPatch(checkpointId, 4, 10_000))
        );

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        uint256 consumed = Math.mulDiv(uint256(produced), uint256(firstBps), 10_000);
        assertEq(target.total(), uint256(produced) - consumed, "later consumer reused stale balance");
    }

    /// @dev Proves two checkpoints for one token retain independent baselines.
    /// @param inventory Arbitrary token inventory before either producer.
    /// @param firstProduced Amount produced after the first checkpoint.
    /// @param secondProduced Amount produced after the second checkpoint.
    /// @param rawFirstId Unbounded first checkpoint identifier.
    /// @param rawSecondId Unbounded second identifier normalized to remain distinct.
    function testFuzz_SameTokenMultipleCheckpointsResolveIndependentDeltas(
        uint128 inventory,
        uint128 firstProduced,
        uint128 secondProduced,
        bytes32 rawFirstId,
        bytes32 rawSecondId
    ) external {
        bytes32 firstId = _validId(rawFirstId);
        bytes32 secondId = _distinctId(rawSecondId, firstId);
        token.setBalance(pair.customAccount, inventory);

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(firstProduced))),
            _singleCheckpoint(firstId),
            _noPatches()
        );
        calls[1] = _call(
            address(token),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(secondProduced))),
            _singleCheckpoint(secondId),
            _noPatches()
        );
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _deltaPatch(firstId, 4, 10_000);
        patches[1] = _deltaPatch(secondId, 36, 10_000);
        calls[2] = _call(
            address(patchTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0), uint256(0), uint256(0xC0FFEE)),
            _noCheckpoints(),
            patches
        );

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(
            patchTarget.observedData(),
            abi.encodeWithSelector(
                CAPTURE_SELECTOR, uint256(firstProduced) + uint256(secondProduced), uint256(secondProduced), 0xC0FFEE
            ),
            "same-token checkpoint deltas"
        );
    }

    /// @dev Accepts strictly increasing offsets and rejects the reverse order before execution.
    /// @param rawFirstWord Unbounded input normalized into the first selected ABI word.
    /// @param rawSecondWord Unbounded input normalized into the second selected ABI word.
    /// @param tokenBalance Arbitrary amount written to each selected word.
    function testFuzz_OffsetOrderAcceptsOnlyStrictlyIncreasing(
        uint8 rawFirstWord,
        uint8 rawSecondWord,
        uint256 tokenBalance
    ) external {
        uint8 firstWord = rawFirstWord % 3;
        uint8 secondWord = rawSecondWord % 3;
        vm.assume(firstWord != secondWord);
        uint32 firstOffset = 4 + uint32(firstWord) * 32;
        uint32 secondOffset = 4 + uint32(secondWord) * 32;
        token.setBalance(pair.customAccount, tokenBalance);

        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](2);
        patches[0] = _patch(firstOffset, 10_000);
        patches[1] = _patch(secondOffset, 10_000);
        bytes memory original = abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(11), uint256(22), uint256(33));
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _call(address(patchTarget), original, _noCheckpoints(), patches);
        vm.expectCall(address(token), abi.encodeCall(IERC20.balanceOf, (pair.customAccount)), uint64(1));

        if (firstOffset < secondOffset) {
            IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);
            bytes memory expected = original;
            assembly ("memory-safe") {
                mstore(add(add(expected, 32), firstOffset), tokenBalance)
                mstore(add(add(expected, 32), secondOffset), tokenBalance)
            }
            assertEq(patchTarget.observedData(), expected, "sorted patches changed unexpected bytes");
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefiSimplify7702Account.UnsortedPatchOffset.selector, 0, 1, firstOffset, secondOffset
                )
            );
            IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);
        }
    }

    /// @dev Compares the implementation's record root with an independent nested-map derivation.
    /// @param invocationId Arbitrary invocation scope identifier.
    /// @param checkpointId Arbitrary logical checkpoint identifier.
    function testFuzz_CheckpointSlotDerivationMatchesIndependentReference(uint256 invocationId, bytes32 checkpointId)
        external
        view
    {
        (bytes32 lockSlot, bytes32 counterSlot, bytes32 tableNamespace) = checkpointHarness.checkpointNamespaces();
        bytes32 invocationRoot = keccak256(abi.encode(invocationId, tableNamespace));
        bytes32 expectedRecordRoot = keccak256(abi.encode(checkpointId, invocationRoot));
        bytes32 actualRecordRoot = checkpointHarness.checkpointRecordRoot(invocationId, checkpointId);

        assertEq(actualRecordRoot, expectedRecordRoot, "manual nested mapping derivation");
        assertNotEq(actualRecordRoot, lockSlot, "record collided with lock");
        assertNotEq(actualRecordRoot, counterSlot, "record collided with counter");
        assertNotEq(bytes32(uint256(actualRecordRoot) + 1), bytes32(uint256(actualRecordRoot) + 2), "field collision");
    }

    function _dynamicCall(
        address callTarget,
        bytes memory data,
        IDefiSimplify7702Account.BalancePatch memory balancePatch
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](1);
        dynamicCall.patches[0] = balancePatch;
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

    function _singleCheckpoint(bytes32 checkpointId)
        private
        view
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = IDefiSimplify7702Account.BalanceCheckpoint({token: address(token), id: checkpointId});
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

    function _patch(uint32 offset, uint16 bps) private view returns (IDefiSimplify7702Account.BalancePatch memory) {
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

    function _validId(bytes32 rawId) private pure returns (bytes32) {
        return rawId == bytes32(0) ? bytes32(uint256(1)) : rawId;
    }

    function _distinctId(bytes32 rawId, bytes32 otherId) private pure returns (bytes32 id) {
        id = _validId(rawId);
        if (id == otherId) {
            id = bytes32(uint256(id) ^ 1);
            if (id == bytes32(0)) {
                id = bytes32(uint256(2));
            }
        }
    }
}
