// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Test} from "forge-std/Test.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";

contract FlowAssertionsFuzzTest is Test {
    bytes32 private constant CHECKPOINT_ID = keccak256("fuzz-flow-assertion");

    FlowAssertions private flowAssertions;
    AssertionBalanceToken private balanceToken;

    function setUp() external {
        flowAssertions = new FlowAssertions();
        balanceToken = new AssertionBalanceToken();
    }

    function testFuzz_BalanceAtLeastMatchesUnsignedComparison(uint256 currentBalance, uint256 minimum) external {
        balanceToken.setBalance(address(this), currentBalance);

        if (currentBalance >= minimum) {
            flowAssertions.assertBalanceAtLeast(address(balanceToken), minimum);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceBelowMinimum.selector, address(balanceToken), currentBalance, minimum
                )
            );
            flowAssertions.assertBalanceAtLeast(address(balanceToken), minimum);
        }
    }

    function testFuzz_IncreaseAtLeastMatchesSaturatingDelta(
        uint256 checkpointBalance,
        uint256 currentBalance,
        uint256 minimumDelta
    ) external {
        balanceToken.setBalance(address(this), checkpointBalance);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_ID);
        balanceToken.setBalance(address(this), currentBalance);
        uint256 actualDelta = currentBalance > checkpointBalance ? currentBalance - checkpointBalance : 0;

        if (actualDelta >= minimumDelta) {
            flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_ID, minimumDelta);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceIncreaseTooSmall.selector,
                    address(balanceToken),
                    CHECKPOINT_ID,
                    actualDelta,
                    minimumDelta
                )
            );
            flowAssertions.assertBalanceIncreaseAtLeast(address(balanceToken), CHECKPOINT_ID, minimumDelta);
        }
    }

    function testFuzz_DecreaseAtMostMatchesSaturatingDelta(
        uint256 checkpointBalance,
        uint256 currentBalance,
        uint256 maximumDelta
    ) external {
        balanceToken.setBalance(address(this), checkpointBalance);
        flowAssertions.snapshotBalance(address(balanceToken), CHECKPOINT_ID);
        balanceToken.setBalance(address(this), currentBalance);
        uint256 actualDelta = checkpointBalance > currentBalance ? checkpointBalance - currentBalance : 0;

        if (actualDelta <= maximumDelta) {
            flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_ID, maximumDelta);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IFlowAssertions.BalanceDecreaseTooLarge.selector,
                    address(balanceToken),
                    CHECKPOINT_ID,
                    actualDelta,
                    maximumDelta
                )
            );
            flowAssertions.assertBalanceDecreaseAtMost(address(balanceToken), CHECKPOINT_ID, maximumDelta);
        }
    }
}
