// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    BaseAaveV3DynamicStrategyFixture,
    IBaseAaveV3Pool,
    IBaseUniswapV3SwapRouter02
} from "./BaseAaveV3DynamicStrategyFixture.sol";

/// @title Base Aave V3 Guarded Dynamic Strategy Fork Tests
/// @notice Exercises a callback-free WETH-collateral/USDC-debt loop against Aave V3 and Uniswap V3
///         at pinned Base block 48,961,870, including observed-delta patching, economic guards,
///         inventory preservation, failure attribution, and atomic rollback.
contract BaseAaveV3DynamicStrategyForkTest is BaseAaveV3DynamicStrategyFixture {
    uint256 private constant BASE_DYNAMIC_STRATEGY_AUTHORITY_KEY = 0xD5C5701;
    bytes4 private constant AAVE_INVALID_AMOUNT_SELECTOR = 0x2c5211c6;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    FlowAssertions private flowAssertions;

    function setUp() external {
        _setUpPinnedBaseAaveAndUniswapFork();
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(_baseEntryPoint(), BASE_DYNAMIC_STRATEGY_AUTHORITY_KEY);
        flowAssertions = new FlowAssertions();
        _assertNoAavePosition(accountUnderTest.delegatedEoa);
        _fundWethCollateralUsdcDebtLoopInventory(accountUnderTest.delegatedEoa);
    }

    /// @dev Given a delegated EOA with no Aave position, the WETH to supply, and isolated WETH,
    ///      USDC, and native inventory sentinels. When the eight-call plan supplies WETH, borrows
    ///      USDC, patches that observed USDC delta into the Router approval and swap, then patches
    ///      the observed WETH output into the second Aave approval and supply. Then only those
    ///      checkpoint deltas move under the Router output/price bounds and final health-factor
    ///      guard; inventory, exact allowances, and unrelated account holders remain untouched.
    function test_WethCollateralUsdcDebtLoop_UsesObservedDeltasAndKeepsExistingInventory() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        uint256 startingWethBalance = IERC20(BASE_WETH).balanceOf(delegatedEoa);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildPinnedWethCollateralUsdcDebtLoopStrategy();

        IBaseUniswapV3SwapRouter02.ExactInputSingleParams memory expectedSwap =
            IBaseUniswapV3SwapRouter02.ExactInputSingleParams({
                tokenIn: BASE_USDC,
                tokenOut: BASE_WETH,
                fee: USDC_WETH_POOL_FEE,
                recipient: delegatedEoa,
                amountIn: GUARDED_USDC_BORROW_AMOUNT,
                amountOutMinimum: MINIMUM_WETH_SWAP_OUTPUT,
                sqrtPriceLimitX96: MAXIMUM_ACCEPTED_SQRT_PRICE_X96
            });
        vm.expectCall(
            BASE_UNISWAP_V3_SWAP_ROUTER_02, abi.encodeCall(IBaseUniswapV3SwapRouter02.exactInputSingle, (expectedSwap))
        );
        vm.expectCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.supply,
                (BASE_WETH, OBSERVED_WETH_SWAP_OUTPUT_AT_PINNED_BLOCK, delegatedEoa, NO_REFERRAL_CODE)
            )
        );

        vm.recordLogs();
        _executeDynamicCallsAsDelegatedEoa(delegatedEoa, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 actualUsdcInput, uint256 actualWethOutput) = _readSwapAmounts(logs, delegatedEoa);
        assertEq(actualUsdcInput, GUARDED_USDC_BORROW_AMOUNT, "swap consumes only borrowed USDC delta");
        assertEq(actualWethOutput, OBSERVED_WETH_SWAP_OUTPUT_AT_PINNED_BLOCK, "swap output at pinned Base block");
        assertEq(
            IERC20(BASE_USDC).balanceOf(delegatedEoa), EXISTING_USDC_INVENTORY, "pre-existing USDC remains untouched"
        );
        assertEq(
            IERC20(BASE_WETH).balanceOf(delegatedEoa), EXISTING_WETH_INVENTORY, "pre-existing WETH remains untouched"
        );
        assertLt(
            IERC20(BASE_WETH).balanceOf(delegatedEoa),
            startingWethBalance,
            "flow-start WETH delta is negative despite positive swap output"
        );
        assertApproxEqAbs(
            IERC20(BASE_AAVE_WETH).balanceOf(delegatedEoa),
            INITIAL_WETH_SUPPLY_AMOUNT + actualWethOutput,
            2,
            "Aave collateral equals initial supply plus observed swap output"
        );
        assertApproxEqAbs(
            IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(delegatedEoa),
            GUARDED_USDC_BORROW_AMOUNT,
            1,
            "Aave variable debt belongs to delegated EOA"
        );
        assertEq(delegatedEoa.balance, EXISTING_NATIVE_INVENTORY, "native inventory remains untouched");
        assertEq(
            IERC20(BASE_USDC).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02),
            0,
            "exact Router allowance is fully consumed"
        );
        assertEq(
            IERC20(BASE_WETH).allowance(delegatedEoa, AAVE_V3_POOL), 0, "exact Aave supply allowance is fully consumed"
        );

        AaveAccountData memory finalAaveState = _readAaveAccountData(delegatedEoa);
        assertGt(finalAaveState.totalCollateralBase, 0, "Aave records delegated EOA collateral");
        assertGt(finalAaveState.totalDebtBase, 0, "Aave records delegated EOA debt");
        assertGe(finalAaveState.healthFactor, MINIMUM_FINAL_HEALTH_FACTOR, "final on-chain health-factor guard");
        _assertNoAavePosition(address(accountUnderTest.implementation));
        _assertNoAavePosition(address(flowAssertions));
        _assertNoAavePosition(address(this));
        _assertNoCustomAccountOrAssertionEvents(logs, delegatedEoa, flowAssertions);
    }

    /// @dev Raises the Router-native minimum output so call 4 must preserve the complete Uniswap
    ///      failure while rolling back the earlier Aave supply, borrow, approvals, and pool state.
    function test_WethCollateralUsdcDebtLoop_WhenSwapMinimumIsUnreachable_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildWethCollateralUsdcDebtLoopStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            1 ether,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            MINIMUM_FINAL_HEALTH_FACTOR
        );
        (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState) =
            _invokeWethCollateralUsdcDebtLoopExpectingRollback(calls);
        bytes memory routerReason =
            _assertDynamicCallFailure(revertData, SWAP_CALL_INDEX, BASE_UNISWAP_V3_SWAP_ROUTER_02);

        assertEq(
            routerReason,
            abi.encodeWithSignature("Error(string)", "Too little received"),
            "complete Uniswap slippage failure"
        );
        _assertWethCollateralUsdcDebtLoopStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    /// @dev Lets every protocol call succeed, then makes the final typed assertion impossible so
    ///      the post-condition at call 7 remains the rollback boundary for the complete strategy.
    function test_WethCollateralUsdcDebtLoop_WhenFinalHealthFactorMinimumIsExcessive_RollsBackEveryStateChange()
        external
    {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildWethCollateralUsdcDebtLoopStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            MINIMUM_WETH_SWAP_OUTPUT,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            type(uint256).max
        );
        (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState) =
            _invokeWethCollateralUsdcDebtLoopExpectingRollback(calls);
        bytes memory assertionReason =
            _assertDynamicCallFailure(revertData, HEALTH_FACTOR_ASSERTION_CALL_INDEX, address(flowAssertions));

        assertEq(
            _selector(assertionReason),
            IFlowAssertions.AaveV3HealthFactorTooLow.selector,
            "final failure is the typed Aave health-factor assertion"
        );
        _assertWethCollateralUsdcDebtLoopStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    /// @dev Shifts the Router approval patch by one byte so account-side alignment validation must
    ///      reject the indexed patch before executing the affected target.
    function test_WethCollateralUsdcDebtLoop_WhenRouterApprovalOffsetIsUnaligned_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildPinnedWethCollateralUsdcDebtLoopStrategy();
        uint32 invalidOffset = ERC20_APPROVE_AMOUNT_CALLDATA_OFFSET + 1;
        calls[ROUTER_APPROVE_CALL_INDEX].patches[0].offset = invalidOffset;
        uint256 approvalCalldataLength = calls[ROUTER_APPROVE_CALL_INDEX].data.length;
        (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState) =
            _invokeWethCollateralUsdcDebtLoopExpectingRollback(calls);

        assertEq(
            revertData,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.InvalidPatchOffset.selector,
                ROUTER_APPROVE_CALL_INDEX,
                0,
                invalidOffset,
                approvalCalldataLength
            ),
            "indexed malformed Router approval offset"
        );
        _assertWethCollateralUsdcDebtLoopStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    /// @dev Relabels the borrowed-USDC patch as WETH so checkpoint-token binding must fail with the
    ///      consuming call and patch indices, rather than spending either inventory sentinel.
    function test_WethCollateralUsdcDebtLoop_WhenPatchTokenDiffersFromCheckpoint_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildPinnedWethCollateralUsdcDebtLoopStrategy();
        calls[ROUTER_APPROVE_CALL_INDEX].patches[0].token = BASE_WETH;
        (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState) =
            _invokeWethCollateralUsdcDebtLoopExpectingRollback(calls);

        assertEq(
            revertData,
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointTokenMismatch.selector,
                ROUTER_APPROVE_CALL_INDEX,
                0,
                BORROWED_USDC_CHECKPOINT_ID,
                BASE_WETH,
                BASE_USDC
            ),
            "indexed token/checkpoint mismatch"
        );
        _assertWethCollateralUsdcDebtLoopStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    /// @dev Keeps the observed-output patch mechanically valid but changes the downstream Aave
    ///      operation, proving the complete target revert is attributed to call 6 and rolls back.
    function test_WethCollateralUsdcDebtLoop_WhenPatchedDownstreamAaveAmountIsInvalid_RollsBackEveryStateChange()
        external
    {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildPinnedWethCollateralUsdcDebtLoopStrategy();
        calls[OUTPUT_SUPPLY_CALL_INDEX].data = abi.encodeCall(
            IBaseAaveV3Pool.borrow, (BASE_USDC, 0, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
        );
        (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState) =
            _invokeWethCollateralUsdcDebtLoopExpectingRollback(calls);
        bytes memory aaveReason = _assertDynamicCallFailure(revertData, OUTPUT_SUPPLY_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            aaveReason,
            abi.encodePacked(AAVE_INVALID_AMOUNT_SELECTOR),
            "complete downstream Aave invalid-amount failure"
        );
        _assertWethCollateralUsdcDebtLoopStateEquals(beforeState, delegatedEoa);
    }

    function _buildPinnedWethCollateralUsdcDebtLoopStrategy()
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        return _buildWethCollateralUsdcDebtLoopStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            MINIMUM_WETH_SWAP_OUTPUT,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            MINIMUM_FINAL_HEALTH_FACTOR
        );
    }

    /// @dev Every failure case compares delegated-account balances and allowances, the Aave
    ///      position, and Uniswap pool balances, price, tick, and liquidity with its pre-call state.
    function _invokeWethCollateralUsdcDebtLoopExpectingRollback(IDefiSimplify7702Account.DynamicCall[] memory calls)
        private
        returns (bytes memory revertData, WethCollateralUsdcDebtLoopState memory beforeState)
    {
        beforeState = _readWethCollateralUsdcDebtLoopState(accountUnderTest.delegatedEoa);
        (bool success, bytes memory returnedData) =
            _invokeDynamicCallsAsDelegatedEoa(accountUnderTest.delegatedEoa, calls);
        assertFalse(success, "forced-failure strategy unexpectedly succeeded");
        return (returnedData, beforeState);
    }

    function _selector(bytes memory encodedError) private pure returns (bytes4 selector) {
        assertGe(encodedError.length, 4, "missing nested error selector");
        assembly ("memory-safe") {
            selector := mload(add(encodedError, 32))
        }
    }
}
