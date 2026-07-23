// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {Test} from "forge-std/Test.sol";
import {FlowAssertionsHarness} from "../mocks/FlowAssertionsMocks.sol";

contract TransientNamespaceSeparationTest is Test {
    using SlotDerivation for bytes32;

    bytes32 private constant CHECKPOINT_ID = keccak256("namespace-separation");

    FlowAssertionsHarness private flowAssertions;

    function setUp() external {
        flowAssertions = new FlowAssertionsHarness();
    }

    function test_AccountAndAssertionTransientNamespacesAndRecordLayoutRemainSeparated() external view {
        bytes32[] memory namespaces = new bytes32[](9);
        namespaces[0] = keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");
        namespaces[1] = keccak256("DefiSimplify7702Account.dynamicInvocationCounter.v1");
        namespaces[2] = keccak256("DefiSimplify7702Account.checkpointTable.v1");
        namespaces[3] = keccak256("DefiSimplify7702Account.callbackState.v1");
        namespaces[4] = keccak256("DefiSimplify7702Account.callbackTarget.v1");
        namespaces[5] = keccak256("DefiSimplify7702Account.callbackCalldataHash.v1");
        namespaces[6] = keccak256("DefiSimplify7702Account.callbackCallIndex.v1");
        namespaces[7] = keccak256("DefiSimplify7702Account.callbackRepaymentToken.v1");
        namespaces[8] = keccak256("FlowAssertions.balanceSnapshotTable.v1");

        for (uint256 firstIndex = 0; firstIndex < namespaces.length; ++firstIndex) {
            for (uint256 secondIndex = firstIndex + 1; secondIndex < namespaces.length; ++secondIndex) {
                assertNotEq(namespaces[firstIndex], namespaces[secondIndex], "transient namespace collision");
            }
        }

        bytes32 expectedRoot = namespaces[8].deriveMapping(address(this)).deriveMapping(CHECKPOINT_ID);
        bytes32 actualRoot = flowAssertions.snapshotRecordRoot(address(this), CHECKPOINT_ID);
        assertEq(flowAssertions.snapshotNamespace(), namespaces[8], "assertion namespace");
        assertEq(actualRoot, expectedRoot, "assertion nested mapping derivation");
        assertNotEq(actualRoot, actualRoot.offset(1), "presence/token slot collision");
        assertNotEq(actualRoot.offset(1), actualRoot.offset(2), "token/balance slot collision");
    }
}
