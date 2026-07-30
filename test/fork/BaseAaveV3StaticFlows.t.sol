// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseAaveV3StaticFlowFixture, IBaseAaveV3Pool} from "./BaseAaveV3StaticFlowFixture.sol";

/// @title Base Aave V3 Static Delegated-Account Lifecycle Fork Tests
/// @notice Proves inherited execute and executeBatch behavior against Aave V3 at pinned Base block
///         48,961,870, including delegated-EOA position ownership, upstream compatibility, exact
///         open/close accounting, indexed failure attribution, and atomic rollback.
contract BaseAaveV3StaticFlowsForkTest is BaseAaveV3StaticFlowFixture {
    uint256 private constant BASE_STATIC_UPSTREAM_AUTHORITY_KEY = 0xA1152;
    uint256 private constant BASE_STATIC_DEFI_SIMPLIFY_AUTHORITY_KEY = 0xD5C52;

    bytes32 private constant SUPPLY_EVENT_SIGNATURE = keccak256("Supply(address,address,address,uint256,uint16)");
    bytes32 private constant BORROW_EVENT_SIGNATURE =
        keccak256("Borrow(address,address,address,uint256,uint8,uint256,uint16)");
    bytes32 private constant REPAY_EVENT_SIGNATURE = keccak256("Repay(address,address,address,uint256,bool)");
    bytes32 private constant WITHDRAW_EVENT_SIGNATURE = keccak256("Withdraw(address,address,address,uint256)");
    bytes4 private constant HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD_SELECTOR = 0x6679996d;

    UpstreamCompatibilityFixture private compatibilityFixture;

    function setUp() external {
        _setUpPinnedBaseAaveFork();
        compatibilityFixture = _deployUpstreamCompatibilityFixture(
            _baseEntryPoint(), BASE_STATIC_UPSTREAM_AUTHORITY_KEY, BASE_STATIC_DEFI_SIMPLIFY_AUTHORITY_KEY
        );
        _assertNoAavePosition(compatibilityFixture.upstream.delegatedEoa);
        _assertNoAavePosition(compatibilityFixture.defiSimplify.delegatedEoa);
    }

    function test_InheritedExecute_AaveSupplyCreditsCollateralToDelegatedEoa() external {
        address payable delegatedEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _wrapNativeAsDelegatedEoa(delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _approveAssetAsDelegatedEoa(delegatedEoa, BASE_WETH, WETH_COLLATERAL_AMOUNT);

        vm.recordLogs();
        _executeAsDelegatedEoa(
            delegatedEoa,
            AAVE_V3_POOL,
            0,
            abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_WETH, WETH_COLLATERAL_AMOUNT, delegatedEoa, NO_REFERRAL_CODE))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSupplyEvent(logs, delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _assertNoLogsEmittedByDelegatedAccount(logs, delegatedEoa);
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), 0, "supplied WETH left delegated EOA");
        assertApproxEqAbs(
            IERC20(BASE_AAVE_WETH).balanceOf(delegatedEoa),
            WETH_COLLATERAL_AMOUNT,
            1,
            "one-call supply credited delegated EOA"
        );
        assertGt(_readAaveAccountData(delegatedEoa).totalCollateralBase, 0, "one-call Aave collateral");
    }

    function test_ApproveAndSupplyBatch_CreditsAaveCollateralToDelegatedEoa() external {
        address payable delegatedEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _wrapNativeAsDelegatedEoa(delegatedEoa, WETH_COLLATERAL_AMOUNT);

        vm.recordLogs();
        _executeBatchAsDelegatedEoa(delegatedEoa, _buildApproveAndSupplyBatch(delegatedEoa, WETH_COLLATERAL_AMOUNT));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSupplyEvent(logs, delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _assertNoLogsEmittedByDelegatedAccount(logs, delegatedEoa);
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), 0, "supplied WETH left account");
        assertApproxEqAbs(
            IERC20(BASE_AAVE_WETH).balanceOf(delegatedEoa),
            WETH_COLLATERAL_AMOUNT,
            1,
            "aWETH credited within current-index rounding"
        );
        assertEq(IERC20(BASE_WETH).allowance(delegatedEoa, AAVE_V3_POOL), 0, "exact supply allowance consumed");

        AaveAccountData memory accountData = _readAaveAccountData(delegatedEoa);
        assertGt(accountData.totalCollateralBase, 0, "Aave collateral belongs to delegated EOA");
        assertEq(accountData.totalDebtBase, 0, "supply does not create debt");
        assertEq(accountData.healthFactor, type(uint256).max, "collateral-only Aave health factor");
        _assertNoAavePosition(address(compatibilityFixture.defiSimplify.implementation));
        _assertNoAavePosition(address(this));
    }

    function test_SupplyAndBorrowBatch_CreatesDebtAndTransfersBorrowedAssetToDelegatedEoa() external {
        address payable delegatedEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _wrapNativeAsDelegatedEoa(delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _approveAssetAsDelegatedEoa(delegatedEoa, BASE_WETH, WETH_COLLATERAL_AMOUNT);

        vm.recordLogs();
        _executeBatchAsDelegatedEoa(
            delegatedEoa, _buildSupplyAndBorrowBatch(delegatedEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSupplyEvent(logs, delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _assertBorrowEvent(logs, delegatedEoa, USDC_BORROW_AMOUNT);
        _assertNoLogsEmittedByDelegatedAccount(logs, delegatedEoa);
        assertEq(IERC20(BASE_USDC).balanceOf(delegatedEoa), USDC_BORROW_AMOUNT, "borrowed USDC receiver");
        assertApproxEqAbs(
            IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(delegatedEoa),
            USDC_BORROW_AMOUNT,
            1,
            "variable debt assigned to delegated EOA"
        );

        AaveAccountData memory accountData = _readAaveAccountData(delegatedEoa);
        assertGt(accountData.totalCollateralBase, 0, "delegated EOA collateral");
        assertGt(accountData.totalDebtBase, 0, "delegated EOA debt");
        assertGt(accountData.healthFactor, 1 ether, "representative position remains healthy");
        _assertNoAavePosition(address(compatibilityFixture.defiSimplify.implementation));
        _assertNoAavePosition(address(this));
    }

    function test_RepayAndWithdrawBatch_ClosesDelegatedEoaPositionAndReturnsCollateral() external {
        address payable delegatedEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _openPosition(delegatedEoa);
        uint256 exactDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(delegatedEoa);
        uint256 withdrawableCollateral = IERC20(BASE_AAVE_WETH).balanceOf(delegatedEoa);
        _fundExactUsdcRepaymentBalance(delegatedEoa, exactDebt);
        _approveAssetAsDelegatedEoa(delegatedEoa, BASE_USDC, exactDebt);

        vm.recordLogs();
        _executeBatchAsDelegatedEoa(delegatedEoa, _buildRepayAndWithdrawBatch(delegatedEoa, exactDebt));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRepayEvent(logs, delegatedEoa, exactDebt);
        _assertWithdrawEvent(logs, delegatedEoa, withdrawableCollateral);
        _assertNoLogsEmittedByDelegatedAccount(logs, delegatedEoa);
        assertEq(IERC20(BASE_USDC).allowance(delegatedEoa, AAVE_V3_POOL), 0, "exact repay allowance consumed");
        assertEq(IERC20(BASE_USDC).balanceOf(delegatedEoa), 0, "borrowed USDC repaid");
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), withdrawableCollateral, "collateral returned");
        _assertNoAavePosition(delegatedEoa);
    }

    /// @dev Given separate upstream and DeFi Simplify delegated EOAs funded with equal WETH. When
    ///      both execute the same approve/supply/borrow lifecycle and repay/withdraw close. Then
    ///      their Aave collateral, debt, balances, and health factors remain equivalent before
    ///      both positions return to the no-position state.
    function test_UpstreamAndDefiSimplifyStaticLifecycles_ReachEquivalentAaveState() external {
        address payable upstreamEoa = compatibilityFixture.upstream.delegatedEoa;
        address payable defiSimplifyEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _wrapNativeAsDelegatedEoa(upstreamEoa, WETH_COLLATERAL_AMOUNT);
        _wrapNativeAsDelegatedEoa(defiSimplifyEoa, WETH_COLLATERAL_AMOUNT);

        _executeBatchAsDelegatedEoa(
            upstreamEoa, _buildOpenPositionBatch(upstreamEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
        _executeBatchAsDelegatedEoa(
            defiSimplifyEoa, _buildOpenPositionBatch(defiSimplifyEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
        _assertEquivalentAaveState(upstreamEoa, defiSimplifyEoa);

        uint256 upstreamDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(upstreamEoa);
        uint256 defiSimplifyDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(defiSimplifyEoa);
        assertEq(upstreamDebt, defiSimplifyDebt, "equivalent variable debt before close");
        _fundExactUsdcRepaymentBalance(upstreamEoa, upstreamDebt);
        _fundExactUsdcRepaymentBalance(defiSimplifyEoa, defiSimplifyDebt);

        _executeBatchAsDelegatedEoa(upstreamEoa, _buildClosePositionBatch(upstreamEoa, upstreamDebt));
        _executeBatchAsDelegatedEoa(defiSimplifyEoa, _buildClosePositionBatch(defiSimplifyEoa, defiSimplifyDebt));
        _assertEquivalentAaveState(upstreamEoa, defiSimplifyEoa);
        _assertNoAavePosition(upstreamEoa);
        _assertNoAavePosition(defiSimplifyEoa);
    }

    /// @dev The third call deliberately over-borrows after approval and supply. Both account
    ///      variants must preserve call-index 2 and Aave's complete nested error while restoring
    ///      native/WETH balances, allowances, and the no-position protocol state.
    function test_LaterBorrowFailure_RollsBackEarlierApproveAndSupplyForBothAccountVariants() external {
        address payable upstreamEoa = compatibilityFixture.upstream.delegatedEoa;
        address payable defiSimplifyEoa = compatibilityFixture.defiSimplify.delegatedEoa;
        _wrapNativeAsDelegatedEoa(upstreamEoa, WETH_COLLATERAL_AMOUNT);
        _wrapNativeAsDelegatedEoa(defiSimplifyEoa, WETH_COLLATERAL_AMOUNT);
        uint256 upstreamNativeBefore = upstreamEoa.balance;
        uint256 defiSimplifyNativeBefore = defiSimplifyEoa.balance;

        (bool upstreamSuccess, bytes memory upstreamReason) =
            _invokeBatchAsDelegatedEoa(upstreamEoa, _buildFailingBorrowBatch(upstreamEoa));
        (bool defiSimplifySuccess, bytes memory defiSimplifyReason) =
            _invokeBatchAsDelegatedEoa(defiSimplifyEoa, _buildFailingBorrowBatch(defiSimplifyEoa));

        assertFalse(upstreamSuccess, "upstream failing Aave batch");
        assertFalse(defiSimplifySuccess, "DeFi Simplify failing Aave batch");
        bytes memory upstreamAaveReason = _assertExecuteErrorAtIndex(upstreamReason, 2);
        bytes memory defiSimplifyAaveReason = _assertExecuteErrorAtIndex(defiSimplifyReason, 2);
        assertEq(upstreamAaveReason, defiSimplifyAaveReason, "upstream/custom nested Aave failure");
        assertEq(
            upstreamAaveReason,
            abi.encodePacked(HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD_SELECTOR),
            "complete Aave health-factor failure"
        );

        assertEq(upstreamEoa.balance, upstreamNativeBefore, "upstream native balance rolled back");
        assertEq(defiSimplifyEoa.balance, defiSimplifyNativeBefore, "DeFi Simplify native balance rolled back");
        assertEq(IERC20(BASE_WETH).balanceOf(upstreamEoa), WETH_COLLATERAL_AMOUNT, "upstream WETH restored");
        assertEq(IERC20(BASE_WETH).balanceOf(defiSimplifyEoa), WETH_COLLATERAL_AMOUNT, "DeFi Simplify WETH restored");
        assertEq(IERC20(BASE_WETH).allowance(upstreamEoa, AAVE_V3_POOL), 0, "upstream approval rolled back");
        assertEq(IERC20(BASE_WETH).allowance(defiSimplifyEoa, AAVE_V3_POOL), 0, "DeFi Simplify approval rolled back");
        _assertNoAavePosition(upstreamEoa);
        _assertNoAavePosition(defiSimplifyEoa);
        _assertEquivalentAaveState(upstreamEoa, defiSimplifyEoa);
    }

    function _assertSupplyEvent(Vm.Log[] memory logs, address delegatedEoa, uint256 expectedAmount) private pure {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics[0] != SUPPLY_EVENT_SIGNATURE) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[1], _addressTopic(BASE_WETH), "Supply reserve");
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "Supply onBehalfOf");
            assertEq(logs[i].topics[3], bytes32(uint256(NO_REFERRAL_CODE)), "Supply referral code");
            (address user, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
            assertEq(user, delegatedEoa, "Supply user");
            assertEq(amount, expectedAmount, "Supply amount");
        }
        assertEq(matchingEvents, 1, "expected one Aave Supply event");
    }

    function _assertBorrowEvent(Vm.Log[] memory logs, address delegatedEoa, uint256 expectedAmount) private pure {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics[0] != BORROW_EVENT_SIGNATURE) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[1], _addressTopic(BASE_USDC), "Borrow reserve");
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "Borrow onBehalfOf");
            assertEq(logs[i].topics[3], bytes32(uint256(NO_REFERRAL_CODE)), "Borrow referral code");
            (address user, uint256 amount, uint8 interestRateMode,) =
                abi.decode(logs[i].data, (address, uint256, uint8, uint256));
            assertEq(user, delegatedEoa, "Borrow user");
            assertEq(amount, expectedAmount, "Borrow amount");
            assertEq(interestRateMode, VARIABLE_INTEREST_RATE_MODE, "Borrow interest-rate mode");
        }
        assertEq(matchingEvents, 1, "expected one Aave Borrow event");
    }

    function _assertRepayEvent(Vm.Log[] memory logs, address delegatedEoa, uint256 expectedAmount) private pure {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics[0] != REPAY_EVENT_SIGNATURE) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[1], _addressTopic(BASE_USDC), "Repay reserve");
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "Repay user");
            assertEq(logs[i].topics[3], _addressTopic(delegatedEoa), "Repay payer");
            (uint256 amount, bool useATokens) = abi.decode(logs[i].data, (uint256, bool));
            assertEq(amount, expectedAmount, "Repay amount");
            assertFalse(useATokens, "repayment uses underlying USDC");
        }
        assertEq(matchingEvents, 1, "expected one Aave Repay event");
    }

    function _assertWithdrawEvent(Vm.Log[] memory logs, address delegatedEoa, uint256 expectedAmount) private pure {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics[0] != WITHDRAW_EVENT_SIGNATURE) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[1], _addressTopic(BASE_WETH), "Withdraw reserve");
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "Withdraw user");
            assertEq(logs[i].topics[3], _addressTopic(delegatedEoa), "Withdraw receiver");
            assertEq(abi.decode(logs[i].data, (uint256)), expectedAmount, "Withdraw amount");
        }
        assertEq(matchingEvents, 1, "expected one Aave Withdraw event");
    }

    function _assertNoLogsEmittedByDelegatedAccount(Vm.Log[] memory logs, address delegatedEoa) private pure {
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, delegatedEoa, "delegated account emitted a custom event");
        }
    }

    function _addressTopic(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
