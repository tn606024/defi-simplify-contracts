// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseAaveV3StaticFlowFixture, IBaseAaveV3Pool} from "./BaseAaveV3StaticFlowFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

/// @dev Test-only direct swap surface for Base's official Uniswap V3 SwapRouter02.
interface IBaseUniswapV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/// @dev Test-only identity and event surface for the pinned Base USDC/WETH pool.
interface IBaseUniswapV3Pool {
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @dev Shared identities, plan construction, and rollback snapshots for DSC-57.
abstract contract BaseAaveV3DynamicStrategyFixture is BaseAaveV3StaticFlowFixture {
    using SafeCast for int256;

    address internal constant BASE_UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant BASE_UNISWAP_V3_SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    bytes32 internal constant BASE_UNISWAP_V3_SWAP_ROUTER_02_RUNTIME_CODE_HASH =
        0x38bd640f47df62b2fd5a6755a63f4976ad847dc9b946ae0d145d21d16bb124e4;
    address internal constant BASE_UNISWAP_V3_USDC_WETH_500_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    bytes32 internal constant BASE_UNISWAP_V3_USDC_WETH_500_POOL_RUNTIME_CODE_HASH =
        0xcd06f61c6db6a1d8317548aaaa0aa83254624aec741534c51815810e977587ae;

    uint24 internal constant USDC_WETH_POOL_FEE = 500;
    uint32 internal constant ERC20_APPROVE_AMOUNT_CALLDATA_OFFSET = 36;
    uint32 internal constant SWAP_ROUTER_AMOUNT_IN_CALLDATA_OFFSET = 132;
    uint32 internal constant AAVE_SUPPLY_AMOUNT_CALLDATA_OFFSET = 36;

    bytes32 internal constant BORROWED_USDC_CHECKPOINT_ID = keccak256("dsc-57.borrowed-usdc");
    bytes32 internal constant SWAPPED_WETH_CHECKPOINT_ID = keccak256("dsc-57.swapped-weth");

    uint256 internal constant INITIAL_WETH_SUPPLY_AMOUNT = 1 ether;
    uint256 internal constant EXISTING_WETH_INVENTORY = 0.25 ether;
    uint256 internal constant EXISTING_USDC_INVENTORY = 37e6;
    uint256 internal constant EXISTING_NATIVE_INVENTORY = 0.125 ether;
    uint256 internal constant GUARDED_USDC_BORROW_AMOUNT = 500e6;
    uint256 internal constant MINIMUM_WETH_SWAP_OUTPUT = 0.26 ether;
    /// @dev Exact Swap event output for 500 USDC at the pinned block, independently matched by the V3 Quoter.
    uint256 internal constant OBSERVED_WETH_SWAP_OUTPUT_AT_PINNED_BLOCK = 260_391_696_019_929_066;
    uint160 internal constant MAXIMUM_ACCEPTED_SQRT_PRICE_X96 = 3_600_000_000_000_000_000_000_000;
    uint256 internal constant MINIMUM_FINAL_HEALTH_FACTOR = 2 ether;

    uint256 internal constant INITIAL_APPROVE_CALL_INDEX = 0;
    uint256 internal constant INITIAL_SUPPLY_CALL_INDEX = 1;
    uint256 internal constant BORROW_CALL_INDEX = 2;
    uint256 internal constant ROUTER_APPROVE_CALL_INDEX = 3;
    uint256 internal constant SWAP_CALL_INDEX = 4;
    uint256 internal constant OUTPUT_APPROVE_CALL_INDEX = 5;
    uint256 internal constant OUTPUT_SUPPLY_CALL_INDEX = 6;
    uint256 internal constant HEALTH_FACTOR_ASSERTION_CALL_INDEX = 7;

    bytes32 internal constant UNISWAP_V3_SWAP_EVENT_SIGNATURE =
        keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");

    struct WethCollateralUsdcDebtLoopState {
        uint256 nativeBalance;
        uint256 wethBalance;
        uint256 usdcBalance;
        uint256 aWethBalance;
        uint256 variableDebtUsdcBalance;
        uint256 wethPoolAllowance;
        uint256 wethRouterAllowance;
        uint256 usdcPoolAllowance;
        uint256 usdcRouterAllowance;
        uint256 uniswapPoolWethBalance;
        uint256 uniswapPoolUsdcBalance;
        uint160 uniswapPoolSqrtPriceX96;
        int24 uniswapPoolTick;
        uint128 uniswapPoolLiquidity;
        AaveAccountData aave;
    }

    function _setUpPinnedBaseAaveAndUniswapFork() internal {
        _setUpPinnedBaseAaveFork();

        assertEq(
            BASE_UNISWAP_V3_SWAP_ROUTER_02.codehash,
            BASE_UNISWAP_V3_SWAP_ROUTER_02_RUNTIME_CODE_HASH,
            "Uniswap SwapRouter02 runtime identity"
        );
        assertEq(
            BASE_UNISWAP_V3_USDC_WETH_500_POOL.codehash,
            BASE_UNISWAP_V3_USDC_WETH_500_POOL_RUNTIME_CODE_HASH,
            "Uniswap USDC/WETH pool runtime identity"
        );
        assertEq(
            IBaseUniswapV3SwapRouter02(BASE_UNISWAP_V3_SWAP_ROUTER_02).factory(),
            BASE_UNISWAP_V3_FACTORY,
            "Uniswap SwapRouter02 factory"
        );
        assertEq(
            IBaseUniswapV3SwapRouter02(BASE_UNISWAP_V3_SWAP_ROUTER_02).WETH9(),
            BASE_WETH,
            "Uniswap SwapRouter02 wrapped native"
        );
        assertEq(IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).token0(), BASE_WETH, "Uniswap pool token0");
        assertEq(IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).token1(), BASE_USDC, "Uniswap pool token1");
        assertEq(IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).fee(), USDC_WETH_POOL_FEE, "Uniswap pool fee");
        assertGt(IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).liquidity(), 0, "Uniswap pool liquidity");
    }

    function _fundWethCollateralUsdcDebtLoopInventory(address payable delegatedEoa) internal {
        _wrapNativeAsDelegatedEoa(delegatedEoa, INITIAL_WETH_SUPPLY_AMOUNT + EXISTING_WETH_INVENTORY);
        deal(BASE_USDC, delegatedEoa, EXISTING_USDC_INVENTORY);
        vm.deal(delegatedEoa, EXISTING_NATIVE_INVENTORY);
    }

    /// @dev Builds the guarded WETH/USDC leverage loop exercised against Base.
    ///
    /// The delegated EOA starts with the configured WETH supply amount plus
    /// separate WETH, USDC, and native-ETH inventory sentinels. Calls execute
    /// in this order:
    /// 1. approve and supply only the configured initial WETH;
    /// 2. checkpoint USDC immediately before borrowing;
    /// 3. approve and swap exactly the observed borrowed-USDC delta;
    /// 4. checkpoint WETH immediately before the swap, then approve and supply
    ///    exactly the observed swap-output delta; and
    /// 5. require the final Aave V3 health factor to meet the configured bound.
    ///
    /// Both checkpoint deltas deliberately exclude pre-existing inventory. This
    /// direct SwapRouter02 function has no deadline field; amountOutMinimum and
    /// sqrtPriceLimitX96 are the protocol-native economic limits. Exact delta
    /// approvals constrain the router and Pool inputs, and the final assertion
    /// is the account-level post-condition. Every forced validation, swap, or
    /// assertion failure must roll back all earlier calls, balances, allowances,
    /// checkpoints, and protocol state in the batch.
    function _buildWethCollateralUsdcDebtLoopStrategy(
        address delegatedEoa,
        FlowAssertions flowAssertions,
        uint256 minimumSwapOutput,
        uint160 sqrtPriceLimitX96,
        uint256 minimumHealthFactor
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        calls = new IDefiSimplify7702Account.DynamicCall[](8);

        calls[INITIAL_APPROVE_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_WETH, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, INITIAL_WETH_SUPPLY_AMOUNT))
        );
        calls[INITIAL_SUPPLY_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.supply, (BASE_WETH, INITIAL_WETH_SUPPLY_AMOUNT, delegatedEoa, NO_REFERRAL_CODE)
            )
        );

        calls[BORROW_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.borrow,
                (BASE_USDC, GUARDED_USDC_BORROW_AMOUNT, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
            ),
            DynamicCallTestBuilder.singleCheckpoint(BASE_USDC, BORROWED_USDC_CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches()
        );
        calls[ROUTER_APPROVE_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            BASE_USDC,
            abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_USDC, BORROWED_USDC_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_CALLDATA_OFFSET
                )
            )
        );

        IBaseUniswapV3SwapRouter02.ExactInputSingleParams memory swapParams =
            IBaseUniswapV3SwapRouter02.ExactInputSingleParams({
                tokenIn: BASE_USDC,
                tokenOut: BASE_WETH,
                fee: USDC_WETH_POOL_FEE,
                recipient: delegatedEoa,
                amountIn: 0,
                amountOutMinimum: minimumSwapOutput,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });
        calls[SWAP_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            BASE_UNISWAP_V3_SWAP_ROUTER_02,
            abi.encodeCall(IBaseUniswapV3SwapRouter02.exactInputSingle, (swapParams)),
            DynamicCallTestBuilder.singleCheckpoint(BASE_WETH, SWAPPED_WETH_CHECKPOINT_ID),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_USDC, BORROWED_USDC_CHECKPOINT_ID, SWAP_ROUTER_AMOUNT_IN_CALLDATA_OFFSET
                )
            )
        );
        calls[OUTPUT_APPROVE_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            BASE_WETH,
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_WETH, SWAPPED_WETH_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_CALLDATA_OFFSET
                )
            )
        );
        calls[OUTPUT_SUPPLY_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            AAVE_V3_POOL,
            abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_WETH, 0, delegatedEoa, NO_REFERRAL_CODE)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_WETH, SWAPPED_WETH_CHECKPOINT_ID, AAVE_SUPPLY_AMOUNT_CALLDATA_OFFSET
                )
            )
        );
        calls[HEALTH_FACTOR_ASSERTION_CALL_INDEX] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (AAVE_V3_POOL, minimumHealthFactor))
        );
    }

    function _executeDynamicCallsAsDelegatedEoa(
        address payable delegatedEoa,
        IDefiSimplify7702Account.DynamicCall[] memory calls
    ) internal {
        vm.prank(delegatedEoa, delegatedEoa);
        _dynamicExecutionInterfaceView(delegatedEoa).executeBatchDynamic(calls);
    }

    function _invokeDynamicCallsAsDelegatedEoa(
        address payable delegatedEoa,
        IDefiSimplify7702Account.DynamicCall[] memory calls
    ) internal returns (bool success, bytes memory returnData) {
        vm.prank(delegatedEoa, delegatedEoa);
        return delegatedEoa.call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
    }

    function _readWethCollateralUsdcDebtLoopState(address delegatedEoa)
        internal
        view
        returns (WethCollateralUsdcDebtLoopState memory state)
    {
        state.nativeBalance = delegatedEoa.balance;
        state.wethBalance = IERC20(BASE_WETH).balanceOf(delegatedEoa);
        state.usdcBalance = IERC20(BASE_USDC).balanceOf(delegatedEoa);
        state.aWethBalance = IERC20(BASE_AAVE_WETH).balanceOf(delegatedEoa);
        state.variableDebtUsdcBalance = IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(delegatedEoa);
        state.wethPoolAllowance = IERC20(BASE_WETH).allowance(delegatedEoa, AAVE_V3_POOL);
        state.wethRouterAllowance = IERC20(BASE_WETH).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02);
        state.usdcPoolAllowance = IERC20(BASE_USDC).allowance(delegatedEoa, AAVE_V3_POOL);
        state.usdcRouterAllowance = IERC20(BASE_USDC).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02);
        state.uniswapPoolWethBalance = IERC20(BASE_WETH).balanceOf(BASE_UNISWAP_V3_USDC_WETH_500_POOL);
        state.uniswapPoolUsdcBalance = IERC20(BASE_USDC).balanceOf(BASE_UNISWAP_V3_USDC_WETH_500_POOL);
        (state.uniswapPoolSqrtPriceX96, state.uniswapPoolTick,,,,,) =
            IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).slot0();
        state.uniswapPoolLiquidity = IBaseUniswapV3Pool(BASE_UNISWAP_V3_USDC_WETH_500_POOL).liquidity();
        state.aave = _readAaveAccountData(delegatedEoa);
    }

    function _assertWethCollateralUsdcDebtLoopStateEquals(
        WethCollateralUsdcDebtLoopState memory expected,
        address delegatedEoa
    ) internal view {
        WethCollateralUsdcDebtLoopState memory actual = _readWethCollateralUsdcDebtLoopState(delegatedEoa);
        assertEq(actual.nativeBalance, expected.nativeBalance, "native balance rollback");
        assertEq(actual.wethBalance, expected.wethBalance, "WETH balance rollback");
        assertEq(actual.usdcBalance, expected.usdcBalance, "USDC balance rollback");
        assertEq(actual.aWethBalance, expected.aWethBalance, "aWETH balance rollback");
        assertEq(actual.variableDebtUsdcBalance, expected.variableDebtUsdcBalance, "variable-debt USDC rollback");
        assertEq(actual.wethPoolAllowance, expected.wethPoolAllowance, "WETH Pool allowance rollback");
        assertEq(actual.wethRouterAllowance, expected.wethRouterAllowance, "WETH Router allowance rollback");
        assertEq(actual.usdcPoolAllowance, expected.usdcPoolAllowance, "USDC Pool allowance rollback");
        assertEq(actual.usdcRouterAllowance, expected.usdcRouterAllowance, "USDC Router allowance rollback");
        assertEq(actual.uniswapPoolWethBalance, expected.uniswapPoolWethBalance, "Uniswap pool WETH balance rollback");
        assertEq(actual.uniswapPoolUsdcBalance, expected.uniswapPoolUsdcBalance, "Uniswap pool USDC balance rollback");
        assertEq(actual.uniswapPoolSqrtPriceX96, expected.uniswapPoolSqrtPriceX96, "Uniswap pool price rollback");
        assertEq(actual.uniswapPoolTick, expected.uniswapPoolTick, "Uniswap pool tick rollback");
        assertEq(actual.uniswapPoolLiquidity, expected.uniswapPoolLiquidity, "Uniswap pool liquidity rollback");
        assertEq(actual.aave.totalCollateralBase, expected.aave.totalCollateralBase, "Aave collateral rollback");
        assertEq(actual.aave.totalDebtBase, expected.aave.totalDebtBase, "Aave debt rollback");
        assertEq(actual.aave.availableBorrowsBase, expected.aave.availableBorrowsBase, "Aave capacity rollback");
        assertEq(
            actual.aave.currentLiquidationThreshold,
            expected.aave.currentLiquidationThreshold,
            "Aave liquidation threshold rollback"
        );
        assertEq(actual.aave.loanToValue, expected.aave.loanToValue, "Aave loan-to-value rollback");
        assertEq(actual.aave.healthFactor, expected.aave.healthFactor, "Aave health factor rollback");
    }

    function _readSwapAmounts(Vm.Log[] memory logs, address delegatedEoa)
        internal
        pure
        returns (uint256 usdcInput, uint256 wethOutput)
    {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter != BASE_UNISWAP_V3_USDC_WETH_500_POOL
                    || logs[i].topics[0] != UNISWAP_V3_SWAP_EVENT_SIGNATURE
            ) {
                continue;
            }

            ++matchingEvents;
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "Uniswap swap recipient");
            (int256 amount0, int256 amount1,,,) = abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24));
            assertLt(amount0, 0, "WETH is swap output");
            assertGt(amount1, 0, "USDC is swap input");
            wethOutput = (-amount0).toUint256();
            usdcInput = amount1.toUint256();
        }
        assertEq(matchingEvents, 1, "expected one Uniswap Swap event");
    }

    function _assertNoCustomAccountOrAssertionEvents(
        Vm.Log[] memory logs,
        address delegatedEoa,
        FlowAssertions flowAssertions
    ) internal pure {
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, delegatedEoa, "delegated account emitted a custom event");
            assertNotEq(logs[i].emitter, address(flowAssertions), "FlowAssertions emitted a custom event");
        }
    }

    function _assertDynamicCallFailure(bytes memory revertData, uint256 expectedCallIndex, address expectedTarget)
        internal
        pure
        returns (bytes memory targetReason)
    {
        assertGe(revertData.length, 4, "missing DynamicCallFailed selector");
        bytes4 actualSelector;
        assembly ("memory-safe") {
            actualSelector := mload(add(revertData, 32))
        }
        assertEq(
            actualSelector, IDefiSimplify7702Account.DynamicCallFailed.selector, "unexpected dynamic failure selector"
        );

        bytes memory errorArguments = new bytes(revertData.length - 4);
        for (uint256 i = 0; i < errorArguments.length; ++i) {
            errorArguments[i] = revertData[i + 4];
        }
        (uint256 actualCallIndex, address actualTarget, bytes memory nestedReason) =
            abi.decode(errorArguments, (uint256, address, bytes));
        assertEq(actualCallIndex, expectedCallIndex, "unexpected failed dynamic call index");
        assertEq(actualTarget, expectedTarget, "unexpected failed dynamic target");
        return nestedReason;
    }

    function _addressTopic(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
