// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Test} from "forge-std/Test.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";

contract FlowAssertionsFuzzTest is Test {
    bytes32 private constant CHECKPOINT = keccak256("fuzz-flow-assertion");

    FlowAssertions private assertions;
    AssertionBalanceToken private token;

    function setUp() external {
        assertions = new FlowAssertions();
        token = new AssertionBalanceToken();
    }

    function testFuzz_BalanceAtLeastMatchesUnsignedComparison(uint256 currentBalance, uint256 minimum) external {
        token.setBalance(address(this), currentBalance);

        if (currentBalance >= minimum) {
            assertions.assertBalanceAtLeast(address(token), minimum);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceBelowMinimum.selector, address(token), currentBalance, minimum
                )
            );
            assertions.assertBalanceAtLeast(address(token), minimum);
        }
    }

    function testFuzz_IncreaseAtLeastMatchesSaturatingDelta(
        uint256 checkpointBalance,
        uint256 currentBalance,
        uint256 minimumDelta
    ) external {
        token.setBalance(address(this), checkpointBalance);
        assertions.snapshotBalance(address(token), CHECKPOINT);
        token.setBalance(address(this), currentBalance);
        uint256 actualDelta = currentBalance > checkpointBalance ? currentBalance - checkpointBalance : 0;

        if (actualDelta >= minimumDelta) {
            assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT, minimumDelta);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceIncreaseTooSmall.selector,
                    address(token),
                    CHECKPOINT,
                    actualDelta,
                    minimumDelta
                )
            );
            assertions.assertBalanceIncreaseAtLeast(address(token), CHECKPOINT, minimumDelta);
        }
    }

    function testFuzz_DecreaseAtMostMatchesSaturatingDelta(
        uint256 checkpointBalance,
        uint256 currentBalance,
        uint256 maximumDelta
    ) external {
        token.setBalance(address(this), checkpointBalance);
        assertions.snapshotBalance(address(token), CHECKPOINT);
        token.setBalance(address(this), currentBalance);
        uint256 actualDelta = checkpointBalance > currentBalance ? checkpointBalance - currentBalance : 0;

        if (actualDelta <= maximumDelta) {
            assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT, maximumDelta);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceDecreaseTooLarge.selector,
                    address(token),
                    CHECKPOINT,
                    actualDelta,
                    maximumDelta
                )
            );
            assertions.assertBalanceDecreaseAtMost(address(token), CHECKPOINT, maximumDelta);
        }
    }
}
