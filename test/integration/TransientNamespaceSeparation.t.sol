// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TransientAccountCheckpointTable} from "../../src/libraries/TransientAccountCheckpointTable.sol";
import {TransientAssertionSnapshotTable} from "../../src/libraries/TransientAssertionSnapshotTable.sol";
import {TransientCallbackCommitment} from "../../src/libraries/TransientCallbackCommitment.sol";
import {TransientDynamicExecutionLock} from "../../src/libraries/TransientDynamicExecutionLock.sol";
import {TransientInvocationCounter} from "../../src/libraries/TransientInvocationCounter.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {Test} from "forge-std/Test.sol";
import {FlowAssertionsHarness} from "../mocks/FlowAssertionsMocks.sol";

contract TransientNamespaceSeparationTest is Test {
    using SlotDerivation for bytes32;

    bytes32 private constant CHECKPOINT_ID = keccak256("namespace-separation");
    uint256 private constant INVOCATION_ID = 7;

    FlowAssertionsHarness private flowAssertions;

    function setUp() external {
        flowAssertions = new FlowAssertionsHarness();
    }

    function test_SemanticTransientNamespaces_MatchIndependentErc7201Derivation() external pure {
        assertEq(
            TransientDynamicExecutionLock.slot(),
            _erc7201Root("DefiSimplify7702Account.transient.dynamicExecutionLock"),
            "dynamic execution lock slot"
        );
        assertEq(
            TransientInvocationCounter.slot(),
            _erc7201Root("DefiSimplify7702Account.transient.dynamicInvocationCounter"),
            "dynamic invocation counter slot"
        );
        assertEq(
            TransientAccountCheckpointTable.root(),
            _erc7201Root("DefiSimplify7702Account.transient.checkpointTable.v1"),
            "account checkpoint table root"
        );
        assertEq(
            TransientCallbackCommitment.root(),
            _erc7201Root("DefiSimplify7702Account.transient.callbackCommitment.v1"),
            "callback commitment root"
        );
        assertEq(
            TransientAssertionSnapshotTable.root(),
            _erc7201Root("FlowAssertions.transient.balanceSnapshotTable.v1"),
            "assertion snapshot table root"
        );
    }

    function test_AllOccupiedTransientSlots_ArePairwiseSeparated() external view {
        bytes32 callbackRoot = TransientCallbackCommitment.root();
        bytes32 checkpointRecordRoot = TransientAccountCheckpointTable.recordRoot(INVOCATION_ID, CHECKPOINT_ID);
        bytes32 assertionRecordRoot = TransientAssertionSnapshotTable.recordRoot(address(this), CHECKPOINT_ID);

        bytes32[] memory occupiedSlots = new bytes32[](15);
        occupiedSlots[0] = TransientDynamicExecutionLock.slot();
        occupiedSlots[1] = TransientInvocationCounter.slot();
        occupiedSlots[2] = callbackRoot;
        occupiedSlots[3] = callbackRoot.offset(1);
        occupiedSlots[4] = callbackRoot.offset(2);
        occupiedSlots[5] = callbackRoot.offset(3);
        occupiedSlots[6] = callbackRoot.offset(4);
        occupiedSlots[7] = checkpointRecordRoot;
        occupiedSlots[8] = checkpointRecordRoot.offset(1);
        occupiedSlots[9] = checkpointRecordRoot.offset(2);
        occupiedSlots[10] = assertionRecordRoot;
        occupiedSlots[11] = assertionRecordRoot.offset(1);
        occupiedSlots[12] = assertionRecordRoot.offset(2);
        occupiedSlots[13] = TransientAccountCheckpointTable.root();
        occupiedSlots[14] = TransientAssertionSnapshotTable.root();

        for (uint256 firstIndex = 0; firstIndex < occupiedSlots.length; ++firstIndex) {
            for (uint256 secondIndex = firstIndex + 1; secondIndex < occupiedSlots.length; ++secondIndex) {
                assertNotEq(occupiedSlots[firstIndex], occupiedSlots[secondIndex], "transient slot collision");
            }
        }
    }

    function test_AssertionSnapshotRecord_UsesFrozenCallerScopedTableRoot() external view {
        bytes32 expectedTableRoot = _erc7201Root("FlowAssertions.transient.balanceSnapshotTable.v1");
        bytes32 expectedRecordRoot = expectedTableRoot.deriveMapping(address(this)).deriveMapping(CHECKPOINT_ID);

        assertEq(flowAssertions.snapshotTableRoot(), expectedTableRoot, "assertion table root");
        assertEq(
            flowAssertions.snapshotRecordRoot(address(this), CHECKPOINT_ID),
            expectedRecordRoot,
            "assertion caller-scoped record root"
        );
    }

    function _erc7201Root(string memory namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
    }
}
