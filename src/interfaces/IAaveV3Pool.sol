// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IAaveV3Pool
/// @notice Minimal Aave V3 Pool view used by the typed health-factor assertion.
interface IAaveV3Pool {
    /// @notice Returns the aggregate Aave V3 position data for one user.
    /// @param user Account whose position data is requested.
    /// @return totalCollateralBase Total collateral value in the Pool's base currency.
    /// @return totalDebtBase Total debt value in the Pool's base currency.
    /// @return availableBorrowsBase Remaining borrowing capacity in the Pool's base currency.
    /// @return currentLiquidationThreshold Current weighted-average liquidation threshold in basis points.
    /// @return ltv Current weighted-average loan-to-value ratio in basis points.
    /// @return healthFactor Current Aave V3 health factor, expressed with 18 decimals.
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
