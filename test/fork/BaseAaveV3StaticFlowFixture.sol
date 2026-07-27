// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Test-only write surface for the pinned Base Aave V3 Pool.
interface IBaseAaveV3Pool is IAaveV3Pool {
    event Supply(
        address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode
    );
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint8 interestRateMode,
        uint256 borrowRate,
        uint16 indexed referralCode
    );
    event Repay(
        address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens
    );

    function ADDRESSES_PROVIDER() external view returns (address);
    function POOL_REVISION() external pure returns (uint256);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawnAmount);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256 repaidAmount);
}

/// @dev Test-only Base wrapped-native interface.
interface IBaseWrappedNativeToken is IERC20 {
    function deposit() external payable;
}

/// @dev Test-only identity surface shared by Aave aTokens and variable-debt tokens.
interface IBaseAaveReserveToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @dev Shared pinned-fork identities and static-flow builders for DSC-52.
abstract contract BaseAaveV3StaticFlowFixture is DelegatedAccountFixture {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant BASE_FORK_BLOCK = 48_961_870;

    address internal constant BASE_ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes32 internal constant BASE_ENTRY_POINT_RUNTIME_CODE_HASH =
        0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d;

    address internal constant AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    bytes32 internal constant AAVE_V3_POOL_RUNTIME_CODE_HASH =
        0xffcb26fbebbe09d9b0d8baef76a1fa218989be6c279b7acf9865d8fb6e0718ce;
    address internal constant AAVE_V3_POOL_IMPLEMENTATION = 0xA4AbC5FcBA6D0d7E3D144d6dbF6cb6128599dFdB;
    bytes32 internal constant AAVE_V3_POOL_IMPLEMENTATION_RUNTIME_CODE_HASH =
        0x46a99baf41f90e39818ded14f4d45885fe6293496e72c1cea2014e814701a994;
    uint256 internal constant AAVE_V3_POOL_REVISION = 11;

    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    bytes32 internal constant BASE_WETH_RUNTIME_CODE_HASH =
        0x8a3a1f6a9f9dce633117adee5b458245835a8645a8c8726a26382a4622508b1c;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 internal constant BASE_USDC_RUNTIME_CODE_HASH =
        0xa6705a10bb756b5dea144591118be77d7af0c3eee3bf2dfe2583dcb0364fefab;
    address internal constant BASE_AAVE_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address internal constant BASE_AAVE_VARIABLE_DEBT_USDC = 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28;
    bytes32 internal constant BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH =
        0x59d2fd2a4bad76f979bc2c1da50504e072f4b3bb64f5429302a384ad9c0706f2;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant WETH_COLLATERAL_AMOUNT = 1 ether;
    uint256 internal constant USDC_BORROW_AMOUNT = 500e6;
    uint256 internal constant EXCESSIVE_USDC_BORROW_AMOUNT = 10_000e6;
    uint256 internal constant VARIABLE_INTEREST_RATE_MODE = 2;
    uint16 internal constant NO_REFERRAL_CODE = 0;

    struct AaveAccountData {
        uint256 totalCollateralBase;
        uint256 totalDebtBase;
        uint256 availableBorrowsBase;
        uint256 currentLiquidationThreshold;
        uint256 loanToValue;
        uint256 healthFactor;
    }

    function _setUpPinnedBaseAaveFork() internal {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        vm.rollFork(BASE_FORK_BLOCK);
        require(block.number == BASE_FORK_BLOCK, "unexpected Base fork block");

        assertEq(BASE_ENTRY_POINT.codehash, BASE_ENTRY_POINT_RUNTIME_CODE_HASH, "EntryPoint runtime identity");
        assertEq(AAVE_V3_POOL.codehash, AAVE_V3_POOL_RUNTIME_CODE_HASH, "Aave Pool proxy runtime identity");
        assertEq(
            AAVE_V3_POOL_IMPLEMENTATION.codehash,
            AAVE_V3_POOL_IMPLEMENTATION_RUNTIME_CODE_HASH,
            "Aave Pool implementation runtime identity"
        );
        assertEq(BASE_WETH.codehash, BASE_WETH_RUNTIME_CODE_HASH, "Base WETH runtime identity");
        assertEq(BASE_USDC.codehash, BASE_USDC_RUNTIME_CODE_HASH, "Base USDC runtime identity");
        assertEq(
            BASE_AAVE_WETH.codehash,
            BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH,
            "Base Aave WETH reserve-token runtime identity"
        );
        assertEq(
            BASE_AAVE_VARIABLE_DEBT_USDC.codehash,
            BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH,
            "Base Aave USDC debt-token runtime identity"
        );

        address poolImplementation = address(uint160(uint256(vm.load(AAVE_V3_POOL, EIP1967_IMPLEMENTATION_SLOT))));
        assertEq(poolImplementation, AAVE_V3_POOL_IMPLEMENTATION, "Aave Pool proxy implementation");
        assertEq(
            IBaseAaveV3Pool(AAVE_V3_POOL).ADDRESSES_PROVIDER(),
            AAVE_V3_POOL_ADDRESSES_PROVIDER,
            "Aave Pool addresses provider"
        );
        assertEq(
            IBaseAaveV3Pool(AAVE_V3_POOL).POOL_REVISION(), AAVE_V3_POOL_REVISION, "Aave Pool implementation revision"
        );
        assertEq(IBaseAaveReserveToken(BASE_AAVE_WETH).UNDERLYING_ASSET_ADDRESS(), BASE_WETH, "aWETH underlying asset");
        assertEq(
            IBaseAaveReserveToken(BASE_AAVE_VARIABLE_DEBT_USDC).UNDERLYING_ASSET_ADDRESS(),
            BASE_USDC,
            "variable-debt USDC underlying asset"
        );
    }

    function _wrapNativeAsDelegatedEoa(address payable delegatedEoa, uint256 amount) internal {
        vm.deal(delegatedEoa, amount);
        _executeAsDelegatedEoa(delegatedEoa, BASE_WETH, amount, abi.encodeCall(IBaseWrappedNativeToken.deposit, ()));
    }

    function _executeAsDelegatedEoa(address payable delegatedEoa, address target, uint256 value, bytes memory data)
        internal
    {
        vm.prank(delegatedEoa, delegatedEoa);
        Simple7702Account(delegatedEoa).execute(target, value, data);
    }

    function _executeBatchAsDelegatedEoa(address payable delegatedEoa, BaseAccount.Call[] memory calls) internal {
        vm.prank(delegatedEoa, delegatedEoa);
        Simple7702Account(delegatedEoa).executeBatch(calls);
    }

    function _invokeBatchAsDelegatedEoa(address payable delegatedEoa, BaseAccount.Call[] memory calls)
        internal
        returns (bool success, bytes memory returnData)
    {
        vm.prank(delegatedEoa, delegatedEoa);
        return delegatedEoa.call(abi.encodeWithSelector(BaseAccount.executeBatch.selector, calls));
    }

    /// @dev Builds the two-call setup used when WETH is already held by the
    /// delegated EOA: approve the Pool for the exact amount, then supply that
    /// amount as collateral on behalf of the same EOA.
    function _buildApproveAndSupplyBatch(address delegatedEoa, uint256 supplyAmount)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: BASE_WETH, value: 0, data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, supplyAmount))
        });
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_WETH, supplyAmount, delegatedEoa, NO_REFERRAL_CODE))
        });
    }

    /// @dev Continues after a separate approval: supply exact WETH collateral,
    /// then borrow exact variable-rate USDC against the delegated EOA.
    function _buildSupplyAndBorrowBatch(address delegatedEoa, uint256 supplyAmount, uint256 borrowAmount)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_WETH, supplyAmount, delegatedEoa, NO_REFERRAL_CODE))
        });
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.borrow,
                (BASE_USDC, borrowAmount, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
            )
        });
    }

    /// @dev Opens the reference static position in one atomic batch:
    /// exact WETH approval, WETH supply, then variable-rate USDC borrow.
    /// Tests assert the resulting balances and Aave account data after execution.
    function _buildOpenPositionBatch(address delegatedEoa, uint256 supplyAmount, uint256 borrowAmount)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](3);
        calls[0] = BaseAccount.Call({
            target: BASE_WETH, value: 0, data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, supplyAmount))
        });
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3Pool.supply, (BASE_WETH, supplyAmount, delegatedEoa, NO_REFERRAL_CODE))
        });
        calls[2] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.borrow,
                (BASE_USDC, borrowAmount, VARIABLE_INTEREST_RATE_MODE, NO_REFERRAL_CODE, delegatedEoa)
            )
        });
    }

    /// @dev Continues after a separate USDC approval: repay the delegated EOA's
    /// exact variable debt, then withdraw all unlocked WETH collateral.
    function _buildRepayAndWithdrawBatch(address delegatedEoa, uint256 debtAmount)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.repay, (BASE_USDC, debtAmount, VARIABLE_INTEREST_RATE_MODE, delegatedEoa)
            )
        });
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3Pool.withdraw, (BASE_WETH, type(uint256).max, delegatedEoa))
        });
    }

    /// @dev Closes the reference static position in one atomic batch:
    /// approve exact USDC debt, repay it, then withdraw all WETH collateral.
    /// The caller funds the exact repayment balance before executing this plan.
    function _buildClosePositionBatch(address delegatedEoa, uint256 debtAmount)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](3);
        calls[0] = BaseAccount.Call({
            target: BASE_USDC, value: 0, data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, debtAmount))
        });
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(
                IBaseAaveV3Pool.repay, (BASE_USDC, debtAmount, VARIABLE_INTEREST_RATE_MODE, delegatedEoa)
            )
        });
        calls[2] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IBaseAaveV3Pool.withdraw, (BASE_WETH, type(uint256).max, delegatedEoa))
        });
    }

    function _buildFailingBorrowBatch(address delegatedEoa) internal pure returns (BaseAccount.Call[] memory calls) {
        calls = _buildOpenPositionBatch(delegatedEoa, WETH_COLLATERAL_AMOUNT, EXCESSIVE_USDC_BORROW_AMOUNT);
    }

    function _openPosition(address payable delegatedEoa) internal {
        _wrapNativeAsDelegatedEoa(delegatedEoa, WETH_COLLATERAL_AMOUNT);
        _executeBatchAsDelegatedEoa(
            delegatedEoa, _buildOpenPositionBatch(delegatedEoa, WETH_COLLATERAL_AMOUNT, USDC_BORROW_AMOUNT)
        );
    }

    function _approveAssetAsDelegatedEoa(address payable delegatedEoa, address token, uint256 amount) internal {
        _executeAsDelegatedEoa(delegatedEoa, token, 0, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, amount)));
    }

    function _fundExactUsdcRepaymentBalance(address delegatedEoa, uint256 exactDebt) internal {
        if (IERC20(BASE_USDC).balanceOf(delegatedEoa) < exactDebt) {
            deal(BASE_USDC, delegatedEoa, exactDebt);
        }
        assertEq(IERC20(BASE_USDC).balanceOf(delegatedEoa), exactDebt, "exact USDC repayment balance");
    }

    function _readAaveAccountData(address delegatedEoa) internal view returns (AaveAccountData memory accountData) {
        (
            accountData.totalCollateralBase,
            accountData.totalDebtBase,
            accountData.availableBorrowsBase,
            accountData.currentLiquidationThreshold,
            accountData.loanToValue,
            accountData.healthFactor
        ) = IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(delegatedEoa);
    }

    function _assertNoAavePosition(address account) internal view {
        AaveAccountData memory accountData = _readAaveAccountData(account);
        assertEq(accountData.totalCollateralBase, 0, "unexpected Aave collateral");
        assertEq(accountData.totalDebtBase, 0, "unexpected Aave debt");
        assertEq(accountData.availableBorrowsBase, 0, "unexpected Aave borrowing capacity");
        assertEq(accountData.currentLiquidationThreshold, 0, "unexpected Aave liquidation threshold");
        assertEq(accountData.loanToValue, 0, "unexpected Aave loan-to-value");
        assertEq(accountData.healthFactor, type(uint256).max, "unexpected no-position health factor");
        assertEq(IERC20(BASE_AAVE_WETH).balanceOf(account), 0, "unexpected aWETH balance");
        assertEq(IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(account), 0, "unexpected USDC variable debt");
    }

    function _assertEquivalentAaveState(address upstreamEoa, address defiSimplifyEoa) internal view {
        AaveAccountData memory upstreamData = _readAaveAccountData(upstreamEoa);
        AaveAccountData memory defiSimplifyData = _readAaveAccountData(defiSimplifyEoa);

        assertEq(upstreamData.totalCollateralBase, defiSimplifyData.totalCollateralBase, "total collateral");
        assertEq(upstreamData.totalDebtBase, defiSimplifyData.totalDebtBase, "total debt");
        assertEq(upstreamData.availableBorrowsBase, defiSimplifyData.availableBorrowsBase, "available borrows");
        assertEq(
            upstreamData.currentLiquidationThreshold,
            defiSimplifyData.currentLiquidationThreshold,
            "liquidation threshold"
        );
        assertEq(upstreamData.loanToValue, defiSimplifyData.loanToValue, "loan-to-value");
        assertEq(upstreamData.healthFactor, defiSimplifyData.healthFactor, "health factor");
        assertEq(
            IERC20(BASE_WETH).balanceOf(upstreamEoa), IERC20(BASE_WETH).balanceOf(defiSimplifyEoa), "WETH balances"
        );
        assertEq(
            IERC20(BASE_USDC).balanceOf(upstreamEoa), IERC20(BASE_USDC).balanceOf(defiSimplifyEoa), "USDC balances"
        );
        assertEq(
            IERC20(BASE_AAVE_WETH).balanceOf(upstreamEoa),
            IERC20(BASE_AAVE_WETH).balanceOf(defiSimplifyEoa),
            "aWETH balances"
        );
        assertEq(
            IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(upstreamEoa),
            IERC20(BASE_AAVE_VARIABLE_DEBT_USDC).balanceOf(defiSimplifyEoa),
            "USDC variable-debt balances"
        );
        assertEq(
            IERC20(BASE_WETH).allowance(upstreamEoa, AAVE_V3_POOL),
            IERC20(BASE_WETH).allowance(defiSimplifyEoa, AAVE_V3_POOL),
            "WETH Pool allowances"
        );
        assertEq(
            IERC20(BASE_USDC).allowance(upstreamEoa, AAVE_V3_POOL),
            IERC20(BASE_USDC).allowance(defiSimplifyEoa, AAVE_V3_POOL),
            "USDC Pool allowances"
        );
    }

    function _assertExecuteErrorAtIndex(bytes memory revertData, uint256 expectedCallIndex)
        internal
        pure
        returns (bytes memory targetReason)
    {
        assertGe(revertData.length, 4, "missing ExecuteError selector");
        bytes4 actualSelector;
        assembly ("memory-safe") {
            actualSelector := mload(add(revertData, 32))
        }
        assertEq(actualSelector, BaseAccount.ExecuteError.selector, "unexpected batch error selector");

        bytes memory errorArguments = new bytes(revertData.length - 4);
        for (uint256 i = 0; i < errorArguments.length; ++i) {
            errorArguments[i] = revertData[i + 4];
        }
        (uint256 actualCallIndex, bytes memory nestedReason) = abi.decode(errorArguments, (uint256, bytes));
        assertEq(actualCallIndex, expectedCallIndex, "unexpected failed static call index");
        assertGt(nestedReason.length, 0, "missing nested Aave failure");
        return nestedReason;
    }

    function _baseEntryPoint() internal pure returns (IEntryPoint) {
        return IEntryPoint(BASE_ENTRY_POINT);
    }
}
