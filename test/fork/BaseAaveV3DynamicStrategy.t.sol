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
        _fundGuardedStrategyInventory(accountUnderTest.delegatedEoa);
    }

    function test_GuardedDynamicStrategy_UsesObservedDeltasAndKeepsExistingInventory() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        uint256 startingWethBalance = IERC20(BASE_WETH).balanceOf(delegatedEoa);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _standardGuardedStrategy();

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
                (BASE_WETH, EXPECTED_WETH_SWAP_OUTPUT_AT_PINNED_BLOCK, delegatedEoa, NO_REFERRAL_CODE)
            )
        );

        vm.recordLogs();
        _executeDynamicStrategy(delegatedEoa, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 actualUsdcInput, uint256 actualWethOutput) = _readSwapAmounts(logs, delegatedEoa);
        assertEq(actualUsdcInput, GUARDED_USDC_BORROW_AMOUNT, "swap consumes only borrowed USDC delta");
        assertEq(actualWethOutput, EXPECTED_WETH_SWAP_OUTPUT_AT_PINNED_BLOCK, "swap output at pinned Base block");
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

    function test_GuardedDynamicStrategy_WhenSwapMinimumIsUnreachable_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildGuardedAaveDynamicStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            1 ether,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            MINIMUM_FINAL_HEALTH_FACTOR
        );
        (bytes memory revertData, StrategyState memory beforeState) = _invokeExpectingRollback(calls);
        bytes memory routerReason =
            _assertDynamicCallFailure(revertData, SWAP_CALL_INDEX, BASE_UNISWAP_V3_SWAP_ROUTER_02);

        assertEq(
            routerReason,
            abi.encodeWithSignature("Error(string)", "Too little received"),
            "complete Uniswap slippage failure"
        );
        _assertStrategyStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    function test_GuardedDynamicStrategy_WhenFinalHealthFactorMinimumIsExcessive_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildGuardedAaveDynamicStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            MINIMUM_WETH_SWAP_OUTPUT,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            type(uint256).max
        );
        (bytes memory revertData, StrategyState memory beforeState) = _invokeExpectingRollback(calls);
        bytes memory assertionReason =
            _assertDynamicCallFailure(revertData, HEALTH_FACTOR_ASSERTION_CALL_INDEX, address(flowAssertions));

        assertEq(
            _selector(assertionReason),
            IFlowAssertions.AaveV3HealthFactorTooLow.selector,
            "final failure is the typed Aave health-factor assertion"
        );
        _assertStrategyStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    function test_GuardedDynamicStrategy_WhenRouterApprovalOffsetIsUnaligned_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _standardGuardedStrategy();
        uint32 invalidOffset = ERC20_APPROVE_AMOUNT_CALLDATA_OFFSET + 1;
        calls[ROUTER_APPROVE_CALL_INDEX].patches[0].offset = invalidOffset;
        uint256 approvalCalldataLength = calls[ROUTER_APPROVE_CALL_INDEX].data.length;
        (bytes memory revertData, StrategyState memory beforeState) = _invokeExpectingRollback(calls);

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
        _assertStrategyStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    function test_GuardedDynamicStrategy_WhenPatchTokenDiffersFromCheckpoint_RollsBackEveryStateChange() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = _standardGuardedStrategy();
        calls[ROUTER_APPROVE_CALL_INDEX].patches[0].token = BASE_WETH;
        (bytes memory revertData, StrategyState memory beforeState) = _invokeExpectingRollback(calls);

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
        _assertStrategyStateEquals(beforeState, accountUnderTest.delegatedEoa);
    }

    function test_GuardedDynamicStrategy_WhenPatchedDownstreamAaveAmountIsInvalid_RollsBackEveryStateChange() external {
        address payable delegatedEoa = accountUnderTest.delegatedEoa;
        IDefiSimplify7702Account.DynamicCall[] memory calls = _standardGuardedStrategy();
        calls[OUTPUT_SUPPLY_CALL_INDEX].data = abi.encodeCall(
            IBaseAaveV3Pool.borrow, (BASE_USDC, 0, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
        );
        (bytes memory revertData, StrategyState memory beforeState) = _invokeExpectingRollback(calls);
        bytes memory aaveReason = _assertDynamicCallFailure(revertData, OUTPUT_SUPPLY_CALL_INDEX, AAVE_V3_POOL);

        assertEq(
            aaveReason,
            abi.encodePacked(AAVE_INVALID_AMOUNT_SELECTOR),
            "complete downstream Aave invalid-amount failure"
        );
        _assertStrategyStateEquals(beforeState, delegatedEoa);
    }

    function _standardGuardedStrategy() private view returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        return _buildGuardedAaveDynamicStrategy(
            accountUnderTest.delegatedEoa,
            flowAssertions,
            MINIMUM_WETH_SWAP_OUTPUT,
            MAXIMUM_ACCEPTED_SQRT_PRICE_X96,
            MINIMUM_FINAL_HEALTH_FACTOR
        );
    }

    function _invokeExpectingRollback(IDefiSimplify7702Account.DynamicCall[] memory calls)
        private
        returns (bytes memory revertData, StrategyState memory beforeState)
    {
        beforeState = _readStrategyState(accountUnderTest.delegatedEoa);
        (bool success, bytes memory returnedData) = _invokeDynamicStrategy(accountUnderTest.delegatedEoa, calls);
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
