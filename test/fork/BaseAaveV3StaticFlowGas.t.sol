// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAaveV3StaticFlowFixture} from "./BaseAaveV3StaticFlowFixture.sol";

contract BaseAaveV3StaticFlowGasForkTest is BaseAaveV3StaticFlowFixture {
    uint256 private constant BASE_STATIC_GAS_AUTHORITY_KEY = 0xD5C5201;

    DelegatedDefiSimplifyAccount private accountUnderTest;

    function setUp() external {
        _setUpPinnedBaseAaveFork();
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(_baseEntryPoint(), BASE_STATIC_GAS_AUTHORITY_KEY);
        _assertNoAavePosition(accountUnderTest.delegatedEoa);
        _wrapNativeAsDelegatedEoa(accountUnderTest.delegatedEoa, WETH_COLLATERAL_AMOUNT);
    }

    function test_Gas_BaseAaveApproveAndSupplyStaticBatch() external {
        _executeBatchAsDelegatedEoa(
            accountUnderTest.delegatedEoa,
            _buildApproveAndSupplyBatch(accountUnderTest.delegatedEoa, WETH_COLLATERAL_AMOUNT)
        );
    }

    function test_Gas_BaseAaveSupplyAndBorrowStaticBatch() external {
        vm.pauseGasMetering();
        _approveAssetAsDelegatedEoa(accountUnderTest.delegatedEoa, BASE_WETH, WETH_COLLATERAL_AMOUNT);
        vm.resumeGasMetering();

        _executeBatchAsDelegatedEoa(
            accountUnderTest.delegatedEoa,
            _buildSupplyAndBorrowBatch(accountUnderTest.delegatedEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
    }

    function test_Gas_BaseAaveRepayAndWithdrawStaticBatch() external {
        vm.pauseGasMetering();
        _executeBatchAsDelegatedEoa(
            accountUnderTest.delegatedEoa,
            _buildOpenPositionBatch(accountUnderTest.delegatedEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
        uint256 exactDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(accountUnderTest.delegatedEoa);
        _fundExactUsdcRepaymentBalance(accountUnderTest.delegatedEoa, exactDebt);
        _approveAssetAsDelegatedEoa(accountUnderTest.delegatedEoa, BASE_USDC, exactDebt);
        vm.resumeGasMetering();

        _executeBatchAsDelegatedEoa(
            accountUnderTest.delegatedEoa, _buildRepayAndWithdrawBatch(accountUnderTest.delegatedEoa, exactDebt)
        );
    }
}
