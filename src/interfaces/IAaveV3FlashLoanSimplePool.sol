// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IAaveV3FlashLoanSimplePool
/// @notice Minimal Aave V3 Pool surface used to authenticate canonical simple flash-loan calldata.
interface IAaveV3FlashLoanSimplePool {
    /// @notice Lends one asset and invokes `executeOperation` on `receiverAddress`.
    /// @param receiverAddress Contract or delegated account receiving the asset and callback.
    /// @param asset ERC20 asset to lend.
    /// @param amount Principal amount to lend.
    /// @param params Opaque callback parameters forwarded to the receiver.
    /// @param referralCode Aave referral code; v1 account plans require zero.
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
