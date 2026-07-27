// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseAaveV3FlashLifecycleFixture, IBaseAaveV3FlashLifecyclePool} from "./BaseAaveV3FlashLifecycleFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

contract BaseAaveV3FlashLifecycleForkTest is BaseAaveV3FlashLifecycleFixture {
    uint256 private constant BASE_FLASH_LIFECYCLE_AUTHORITY_KEY = 0xD5C8201;

    uint256 private constant LEVERAGE_FLASH_CALL_INDEX = 3;
    uint256 private constant LEVERAGE_HEALTH_ASSERTION_CALL_INDEX = 4;
    uint256 private constant LEVERAGE_SWAP_CALLBACK_CALL_INDEX = 1;
    uint256 private constant PARTIAL_FLASH_CALL_INDEX = 1;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    FlowAssertions private flowAssertions;
    StaticCallUint256Assertions private staticAssertions;

    function setUp() external {
        _setUpPinnedBaseAaveFlashLifecycleFork();
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(_baseEntryPoint(), BASE_FLASH_LIFECYCLE_AUTHORITY_KEY);
        flowAssertions = new FlowAssertions();
        staticAssertions = new StaticCallUint256Assertions();
        _assertNoAavePosition(accountUnderTest.delegatedEoa);
    }

    function test_FlashAssistedLeverageOpen_UsesObservedSwapOutputAndRepaysExactly() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _fundLeverageOpenInventory(delegatedEoa);
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            delegatedEoa,
            flowAssertions,
            premium,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            LEVERAGE_FLASH_WETH + premium
        );

        vm.recordLogs();
        _executeDynamicCallsAsDelegatedEoa(delegatedEoa, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        FlashLoanObservation memory flashLoan = _readSingleFlashLoan(logs, delegatedEoa);
        SwapObservation memory swap = _readSingleCbEthWethSwap(logs, delegatedEoa, true);
        assertEq(flashLoan.amount, LEVERAGE_FLASH_WETH, "flash principal");
        assertEq(flashLoan.premium, premium, "bounded Aave premium");
        assertEq(swap.wethAmount, LEVERAGE_FLASH_WETH, "swap consumes only flash WETH");
        assertEq(swap.cbEthAmount, LEVERAGE_OBSERVED_CBETH_OUTPUT, "observed cbETH output");
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), EXISTING_WETH_INVENTORY, "WETH sentinel survives");
        assertEq(IERC20(BASE_CBETH).balanceOf(delegatedEoa), EXISTING_CBETH_INVENTORY, "cbETH sentinel survives");
        assertApproxEqAbs(
            IERC20(BASE_AAVE_CBETH).balanceOf(delegatedEoa),
            LEVERAGE_INITIAL_CBETH_SUPPLY + swap.cbEthAmount,
            2,
            "Aave collateral equals own capital plus observed swap output"
        );
        assertApproxEqAbs(
            IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa),
            LEVERAGE_FLASH_WETH + premium,
            1,
            "Aave WETH debt funds exact flash repayment"
        );

        AaveAccountData memory finalAaveState = _readAaveAccountData(delegatedEoa);
        assertGt(finalAaveState.totalCollateralBase, 0, "delegated EOA owns Aave collateral");
        assertGt(finalAaveState.totalDebtBase, 0, "delegated EOA owns Aave debt");
        assertGe(finalAaveState.healthFactor, MINIMUM_LEVERAGED_HEALTH_FACTOR, "guarded leverage health factor");
        assertEq(
            IBaseAaveV3FlashLifecyclePool(AAVE_V3_POOL).getUserEMode(delegatedEoa),
            ETH_CORRELATED_EMODE_CATEGORY,
            "ETH-correlated E-Mode remains active"
        );
        _assertNoResidualLifecycleAllowances(delegatedEoa);
        _assertOnlyDelegatedEoaOwnsAavePosition();
        _assertNoCustomLifecycleEvents(logs);
    }

    function test_FlashAssistedPartialDeleverage_ReducesDebtAndResuppliesOnlyOuterCheckpointRemainder() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _openCbEthCollateralWethDebtPosition(delegatedEoa);
        uint256 debtBefore = IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa);
        uint256 collateralBefore = IERC20(BASE_AAVE_CBETH).balanceOf(delegatedEoa);
        uint256 healthFactorBefore = _readAaveAccountData(delegatedEoa).healthFactor;
        uint256 premium = _aaveFlashPremium(PARTIAL_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedPartialDeleverage(
            delegatedEoa, flowAssertions, premium, PARTIAL_MAXIMUM_CBETH_INPUT, MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR
        );

        vm.recordLogs();
        _executeDynamicCallsAsDelegatedEoa(delegatedEoa, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        FlashLoanObservation memory flashLoan = _readSingleFlashLoan(logs, delegatedEoa);
        SwapObservation memory swap = _readSingleCbEthWethSwap(logs, delegatedEoa, false);
        assertEq(flashLoan.amount, PARTIAL_FLASH_WETH, "partial-deleverage flash principal");
        assertEq(flashLoan.premium, premium, "partial-deleverage premium");
        assertEq(swap.wethAmount, PARTIAL_FLASH_WETH + premium, "exact repayment output");
        assertEq(swap.cbEthAmount, PARTIAL_OBSERVED_CBETH_INPUT, "bounded cbETH sold");
        assertLe(swap.cbEthAmount, PARTIAL_MAXIMUM_CBETH_INPUT, "router-native maximum input");
        assertApproxEqAbs(
            IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa),
            debtBefore - PARTIAL_FLASH_WETH,
            1,
            "selected WETH debt amount repaid"
        );
        assertApproxEqAbs(
            IERC20(BASE_AAVE_CBETH).balanceOf(delegatedEoa),
            collateralBefore - swap.cbEthAmount,
            2,
            "only collateral actually sold remains withdrawn"
        );
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), EXISTING_WETH_INVENTORY, "WETH sentinel survives");
        assertEq(IERC20(BASE_CBETH).balanceOf(delegatedEoa), EXISTING_CBETH_INVENTORY, "cbETH sentinel survives");
        assertEq(
            PARTIAL_CBETH_WITHDRAWAL - swap.cbEthAmount, PARTIAL_OBSERVED_CBETH_REMAINDER, "outer checkpoint remainder"
        );

        AaveAccountData memory finalAaveState = _readAaveAccountData(delegatedEoa);
        assertGt(finalAaveState.healthFactor, healthFactorBefore, "partial deleverage improves health factor");
        assertGe(
            finalAaveState.healthFactor,
            MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR,
            "guarded partial-deleverage health factor"
        );
        _assertNoResidualLifecycleAllowances(delegatedEoa);
        _assertOnlyDelegatedEoaOwnsAavePosition();
        _assertNoCustomLifecycleEvents(logs);
    }

    function test_FlashAssistedFullClose_PatchesVisibleDebtAndReturnsUnusedCollateral() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _openCbEthCollateralWethDebtPosition(delegatedEoa);
        uint256 observedDebt = IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa);
        uint256 premium = _aaveFlashPremium(observedDebt);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedFullClose(
            delegatedEoa, flowAssertions, staticAssertions, observedDebt, premium, FULL_CLOSE_MAXIMUM_CBETH_INPUT
        );
        assertEq(
            _wordAt(calls[0].data, FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET),
            0,
            "flash principal is unresolved before account patching"
        );

        vm.recordLogs();
        _executeDynamicCallsAsDelegatedEoa(delegatedEoa, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        FlashLoanObservation memory flashLoan = _readSingleFlashLoan(logs, delegatedEoa);
        SwapObservation memory swap = _readSingleCbEthWethSwap(logs, delegatedEoa, false);
        assertEq(flashLoan.amount, observedDebt, "flash principal uses visible variable-debt balance");
        assertEq(flashLoan.premium, premium, "full-close premium");
        assertEq(swap.wethAmount, observedDebt + premium, "exact full-close repayment output");
        assertEq(swap.cbEthAmount, FULL_CLOSE_OBSERVED_CBETH_INPUT, "bounded full-close cbETH sold");
        assertLe(swap.cbEthAmount, FULL_CLOSE_MAXIMUM_CBETH_INPUT, "full-close maximum collateral input");
        assertEq(IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa), 0, "WETH debt is zero");
        assertEq(IERC20(BASE_AAVE_CBETH).balanceOf(delegatedEoa), 0, "Aave cbETH collateral is zero");
        assertApproxEqAbs(
            IERC20(BASE_CBETH).balanceOf(delegatedEoa),
            EXISTING_CBETH_INVENTORY + POSITION_INITIAL_CBETH_SUPPLY - swap.cbEthAmount,
            2,
            "unused cbETH returns to delegated EOA"
        );
        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), EXISTING_WETH_INVENTORY, "WETH sentinel survives");

        AaveAccountData memory finalAaveState = _readAaveAccountData(delegatedEoa);
        assertEq(finalAaveState.totalCollateralBase, 0, "full close leaves no Aave collateral");
        assertEq(finalAaveState.totalDebtBase, 0, "full close leaves no Aave debt");
        assertEq(finalAaveState.healthFactor, type(uint256).max, "no-position health factor");
        _assertNoResidualLifecycleAllowances(delegatedEoa);
        _assertOnlyDelegatedEoaOwnsAavePosition();
        _assertNoCustomLifecycleEvents(logs);
    }

    function test_FlashAssistedLeverageOpen_WhenMaximumPremiumIsTooLow_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _fundLeverageOpenInventory(delegatedEoa);
        uint256 actualPremium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            delegatedEoa,
            flowAssertions,
            actualPremium - 1,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            LEVERAGE_FLASH_WETH + actualPremium
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, LEVERAGE_FLASH_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            _selector(poolReason),
            IDefiSimplify7702Account.FlashLoanPremiumTooHigh.selector,
            "premium bound fails inside authenticated callback"
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashAssistedLeverageOpen_WhenSwapMinimumIsImpossible_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _fundLeverageOpenInventory(delegatedEoa);
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            delegatedEoa,
            flowAssertions,
            premium,
            1 ether,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            LEVERAGE_FLASH_WETH + premium
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, LEVERAGE_FLASH_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            _selector(poolReason),
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            "router failure retains callback attribution"
        );
        _assertCallbackFailureIndices(
            poolReason, LEVERAGE_FLASH_CALL_INDEX, LEVERAGE_SWAP_CALLBACK_CALL_INDEX, BASE_UNISWAP_V3_SWAP_ROUTER_02
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashAssistedLeverageOpen_WhenFinalHealthFactorIsExcessive_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _fundLeverageOpenInventory(delegatedEoa);
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            delegatedEoa,
            flowAssertions,
            premium,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            type(uint256).max,
            LEVERAGE_FLASH_WETH + premium
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory assertionReason =
            _assertDynamicCallFailure(revertData, LEVERAGE_HEALTH_ASSERTION_CALL_INDEX, address(flowAssertions));

        assertEq(
            _selector(assertionReason),
            IFlowAssertions.AaveV3HealthFactorTooLow.selector,
            "final health-factor assertion is the rollback boundary"
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashAssistedLeverageOpen_WhenRepaymentBalanceIsInsufficient_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _fundLeverageOpenInventory(delegatedEoa);
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedLeverageOpen(
            delegatedEoa,
            flowAssertions,
            premium,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            0.1 ether
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, LEVERAGE_FLASH_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            _selector(poolReason),
            IDefiSimplify7702Account.FlashLoanRepaymentBalanceInsufficient.selector,
            "repayment coverage checked after callback plan"
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashLoan_WhenCallbackEnvelopeIsMalformed_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple,
                (delegatedEoa, BASE_WETH, PARTIAL_FLASH_WETH, hex"1234", NO_REFERRAL_CODE)
            ),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.noPatches(),
            true
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, 0, AAVE_V3_POOL);

        assertEq(poolReason.length, 0, "Solidity ABI decoding rejects the malformed envelope");
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashLoan_WhenCallbackPlanRequestsNestedCallback_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        IDefiSimplify7702Account.DynamicCall[] memory nestedCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        nestedCalls[0] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_WETH, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0))
        );
        nestedCalls[0].expectsCallback = true;

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _flashLoanCall(
            delegatedEoa,
            PARTIAL_FLASH_WETH,
            _aaveFlashPremium(PARTIAL_FLASH_WETH),
            nestedCalls,
            DynamicCallTestBuilder.noPatches()
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, 0, AAVE_V3_POOL);

        assertEq(
            _selector(poolReason),
            IDefiSimplify7702Account.NestedCallbackNotSupported.selector,
            "nested callback rejected before nested target execution"
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function test_FlashAssistedPartialDeleverage_WhenMaximumCollateralInputIsTooLow_RollsBackPosition() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        _openCbEthCollateralWethDebtPosition(delegatedEoa);
        uint256 premium = _aaveFlashPremium(PARTIAL_FLASH_WETH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildFlashAssistedPartialDeleverage(
            delegatedEoa,
            flowAssertions,
            premium,
            PARTIAL_OBSERVED_CBETH_INPUT - 1,
            MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR
        );
        (bytes memory revertData, FlashLifecycleState memory beforeState) =
            _invokeExpectingRollback(delegatedEoa, calls);
        bytes memory poolReason = _assertDynamicCallFailure(revertData, PARTIAL_FLASH_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            _selector(poolReason),
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            "exact-output input cap fails inside callback"
        );
        _assertFlashLifecycleStateEquals(beforeState, delegatedEoa);
    }

    function _invokeExpectingRollback(address payable delegatedEoa, IDefiSimplify7702Account.DynamicCall[] memory calls)
        private
        returns (bytes memory revertData, FlashLifecycleState memory beforeState)
    {
        beforeState = _readFlashLifecycleState(delegatedEoa);
        (bool success, bytes memory returnedData) = _invokeDynamicCallsAsDelegatedEoa(delegatedEoa, calls);
        assertFalse(success, "forced-failure flash lifecycle unexpectedly succeeded");
        return (returnedData, beforeState);
    }

    function _assertCallbackFailureIndices(
        bytes memory encodedError,
        uint256 expectedOuterCallIndex,
        uint256 expectedCallbackCallIndex,
        address expectedTarget
    ) private pure {
        bytes memory errorArguments = _argumentsAfterSelector(encodedError);
        (uint256 outerCallIndex, uint256 callbackCallIndex, address target, bytes memory reason) =
            abi.decode(errorArguments, (uint256, uint256, address, bytes));
        assertEq(outerCallIndex, expectedOuterCallIndex, "outer callback-enabled call index");
        assertEq(callbackCallIndex, expectedCallbackCallIndex, "callback plan call index");
        assertEq(target, expectedTarget, "callback target");
        assertGt(reason.length, 0, "complete callback target failure");
    }

    function _assertOnlyDelegatedEoaOwnsAavePosition() private view {
        _assertNoAavePosition(address(accountUnderTest.implementation));
        _assertNoAavePosition(address(flowAssertions));
        _assertNoAavePosition(address(staticAssertions));
        _assertNoAavePosition(address(this));
    }

    function _assertNoCustomLifecycleEvents(Vm.Log[] memory logs) private view {
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, accountUnderTest.delegatedEoa, "delegated account custom event");
            assertNotEq(logs[i].emitter, address(flowAssertions), "FlowAssertions custom event");
            assertNotEq(logs[i].emitter, address(staticAssertions), "generic assertion custom event");
        }
    }

    function _argumentsAfterSelector(bytes memory encodedError) private pure returns (bytes memory arguments) {
        assertGe(encodedError.length, 4, "missing error selector");
        arguments = new bytes(encodedError.length - 4);
        for (uint256 i = 0; i < arguments.length; ++i) {
            arguments[i] = encodedError[i + 4];
        }
    }

    function _wordAt(bytes memory data, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }
}
