// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Deterministic fixture used only to verify the bootstrapped toolchain.
contract ProjectBootstrap {
    function version() external pure returns (uint256) {
        return 1;
    }
}
