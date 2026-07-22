// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {Test} from "forge-std/Test.sol";
import {FlowAssertionsHarness} from "../mocks/FlowAssertionsMocks.sol";

contract TransientNamespaceSeparationTest is Test {
    using SlotDerivation for bytes32;

    bytes32 private constant CHECKPOINT_ID = keccak256("namespace-separation");

    FlowAssertionsHarness private assertions;

    function setUp() external {
        assertions = new FlowAssertionsHarness();
    }

    function test_AccountAndAssertionTransientNamespacesAndRecordLayoutRemainSeparated() external view {
        bytes32 lockNamespace = keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");
        bytes32 invocationNamespace = keccak256("DefiSimplify7702Account.dynamicInvocationCounter.v1");
        bytes32 checkpointNamespace = keccak256("DefiSimplify7702Account.checkpointTable.v1");
        bytes32 assertionNamespace = keccak256("FlowAssertions.balanceSnapshotTable.v1");

        assertNotEq(lockNamespace, invocationNamespace, "lock/invocation namespace collision");
        assertNotEq(lockNamespace, checkpointNamespace, "lock/checkpoint namespace collision");
        assertNotEq(lockNamespace, assertionNamespace, "lock/assertion namespace collision");
        assertNotEq(invocationNamespace, checkpointNamespace, "invocation/checkpoint namespace collision");
        assertNotEq(invocationNamespace, assertionNamespace, "invocation/assertion namespace collision");
        assertNotEq(checkpointNamespace, assertionNamespace, "checkpoint/assertion namespace collision");

        bytes32 expectedRoot = assertionNamespace.deriveMapping(address(this)).deriveMapping(CHECKPOINT_ID);
        bytes32 actualRoot = assertions.snapshotRecordRoot(address(this), CHECKPOINT_ID);
        assertEq(assertions.snapshotNamespace(), assertionNamespace, "assertion namespace");
        assertEq(actualRoot, expectedRoot, "assertion nested mapping derivation");
        assertNotEq(actualRoot, actualRoot.offset(1), "presence/token slot collision");
        assertNotEq(actualRoot.offset(1), actualRoot.offset(2), "token/balance slot collision");
    }
}
