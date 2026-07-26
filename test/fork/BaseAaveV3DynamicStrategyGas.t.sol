// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAaveV3DynamicStrategyFixture} from "./BaseAaveV3DynamicStrategyFixture.sol";

contract BaseAaveV3DynamicStrategyGasForkTest is BaseAaveV3DynamicStrategyFixture {
    uint256 private constant BASE_DYNAMIC_STRATEGY_GAS_AUTHORITY_KEY = 0xD5C5702;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    FlowAssertions private flowAssertions;

    function setUp() external {
        _setUpPinnedBaseAaveAndUniswapFork();
        accountUnderTest =
            _deployDelegatedDefiSimplifyAccount(_baseEntryPoint(), BASE_DYNAMIC_STRATEGY_GAS_AUTHORITY_KEY);
        flowAssertions = new FlowAssertions();
        _assertNoAavePosition(accountUnderTest.delegatedEoa);
        _fundWethCollateralUsdcDebtLoopInventory(accountUnderTest.delegatedEoa);
    }

    function test_Gas_BaseAaveWethCollateralUsdcDebtLoop() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildWethCollateralUsdcDebtLoopStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            MINIMUM_WETH_SWAP_OUTPUT,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            MINIMUM_FINAL_HEALTH_FACTOR
        );

        _executeDynamicCallsAsDelegatedEoa(accountUnderTest.delegatedEoa, calls);
    }
}
