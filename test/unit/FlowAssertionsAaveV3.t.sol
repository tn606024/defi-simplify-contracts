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
    FlowAssertions private assertions;
    AaveV3PoolMock private pool;

    function setUp() external {
        assertions = new FlowAssertions();
        pool = new AaveV3PoolMock();
    }

    function test_HealthyAccountPassesAtEqualityAndAboveMinimum() external {
        pool.setHealthFactor(address(this), 1.5e18);

        assertions.assertAaveV3HealthFactorAtLeast(address(pool), 1.4e18);
        assertions.assertAaveV3HealthFactorAtLeast(address(pool), 1.5e18);
    }

    function test_HealthFactorBelowMinimumReportsPoolActualAndMinimum() external {
        pool.setHealthFactor(address(this), 1.2e18);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(pool), 1.2e18, 1.25e18)
        );
        assertions.assertAaveV3HealthFactorAtLeast(address(pool), 1.25e18);
    }

    function test_ZeroAndNoPositionSemanticsFollowPoolReportedValue() external {
        pool.setHealthFactor(address(this), 0);
        assertions.assertAaveV3HealthFactorAtLeast(address(pool), 0);

        pool.setHealthFactor(address(this), type(uint256).max);
        assertions.assertAaveV3HealthFactorAtLeast(address(pool), type(uint256).max);
    }

    function test_DifferentCallersUseTheirOwnAaveV3AccountData() external {
        AaveV3AssertionCaller first = new AaveV3AssertionCaller();
        AaveV3AssertionCaller second = new AaveV3AssertionCaller();
        pool.setHealthFactor(address(first), 2e18);
        pool.setHealthFactor(address(second), 1.1e18);

        first.assertHealthFactorAtLeast(assertions, address(pool), 2e18);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(pool), 1.1e18, 1.2e18)
        );
        second.assertHealthFactorAtLeast(assertions, address(pool), 1.2e18);
    }

    function test_PoolReceivesDirectCallerInsteadOfAssertionContract() external {
        AaveV3AssertionCaller caller = new AaveV3AssertionCaller();
        pool.setHealthFactor(address(caller), 1.7e18);
        pool.setHealthFactor(address(assertions), 0);
        pool.setHealthFactor(address(this), 0);

        caller.assertHealthFactorAtLeast(assertions, address(pool), 1.7e18);
    }

    function test_RevertingPoolPreservesCompleteReason() external {
        bytes memory payload = bytes("aave-v3-account-data-revert");
        RevertingAaveV3Pool revertingPool = new RevertingAaveV3Pool(41, payload);
        bytes memory reason = abi.encodeWithSelector(RevertingAaveV3Pool.AccountDataFailure.selector, 41, payload);

        vm.expectRevert(
            abi.encodeWithSelector(IFlowAssertions.AaveV3AccountDataReadFailed.selector, address(revertingPool), reason)
        );
        assertions.assertAaveV3HealthFactorAtLeast(address(revertingPool), 0);
    }

    function test_ShortSuccessfulPoolReadPreservesCompleteMalformedBytes() external {
        ShortReturnAaveV3Pool shortPool = new ShortReturnAaveV3Pool();

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlowAssertions.AaveV3AccountDataReadFailed.selector, address(shortPool), hex"123456"
            )
        );
        assertions.assertAaveV3HealthFactorAtLeast(address(shortPool), 0);
    }

    function test_NoCodePoolIsMalformedWithEmptyReason() external {
        address noCode = address(0xA4A4);

        vm.expectRevert(abi.encodeWithSelector(IFlowAssertions.AaveV3AccountDataReadFailed.selector, noCode, bytes("")));
        assertions.assertAaveV3HealthFactorAtLeast(noCode, 0);
    }

    function test_FakePoolDemonstratesExplicitTargetTrustAssumption() external {
        FakeAaveV3Pool fakePool = new FakeAaveV3Pool();

        assertions.assertAaveV3HealthFactorAtLeast(address(fakePool), type(uint256).max);
    }

    function test_AaveV3AssertionEmitsNoCustomEvent() external {
        pool.setHealthFactor(address(this), 1.3e18);

        vm.recordLogs();
        assertions.assertAaveV3HealthFactorAtLeast(address(pool), 1.3e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected Aave V3 assertion event");
    }
}
