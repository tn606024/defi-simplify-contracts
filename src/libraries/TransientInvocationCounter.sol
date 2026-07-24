// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title TransientInvocationCounter
/// @notice Canonical transaction-scoped invocation counter for DeFi Simplify dynamic execution.
/// @dev The library owns one ERC-7201-derived transient namespace and is inlined into the
///      consuming account. Checked increment preserves the nonzero invocation-ID invariant.
library TransientInvocationCounter {
    using TransientSlot for *;

    // keccak256(abi.encode(uint256(keccak256(
    //     "DefiSimplify7702Account.transient.dynamicInvocationCounter"
    // )) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _COUNTER_SLOT = 0xeaf74057172b9c7d3a37d1cf7b5689ce9049923e31a501f8e4dab9e627800900;

    /// @notice Returns the frozen transient counter slot for independent layout verification.
    /// @return counterSlot ERC-7201-derived slot holding the invocation counter.
    function slot() internal pure returns (bytes32 counterSlot) {
        return _COUNTER_SLOT;
    }

    /// @notice Returns the current transaction-scoped counter value.
    /// @return value Latest successfully allocated invocation ID, or zero before allocation.
    function current() internal view returns (uint256 value) {
        return _COUNTER_SLOT.asUint256().tload();
    }

    /// @notice Allocates and returns the next nonzero invocation ID.
    /// @dev Solidity checked arithmetic reverts rather than wrapping the counter to zero.
    /// @return invocationId Newly stored invocation ID.
    function increment() internal returns (uint256 invocationId) {
        invocationId = current() + 1;
        _COUNTER_SLOT.asUint256().tstore(invocationId);
    }
}
