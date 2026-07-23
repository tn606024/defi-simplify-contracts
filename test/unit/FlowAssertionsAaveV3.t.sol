// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {
    AaveV3AssertionCaller,
    AaveV3PoolMock,
    FakeAaveV3Pool,
    RevertingAaveV3Pool,
    ShortReturnAaveV3Pool
} from "../mocks/AaveV3PoolMocks.sol";

contract FlowAssertionsAaveV3Test is Test {
    FlowAssertions private flowAssertions;
    AaveV3PoolMock private aavePool;

    function setUp() external {
        flowAssertions = new FlowAssertions();
        aavePool = new AaveV3PoolMock();
    }

    function test_HealthyAccountPassesAtEqualityAndAboveMinimum() external {
        aavePool.setHealthFactor(address(this), 1.5e18);

        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), 1.4e18);
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), 1.5e18);
    }

    function test_HealthFactorBelowMinimumReportsPoolActualAndMinimum() external {
        aavePool.setHealthFactor(address(this), 1.2e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(aavePool), 1.2e18, 1.25e18
            )
        );
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), 1.25e18);
    }

    function test_ZeroAndNoPositionSemanticsFollowPoolReportedValue() external {
        aavePool.setHealthFactor(address(this), 0);
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), 0);

        aavePool.setHealthFactor(address(this), type(uint256).max);
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), type(uint256).max);
    }

    function test_DifferentCallersUseTheirOwnAaveV3AccountData() external {
        AaveV3AssertionCaller first = new AaveV3AssertionCaller();
        AaveV3AssertionCaller second = new AaveV3AssertionCaller();
        aavePool.setHealthFactor(address(first), 2e18);
        aavePool.setHealthFactor(address(second), 1.1e18);

        first.assertHealthFactorAtLeast(flowAssertions, address(aavePool), 2e18);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(aavePool), 1.1e18, 1.2e18)
        );
        second.assertHealthFactorAtLeast(flowAssertions, address(aavePool), 1.2e18);
    }

    function test_PoolReceivesDirectCallerInsteadOfAssertionContract() external {
        AaveV3AssertionCaller caller = new AaveV3AssertionCaller();
        aavePool.setHealthFactor(address(caller), 1.7e18);
        aavePool.setHealthFactor(address(flowAssertions), 0);
        aavePool.setHealthFactor(address(this), 0);

        caller.assertHealthFactorAtLeast(flowAssertions, address(aavePool), 1.7e18);
    }

    function test_RevertingPoolPreservesCompleteReason() external {
        bytes memory payload = bytes("aave-v3-account-data-revert");
        RevertingAaveV3Pool revertingPool = new RevertingAaveV3Pool(41, payload);
        bytes memory reason = abi.encodeWithSelector(RevertingAaveV3Pool.AccountDataFailure.selector, 41, payload);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AaveV3AccountDataReadFailed.selector, address(revertingPool), reason)
        );
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(revertingPool), 0);
    }

    function test_ShortSuccessfulPoolReadPreservesCompleteMalformedBytes() external {
        ShortReturnAaveV3Pool shortPool = new ShortReturnAaveV3Pool();

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AaveV3AccountDataReadFailed.selector, address(shortPool), hex"123456"
            )
        );
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(shortPool), 0);
    }

    function test_NoCodePoolIsMalformedWithEmptyReason() external {
        address noCode = address(0xA4A4);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.AaveV3AccountDataReadFailed.selector, noCode, bytes("")));
        flowAssertions.assertAaveV3HealthFactorAtLeast(noCode, 0);
    }

    function test_FakePoolDemonstratesExplicitTargetTrustAssumption() external {
        FakeAaveV3Pool fakePool = new FakeAaveV3Pool();

        flowAssertions.assertAaveV3HealthFactorAtLeast(address(fakePool), type(uint256).max);
    }

    function test_AaveV3AssertionEmitsNoCustomEvent() external {
        aavePool.setHealthFactor(address(this), 1.3e18);

        vm.recordLogs();
        flowAssertions.assertAaveV3HealthFactorAtLeast(address(aavePool), 1.3e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected Aave V3 assertion event");
    }
}
