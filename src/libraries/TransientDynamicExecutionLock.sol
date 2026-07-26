// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title TransientDynamicExecutionLock
/// @notice Canonical transient reentrancy lock for DeFi Simplify dynamic account execution.
/// @dev The library owns one ERC-7201-derived transient namespace and is inlined into the
///      consuming account. It provides physical access only; the account owns authorization,
///      errors, and the decision to enter or leave the lock.
library TransientDynamicExecutionLock {
    using TransientSlot for *;

    // keccak256(abi.encode(uint256(keccak256(
    //     "DefiSimplify7702Account.transient.dynamicExecutionLock"
    // )) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _LOCK_SLOT = 0xa887af3dc6cbbedd251cf0b09904e889488cc283e13765d2c1980397e0c60e00;

    /// @notice Returns the frozen transient lock slot for independent layout verification.
    /// @return lockSlot ERC-7201-derived slot holding the dynamic execution lock.
    function slot() internal pure returns (bytes32 lockSlot) {
        return _LOCK_SLOT;
    }

    /// @notice Reports whether dynamic execution is currently locked in this storage context.
    /// @return locked Whether the lock has been entered.
    function isLocked() internal view returns (bool locked) {
        return _LOCK_SLOT.asBoolean().tload();
    }

    /// @notice Enters the dynamic execution lock.
    /// @dev The account must check `isLocked()` and apply its own error policy before calling.
    function lock() internal {
        _LOCK_SLOT.asBoolean().tstore(true);
    }

    /// @notice Leaves the dynamic execution lock after successful outer execution.
    /// @dev A reverting frame rolls back the prior lock write without requiring this function.
    function unlock() internal {
        _LOCK_SLOT.asBoolean().tstore(false);
    }
}
