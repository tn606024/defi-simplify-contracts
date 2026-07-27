// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";
import {IBaseUniswapV3Pool, IBaseUniswapV3SwapRouter02} from "./BaseAaveV3DynamicStrategyFixture.sol";
import {BaseAaveV3StaticFlowFixture, IBaseAaveV3Pool, IBaseAaveReserveToken} from "./BaseAaveV3StaticFlowFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

/// @dev Test-only Aave V3 Pool surface needed by the flash-assisted lifecycle proof.
interface IBaseAaveV3FlashLifecyclePool is IBaseAaveV3Pool, IAaveV3FlashLoanSimplePool {
    event FlashLoan(
        address indexed target,
        address initiator,
        address indexed asset,
        uint256 amount,
        uint8 interestRateMode,
        uint256 premium,
        uint16 indexed referralCode
    );

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
    function setUserEMode(uint8 categoryId) external;
    function getUserEMode(address user) external view returns (uint256);
}

/// @dev Test-only direct exact-output surface on Base's official SwapRouter02.
interface IBaseUniswapV3FlashLifecycleRouter is IBaseUniswapV3SwapRouter02 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @dev Test-only Uniswap V3 factory identity surface.
interface IBaseUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Shared pinned identities, reviewer-readable plans, and rollback snapshots for DSC-82.
abstract contract BaseAaveV3FlashLifecycleFixture is BaseAaveV3StaticFlowFixture {
    using SafeCast for int256;

    address internal constant BASE_UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant BASE_UNISWAP_V3_SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    bytes32 internal constant BASE_UNISWAP_V3_SWAP_ROUTER_02_RUNTIME_CODE_HASH =
        0x38bd640f47df62b2fd5a6755a63f4976ad847dc9b946ae0d145d21d16bb124e4;

    address internal constant BASE_CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    bytes32 internal constant BASE_CBETH_RUNTIME_CODE_HASH =
        0x8cd2f08c7ee9e6ab6e0180e8d6cb0613bbd54d2c4ae2ecdcaddfcdd9a226215b;
    address internal constant BASE_AAVE_CBETH = 0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad;
    address internal constant BASE_AAVE_VARIABLE_DEBT_WETH = 0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E;

    address internal constant BASE_UNISWAP_V3_CBETH_WETH_500_POOL = 0x10648BA41B8565907Cfa1496765fA4D95390aa0d;
    bytes32 internal constant BASE_UNISWAP_V3_CBETH_WETH_500_POOL_RUNTIME_CODE_HASH =
        0x124abb73a13a6eca26ef58e647330cc3450586435de21b6077de9af21b61cfd1;

    uint24 internal constant CBETH_WETH_POOL_FEE = 500;
    uint128 internal constant AAVE_FLASH_LOAN_PREMIUM_BPS = 5;
    uint8 internal constant ETH_CORRELATED_EMODE_CATEGORY = 1;
    uint8 internal constant NO_FLASH_DEBT_MODE = 0;

    uint32 internal constant ERC20_APPROVE_AMOUNT_OFFSET = 36;
    uint32 internal constant AAVE_AMOUNT_ARGUMENT_OFFSET = 36;
    uint32 internal constant FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET = 68;
    uint32 internal constant EXACT_INPUT_AMOUNT_ARGUMENT_OFFSET = 132;
    uint32 internal constant BALANCE_OF_ACCOUNT_ARGUMENT_OFFSET = 4;
    uint32 internal constant FIRST_RETURN_WORD_OFFSET = 0;

    bytes32 internal constant LEVERAGE_SWAP_OUTPUT_CHECKPOINT_ID = keccak256("dsc-82.leverage.swap-output-cbeth");
    bytes32 internal constant PARTIAL_CALLBACK_WITHDRAWAL_CHECKPOINT_ID =
        keccak256("dsc-82.partial.callback-withdrawn-cbeth");
    bytes32 internal constant PARTIAL_OUTER_REMAINDER_CHECKPOINT_ID = keccak256("dsc-82.partial.outer-remainder-cbeth");
    bytes32 internal constant FULL_CLOSE_WITHDRAWAL_CHECKPOINT_ID = keccak256("dsc-82.full-close.withdrawn-cbeth");

    uint256 internal constant EXISTING_CBETH_INVENTORY = 0.01 ether;
    uint256 internal constant EXISTING_WETH_INVENTORY = 0.02 ether;

    uint256 internal constant LEVERAGE_INITIAL_CBETH_SUPPLY = 0.3 ether;
    uint256 internal constant LEVERAGE_FLASH_WETH = 0.2 ether;
    uint256 internal constant LEVERAGE_MINIMUM_CBETH_OUTPUT = 0.175 ether;
    /// @dev Exact Swap event output for 0.2 WETH at the pinned block, also matched by QuoterV2.
    uint256 internal constant LEVERAGE_OBSERVED_CBETH_OUTPUT = 176_117_556_140_503_803;

    uint256 internal constant POSITION_INITIAL_CBETH_SUPPLY = 0.5 ether;
    uint256 internal constant POSITION_INITIAL_WETH_DEBT = 0.2 ether;
    uint256 internal constant PARTIAL_FLASH_WETH = 0.05 ether;
    uint256 internal constant PARTIAL_CBETH_WITHDRAWAL = 0.05 ether;
    uint256 internal constant PARTIAL_MAXIMUM_CBETH_INPUT = 0.045 ether;
    /// @dev Exact cbETH input for 0.050025 WETH at the pinned block, also matched by QuoterV2.
    uint256 internal constant PARTIAL_OBSERVED_CBETH_INPUT = 44_096_587_638_647_255;
    uint256 internal constant PARTIAL_OBSERVED_CBETH_REMAINDER = PARTIAL_CBETH_WITHDRAWAL
        - PARTIAL_OBSERVED_CBETH_INPUT;

    uint256 internal constant FULL_CLOSE_MAXIMUM_CBETH_INPUT = 0.18 ether;
    /// @dev Exact cbETH input for the observed 0.200100000000000002 WETH repayment at the pinned block.
    uint256 internal constant FULL_CLOSE_OBSERVED_CBETH_INPUT = 176_388_991_438_775_042;

    uint160 internal constant MAXIMUM_CBETH_PER_WETH_SQRT_PRICE_X96 = 84_500_000_000_000_000_000_000_000_000;
    uint160 internal constant MINIMUM_CBETH_PER_WETH_SQRT_PRICE_X96 = 84_000_000_000_000_000_000_000_000_000;
    uint256 internal constant MINIMUM_LEVERAGED_HEALTH_FACTOR = 2 ether;
    uint256 internal constant MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR = 2 ether;

    address internal constant POSITION_DEBT_PROCEEDS_SINK = address(0xD5C82);
    address internal constant STATIC_ASSERTION_ACCOUNT_PLACEHOLDER = 0x1111111111111111111111111111111111111111;

    bytes32 internal constant AAVE_FLASH_LOAN_EVENT_SIGNATURE =
        keccak256("FlashLoan(address,address,address,uint256,uint8,uint256,uint16)");
    bytes32 internal constant UNISWAP_V3_CBETH_WETH_SWAP_EVENT_SIGNATURE =
        keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");

    struct FlashLifecycleState {
        uint256 nativeBalance;
        uint256 wethBalance;
        uint256 cbEthBalance;
        uint256 aCbEthBalance;
        uint256 variableDebtWethBalance;
        uint256 wethPoolAllowance;
        uint256 wethRouterAllowance;
        uint256 cbEthPoolAllowance;
        uint256 cbEthRouterAllowance;
        uint256 aaveWethReserveLiquidity;
        uint256 aaveCbEthReserveLiquidity;
        uint256 uniswapPoolWethBalance;
        uint256 uniswapPoolCbEthBalance;
        uint160 uniswapPoolSqrtPriceX96;
        int24 uniswapPoolTick;
        uint128 uniswapPoolLiquidity;
        AaveAccountData aave;
    }

    struct FlashLoanObservation {
        uint256 amount;
        uint256 premium;
    }

    struct SwapObservation {
        uint256 cbEthAmount;
        uint256 wethAmount;
    }

    function _setUpPinnedBaseAaveFlashLifecycleFork() internal {
        _setUpPinnedBaseAaveFork();

        assertEq(
            BASE_UNISWAP_V3_SWAP_ROUTER_02.codehash,
            BASE_UNISWAP_V3_SWAP_ROUTER_02_RUNTIME_CODE_HASH,
            "Uniswap SwapRouter02 runtime identity"
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
        assertEq(BASE_CBETH.codehash, BASE_CBETH_RUNTIME_CODE_HASH, "Base cbETH runtime identity");
        assertEq(
            BASE_AAVE_CBETH.codehash,
            BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH,
            "Base Aave cbETH reserve-token runtime identity"
        );
        assertEq(
            BASE_AAVE_VARIABLE_DEBT_WETH.codehash,
            BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH,
            "Base Aave WETH debt-token runtime identity"
        );
        assertEq(
            BASE_UNISWAP_V3_CBETH_WETH_500_POOL.codehash,
            BASE_UNISWAP_V3_CBETH_WETH_500_POOL_RUNTIME_CODE_HASH,
            "Uniswap cbETH/WETH pool runtime identity"
        );
        assertEq(
            IBaseAaveReserveToken(BASE_AAVE_CBETH).UNDERLYING_ASSET_ADDRESS(), BASE_CBETH, "aBasecbETH underlying asset"
        );
        assertEq(
            IBaseAaveReserveToken(BASE_AAVE_VARIABLE_DEBT_WETH).UNDERLYING_ASSET_ADDRESS(),
            BASE_WETH,
            "variable-debt WETH underlying asset"
        );
        assertEq(
            IBaseUniswapV3Factory(BASE_UNISWAP_V3_FACTORY).getPool(BASE_CBETH, BASE_WETH, CBETH_WETH_POOL_FEE),
            BASE_UNISWAP_V3_CBETH_WETH_500_POOL,
            "Uniswap factory cbETH/WETH pool"
        );
        assertEq(
            IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).token0(), BASE_CBETH, "Uniswap cbETH/WETH token0"
        );
        assertEq(
            IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).token1(), BASE_WETH, "Uniswap cbETH/WETH token1"
        );
        assertEq(
            IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).fee(), CBETH_WETH_POOL_FEE, "Uniswap cbETH/WETH fee"
        );
        assertGt(IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).liquidity(), 0, "Uniswap cbETH/WETH liquidity");
        assertEq(
            IBaseAaveV3FlashLifecyclePool(AAVE_V3_POOL).FLASHLOAN_PREMIUM_TOTAL(),
            AAVE_FLASH_LOAN_PREMIUM_BPS,
            "Aave simple flash-loan premium"
        );
    }

    function _fundLeverageOpenInventory(address delegatedEoa) internal {
        deal(BASE_CBETH, delegatedEoa, LEVERAGE_INITIAL_CBETH_SUPPLY + EXISTING_CBETH_INVENTORY);
        deal(BASE_WETH, delegatedEoa, EXISTING_WETH_INVENTORY);
    }

    function _openCbEthCollateralWethDebtPosition(address payable delegatedEoa) internal {
        deal(BASE_CBETH, delegatedEoa, POSITION_INITIAL_CBETH_SUPPLY + EXISTING_CBETH_INVENTORY);
        deal(BASE_WETH, delegatedEoa, EXISTING_WETH_INVENTORY);

        BaseAccount.Call[] memory setupCalls = new BaseAccount.Call[](4);
        setupCalls[0] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3FlashLifecyclePool.setUserEMode, (ETH_CORRELATED_EMODE_CATEGORY))
        });
        setupCalls[1] = BaseAccount.Call({
            target: BASE_CBETH,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, POSITION_INITIAL_CBETH_SUPPLY))
        });
        setupCalls[2] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.supply, (BASE_CBETH, POSITION_INITIAL_CBETH_SUPPLY, delegatedEoa, NO_REFERRAL_CODE)
            )
        });
        setupCalls[3] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.borrow,
                (BASE_WETH, POSITION_INITIAL_WETH_DEBT, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
            )
        });
        _executeBatchAsDelegatedEoa(delegatedEoa, setupCalls);

        _executeAsDelegatedEoa(
            delegatedEoa,
            BASE_WETH,
            0,
            abi.encodeCall(IERC20.transfer, (POSITION_DEBT_PROCEEDS_SINK, POSITION_INITIAL_WETH_DEBT))
        );

        assertEq(IERC20(BASE_WETH).balanceOf(delegatedEoa), EXISTING_WETH_INVENTORY, "WETH sentinel after setup");
        assertEq(IERC20(BASE_CBETH).balanceOf(delegatedEoa), EXISTING_CBETH_INVENTORY, "cbETH sentinel after setup");
        assertEq(
            IBaseAaveV3FlashLifecyclePool(AAVE_V3_POOL).getUserEMode(delegatedEoa),
            ETH_CORRELATED_EMODE_CATEGORY,
            "ETH-correlated E-Mode"
        );
    }

    function _buildFlashAssistedLeverageOpen(
        address delegatedEoa,
        FlowAssertions flowAssertions,
        uint256 maximumPremium,
        uint256 minimumCbEthOutput,
        uint256 minimumHealthFactor,
        uint256 repaymentBorrowAmount
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            _buildLeverageOpenCallbackCalls(delegatedEoa, minimumCbEthOutput, repaymentBorrowAmount);

        calls = new IDefiSimplify7702Account.DynamicCall[](7);
        calls[0] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL, abi.encodeCall(IBaseAaveV3FlashLifecyclePool.setUserEMode, (ETH_CORRELATED_EMODE_CATEGORY))
        );
        calls[1] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_CBETH, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, LEVERAGE_INITIAL_CBETH_SUPPLY))
        );
        calls[2] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.supply, (BASE_CBETH, LEVERAGE_INITIAL_CBETH_SUPPLY, delegatedEoa, NO_REFERRAL_CODE)
            )
        );
        calls[3] = _flashLoanCall(
            delegatedEoa, LEVERAGE_FLASH_WETH, maximumPremium, callbackCalls, DynamicCallTestBuilder.noPatches()
        );
        calls[4] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (AAVE_V3_POOL, minimumHealthFactor))
        );
        calls[5] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertBalanceAtLeast, (BASE_WETH, EXISTING_WETH_INVENTORY))
        );
        calls[6] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertBalanceAtLeast, (BASE_CBETH, EXISTING_CBETH_INVENTORY))
        );
    }

    function _buildLeverageOpenCallbackCalls(
        address delegatedEoa,
        uint256 minimumCbEthOutput,
        uint256 repaymentBorrowAmount
    ) private pure returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls) {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](5);
        callbackCalls[0] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_WETH, abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, LEVERAGE_FLASH_WETH))
        );

        IBaseUniswapV3SwapRouter02.ExactInputSingleParams memory swapParams =
            IBaseUniswapV3SwapRouter02.ExactInputSingleParams({
                tokenIn: BASE_WETH,
                tokenOut: BASE_CBETH,
                fee: CBETH_WETH_POOL_FEE,
                recipient: delegatedEoa,
                amountIn: LEVERAGE_FLASH_WETH,
                amountOutMinimum: minimumCbEthOutput,
                sqrtPriceLimitX96: MAXIMUM_CBETH_PER_WETH_SQRT_PRICE_X96
            });
        callbackCalls[1] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_UNISWAP_V3_SWAP_ROUTER_02,
            abi.encodeCall(IBaseUniswapV3SwapRouter02.exactInputSingle, (swapParams)),
            DynamicCallTestBuilder.singleCheckpoint(BASE_CBETH, LEVERAGE_SWAP_OUTPUT_CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches(),
            false
        );
        callbackCalls[2] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_CBETH,
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, LEVERAGE_SWAP_OUTPUT_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_OFFSET
                )
            ),
            false
        );
        callbackCalls[3] = DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_CBETH, 0, delegatedEoa, NO_REFERRAL_CODE)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, LEVERAGE_SWAP_OUTPUT_CHECKPOINT_ID, AAVE_AMOUNT_ARGUMENT_OFFSET
                )
            ),
            false
        );
        callbackCalls[4] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.borrow,
                (BASE_WETH, repaymentBorrowAmount, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
            )
        );
    }

    function _buildFlashAssistedPartialDeleverage(
        address delegatedEoa,
        FlowAssertions flowAssertions,
        uint256 maximumPremium,
        uint256 maximumCbEthInput,
        uint256 minimumHealthFactor
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            _buildPartialDeleverageCallbackCalls(delegatedEoa, maximumCbEthInput);

        calls = new IDefiSimplify7702Account.DynamicCall[](7);
        calls[0] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_CBETH,
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            DynamicCallTestBuilder.singleCheckpoint(BASE_CBETH, PARTIAL_OUTER_REMAINDER_CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches(),
            false
        );
        calls[1] = _flashLoanCall(
            delegatedEoa, PARTIAL_FLASH_WETH, maximumPremium, callbackCalls, DynamicCallTestBuilder.noPatches()
        );
        calls[2] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_CBETH,
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, PARTIAL_OUTER_REMAINDER_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_OFFSET
                )
            ),
            false
        );
        calls[3] = DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_CBETH, 0, delegatedEoa, NO_REFERRAL_CODE)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, PARTIAL_OUTER_REMAINDER_CHECKPOINT_ID, AAVE_AMOUNT_ARGUMENT_OFFSET
                )
            ),
            false
        );
        calls[4] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (AAVE_V3_POOL, minimumHealthFactor))
        );
        calls[5] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertBalanceAtLeast, (BASE_WETH, EXISTING_WETH_INVENTORY))
        );
        calls[6] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertBalanceAtLeast, (BASE_CBETH, EXISTING_CBETH_INVENTORY))
        );
    }

    function _buildPartialDeleverageCallbackCalls(address delegatedEoa, uint256 maximumCbEthInput)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        uint256 requiredRepayment = PARTIAL_FLASH_WETH + _aaveFlashPremium(PARTIAL_FLASH_WETH);
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](6);
        callbackCalls[0] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_WETH, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, PARTIAL_FLASH_WETH))
        );
        callbackCalls[1] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.repay, (BASE_WETH, PARTIAL_FLASH_WETH, VARIABLE_INTEREST_RATE_MODE, delegatedEoa)
            )
        );
        callbackCalls[2] = DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(IBaseAaveV3Pool.withdraw, (BASE_CBETH, PARTIAL_CBETH_WITHDRAWAL, delegatedEoa)),
            DynamicCallTestBuilder.singleCheckpoint(BASE_CBETH, PARTIAL_CALLBACK_WITHDRAWAL_CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches(),
            false
        );
        callbackCalls[3] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_CBETH,
            abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, PARTIAL_CALLBACK_WITHDRAWAL_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_OFFSET
                )
            ),
            false
        );
        callbackCalls[4] = _exactOutputWethSwapCall(delegatedEoa, requiredRepayment, maximumCbEthInput);
        callbackCalls[5] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_CBETH, abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, 0))
        );
    }

    function _buildFlashAssistedFullClose(
        address delegatedEoa,
        FlowAssertions flowAssertions,
        StaticCallUint256Assertions staticAssertions,
        uint256 observedDebt,
        uint256 maximumPremium,
        uint256 maximumCbEthInput
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            _buildFullCloseCallbackCalls(delegatedEoa, observedDebt, maximumCbEthInput);

        calls = new IDefiSimplify7702Account.DynamicCall[](4);
        calls[0] = _flashLoanCall(
            delegatedEoa,
            0,
            maximumPremium,
            callbackCalls,
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCurrentBalancePatch(
                    BASE_AAVE_VARIABLE_DEBT_WETH, FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET
                )
            )
        );
        calls[1] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(staticAssertions),
            abi.encodeCall(
                IStaticCallUint256Assertions.assertStaticCallUint256AtMost,
                (
                    BASE_AAVE_VARIABLE_DEBT_WETH,
                    abi.encodeCall(IERC20.balanceOf, (STATIC_ASSERTION_ACCOUNT_PLACEHOLDER)),
                    BALANCE_OF_ACCOUNT_ARGUMENT_OFFSET,
                    FIRST_RETURN_WORD_OFFSET,
                    0
                )
            )
        );
        calls[2] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (AAVE_V3_POOL, type(uint256).max))
        );
        calls[3] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(flowAssertions),
            abi.encodeCall(
                IFlowAssertions.assertBalanceAtLeast,
                (BASE_CBETH, EXISTING_CBETH_INVENTORY + POSITION_INITIAL_CBETH_SUPPLY - FULL_CLOSE_MAXIMUM_CBETH_INPUT)
            )
        );
    }

    function _buildFullCloseCallbackCalls(address delegatedEoa, uint256 observedDebt, uint256 maximumCbEthInput)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        uint256 requiredRepayment = observedDebt + _aaveFlashPremium(observedDebt);
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](6);
        callbackCalls[0] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_WETH,
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCurrentBalancePatch(
                    BASE_AAVE_VARIABLE_DEBT_WETH, ERC20_APPROVE_AMOUNT_OFFSET
                )
            ),
            false
        );
        callbackCalls[1] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IBaseAaveV3Pool.repay, (BASE_WETH, type(uint256).max, VARIABLE_INTEREST_RATE_MODE, delegatedEoa)
            )
        );
        callbackCalls[2] = DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(IBaseAaveV3Pool.withdraw, (BASE_CBETH, type(uint256).max, delegatedEoa)),
            DynamicCallTestBuilder.singleCheckpoint(BASE_CBETH, FULL_CLOSE_WITHDRAWAL_CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches(),
            false
        );
        callbackCalls[3] = DynamicCallTestBuilder.buildZeroValueCall(
            BASE_CBETH,
            abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, 0)),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.fullCheckpointDeltaPatch(
                    BASE_CBETH, FULL_CLOSE_WITHDRAWAL_CHECKPOINT_ID, ERC20_APPROVE_AMOUNT_OFFSET
                )
            ),
            false
        );
        callbackCalls[4] = _exactOutputWethSwapCall(delegatedEoa, requiredRepayment, maximumCbEthInput);
        callbackCalls[5] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_CBETH, abi.encodeCall(IERC20.approve, (BASE_UNISWAP_V3_SWAP_ROUTER_02, 0))
        );
    }

    function _exactOutputWethSwapCall(address delegatedEoa, uint256 wethAmountOut, uint256 maximumCbEthInput)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        IBaseUniswapV3FlashLifecycleRouter.ExactOutputSingleParams memory swapParams =
            IBaseUniswapV3FlashLifecycleRouter.ExactOutputSingleParams({
                tokenIn: BASE_CBETH,
                tokenOut: BASE_WETH,
                fee: CBETH_WETH_POOL_FEE,
                recipient: delegatedEoa,
                amountOut: wethAmountOut,
                amountInMaximum: maximumCbEthInput,
                sqrtPriceLimitX96: MINIMUM_CBETH_PER_WETH_SQRT_PRICE_X96
            });
        return DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            BASE_UNISWAP_V3_SWAP_ROUTER_02,
            abi.encodeCall(IBaseUniswapV3FlashLifecycleRouter.exactOutputSingle, (swapParams))
        );
    }

    function _flashLoanCall(
        address delegatedEoa,
        uint256 amount,
        uint256 maximumPremium,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory) {
        bytes memory params = abi.encode(
            IDefiSimplify7702Account.CallbackEnvelope({maxPremium: maximumPremium, callbackCalls: callbackCalls})
        );
        return DynamicCallTestBuilder.buildZeroValueCall(
            AAVE_V3_POOL,
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple, (delegatedEoa, BASE_WETH, amount, params, NO_REFERRAL_CODE)
            ),
            DynamicCallTestBuilder.noCheckpoints(),
            patches,
            true
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

    /// @dev Mirrors the pinned Aave Pool revision's upward rounding of the simple-flash-loan premium.
    function _aaveFlashPremium(uint256 principal) internal pure returns (uint256) {
        return (principal * AAVE_FLASH_LOAN_PREMIUM_BPS + 9_999) / 10_000;
    }

    function _readFlashLifecycleState(address delegatedEoa) internal view returns (FlashLifecycleState memory state) {
        state.nativeBalance = delegatedEoa.balance;
        state.wethBalance = IERC20(BASE_WETH).balanceOf(delegatedEoa);
        state.cbEthBalance = IERC20(BASE_CBETH).balanceOf(delegatedEoa);
        state.aCbEthBalance = IERC20(BASE_AAVE_CBETH).balanceOf(delegatedEoa);
        state.variableDebtWethBalance = IERC20(BASE_AAVE_VARIABLE_DEBT_WETH).balanceOf(delegatedEoa);
        state.wethPoolAllowance = IERC20(BASE_WETH).allowance(delegatedEoa, AAVE_V3_POOL);
        state.wethRouterAllowance = IERC20(BASE_WETH).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02);
        state.cbEthPoolAllowance = IERC20(BASE_CBETH).allowance(delegatedEoa, AAVE_V3_POOL);
        state.cbEthRouterAllowance = IERC20(BASE_CBETH).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02);
        state.aaveWethReserveLiquidity = IERC20(BASE_WETH).balanceOf(BASE_AAVE_WETH);
        state.aaveCbEthReserveLiquidity = IERC20(BASE_CBETH).balanceOf(BASE_AAVE_CBETH);
        state.uniswapPoolWethBalance = IERC20(BASE_WETH).balanceOf(BASE_UNISWAP_V3_CBETH_WETH_500_POOL);
        state.uniswapPoolCbEthBalance = IERC20(BASE_CBETH).balanceOf(BASE_UNISWAP_V3_CBETH_WETH_500_POOL);
        (state.uniswapPoolSqrtPriceX96, state.uniswapPoolTick,,,,,) =
            IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).slot0();
        state.uniswapPoolLiquidity = IBaseUniswapV3Pool(BASE_UNISWAP_V3_CBETH_WETH_500_POOL).liquidity();
        state.aave = _readAaveAccountData(delegatedEoa);
    }

    function _assertFlashLifecycleStateEquals(FlashLifecycleState memory expected, address delegatedEoa) internal view {
        FlashLifecycleState memory actual = _readFlashLifecycleState(delegatedEoa);
        assertEq(actual.nativeBalance, expected.nativeBalance, "native balance rollback");
        assertEq(actual.wethBalance, expected.wethBalance, "WETH balance rollback");
        assertEq(actual.cbEthBalance, expected.cbEthBalance, "cbETH balance rollback");
        assertEq(actual.aCbEthBalance, expected.aCbEthBalance, "aBasecbETH balance rollback");
        assertEq(actual.variableDebtWethBalance, expected.variableDebtWethBalance, "WETH debt rollback");
        assertEq(actual.wethPoolAllowance, expected.wethPoolAllowance, "WETH Pool allowance rollback");
        assertEq(actual.wethRouterAllowance, expected.wethRouterAllowance, "WETH Router allowance rollback");
        assertEq(actual.cbEthPoolAllowance, expected.cbEthPoolAllowance, "cbETH Pool allowance rollback");
        assertEq(actual.cbEthRouterAllowance, expected.cbEthRouterAllowance, "cbETH Router allowance rollback");
        assertEq(
            actual.aaveWethReserveLiquidity, expected.aaveWethReserveLiquidity, "Aave WETH reserve liquidity rollback"
        );
        assertEq(
            actual.aaveCbEthReserveLiquidity,
            expected.aaveCbEthReserveLiquidity,
            "Aave cbETH reserve liquidity rollback"
        );
        assertEq(actual.uniswapPoolWethBalance, expected.uniswapPoolWethBalance, "Uniswap WETH rollback");
        assertEq(actual.uniswapPoolCbEthBalance, expected.uniswapPoolCbEthBalance, "Uniswap cbETH rollback");
        assertEq(actual.uniswapPoolSqrtPriceX96, expected.uniswapPoolSqrtPriceX96, "Uniswap price rollback");
        assertEq(actual.uniswapPoolTick, expected.uniswapPoolTick, "Uniswap tick rollback");
        assertEq(actual.uniswapPoolLiquidity, expected.uniswapPoolLiquidity, "Uniswap liquidity rollback");
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

    function _readSingleFlashLoan(Vm.Log[] memory logs, address delegatedEoa)
        internal
        pure
        returns (FlashLoanObservation memory observation)
    {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics[0] != AAVE_FLASH_LOAN_EVENT_SIGNATURE) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[1], _addressTopic(delegatedEoa), "flash target is delegated EOA");
            assertEq(logs[i].topics[2], _addressTopic(BASE_WETH), "flash asset is WETH");
            assertEq(uint256(logs[i].topics[3]), NO_REFERRAL_CODE, "flash referral code");

            (address initiator, uint256 amount, uint8 interestRateMode, uint256 premium) =
                abi.decode(logs[i].data, (address, uint256, uint8, uint256));
            assertEq(initiator, delegatedEoa, "flash initiator is delegated EOA");
            assertEq(interestRateMode, NO_FLASH_DEBT_MODE, "simple flash loan opens no Pool debt");
            observation = FlashLoanObservation({amount: amount, premium: premium});
        }
        assertEq(matchingEvents, 1, "expected one Aave FlashLoan event");
    }

    function _readSingleCbEthWethSwap(Vm.Log[] memory logs, address delegatedEoa, bool wethIsInput)
        internal
        pure
        returns (SwapObservation memory observation)
    {
        uint256 matchingEvents;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter != BASE_UNISWAP_V3_CBETH_WETH_500_POOL
                    || logs[i].topics[0] != UNISWAP_V3_CBETH_WETH_SWAP_EVENT_SIGNATURE
            ) {
                continue;
            }
            ++matchingEvents;
            assertEq(logs[i].topics[2], _addressTopic(delegatedEoa), "swap recipient is delegated EOA");
            (int256 amount0, int256 amount1,,,) = abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24));
            if (wethIsInput) {
                assertLt(amount0, 0, "cbETH is swap output");
                assertGt(amount1, 0, "WETH is swap input");
                observation.cbEthAmount = (-amount0).toUint256();
                observation.wethAmount = amount1.toUint256();
            } else {
                assertGt(amount0, 0, "cbETH is swap input");
                assertLt(amount1, 0, "WETH is swap output");
                observation.cbEthAmount = amount0.toUint256();
                observation.wethAmount = (-amount1).toUint256();
            }
        }
        assertEq(matchingEvents, 1, "expected one Uniswap cbETH/WETH Swap event");
    }

    function _assertNoResidualLifecycleAllowances(address delegatedEoa) internal view {
        assertEq(IERC20(BASE_WETH).allowance(delegatedEoa, AAVE_V3_POOL), 0, "zero WETH Pool allowance");
        assertEq(
            IERC20(BASE_WETH).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02), 0, "zero WETH Router allowance"
        );
        assertEq(IERC20(BASE_CBETH).allowance(delegatedEoa, AAVE_V3_POOL), 0, "zero cbETH Pool allowance");
        assertEq(
            IERC20(BASE_CBETH).allowance(delegatedEoa, BASE_UNISWAP_V3_SWAP_ROUTER_02), 0, "zero cbETH Router allowance"
        );
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

    function _selector(bytes memory encodedError) internal pure returns (bytes4 selector) {
        assertGe(encodedError.length, 4, "missing nested error selector");
        assembly ("memory-safe") {
            selector := mload(add(encodedError, 32))
        }
    }

    function _addressTopic(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
