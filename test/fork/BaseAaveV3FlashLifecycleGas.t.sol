// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAaveV3FlashLifecycleFixture} from "./BaseAaveV3FlashLifecycleFixture.sol";

contract BaseAaveV3FlashLifecycleGasForkTest is BaseAaveV3FlashLifecycleFixture {
    uint256 private constant BASE_FLASH_LIFECYCLE_GAS_AUTHORITY_KEY = 0xD5C8202;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    FlowAssertions private flowAssertions;
    StaticCallUint256Assertions private staticAssertions;

    function setUp() external {
        _setUpPinnedBaseAaveFlashLifecycleFork();
        accountUnderTest =
            _deployDelegatedDefiSimplifyAccount(_baseEntryPoint(), BASE_FLASH_LIFECYCLE_GAS_AUTHORITY_KEY);
        flowAssertions = new FlowAssertions();
        staticAssertions = new StaticCallUint256Assertions();
        _assertNoAavePosition(accountUnderTest.delegatedEoa);
    }

    function test_Gas_BaseAaveFlashAssistedLeverageOpen() external {
        vm.pauseGasMetering();
        _fundLeverageOpenInventory(accountUnderTest.delegatedEoa);
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            premium,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            LEVERAGE_FLASH_WETH + premium
        );
        vm.resumeGasMetering();

        _executeDynamicCallsAsDelegatedEoa(accountUnderTest.delegatedEoa, calls);
    }

    function test_Gas_BaseAaveFlashAssistedPartialDeleverage() external {
        vm.pauseGasMetering();
        _openCbEthCollateralWethDebtPosition(accountUnderTest.delegatedEoa);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedPartialDeleverage(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            _aaveFlashPremium(PARTIAL_FLASH_WETH),
            PARTIAL_MAXIMUM_CBETH_INPUT,
            MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR
        );
        vm.resumeGasMetering();

        _executeDynamicCallsAsDelegatedEoa(accountUnderTest.delegatedEoa, calls);
    }

    function test_Gas_BaseAaveFlashAssistedFullClose() external {
        vm.pauseGasMetering();
        _openCbEthCollateralWethDebtPosition(accountUnderTest.delegatedEoa);
        uint256 observedDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(accountUnderTest.delegatedEoa);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedFullClose(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            staticAssertions,
            observedDebt,
            _aaveFlashPremium(observedDebt),
            FULL_CLOSE_MAXIMUM_CBETH_INPUT
        );
        vm.resumeGasMetering();

        _executeDynamicCallsAsDelegatedEoa(accountUnderTest.delegatedEoa, calls);
    }
}
