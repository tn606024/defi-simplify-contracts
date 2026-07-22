// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title TransientTokenBalanceRecord
/// @notice Typed transient-storage access for records that bind an ERC20 token to one observed balance.
/// @dev Callers derive and scope each record root, enforce lifecycle and validation policy, and own all errors.
///      The physical record layout is fixed at offset 0 for presence, offset 1 for token, and offset 2 for balance.
///      `store` writes token and balance before publishing presence. All functions are internal and are inlined into
///      the consuming contract, so this library introduces no deployed or linked-library dependency.
library TransientTokenBalanceRecord {
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    uint256 private constant _TOKEN_OFFSET = 1;
    uint256 private constant _BALANCE_OFFSET = 2;

    /// @notice Reports whether the caller-scoped transient record has been published.
    /// @param recordRoot Slot at offset zero of the transient record.
    /// @return present Whether the explicit presence field is set.
    function isPresent(bytes32 recordRoot) internal view returns (bool present) {
        return recordRoot.asBoolean().tload();
    }

    /// @notice Loads the token field without applying caller-specific presence or token validation.
    /// @param recordRoot Slot at offset zero of the transient record.
    /// @return storedToken Token stored at record offset one.
    function token(bytes32 recordRoot) internal view returns (address storedToken) {
        return recordRoot.offset(_TOKEN_OFFSET).asAddress().tload();
    }

    /// @notice Loads the balance field without applying caller-specific presence or delta validation.
    /// @param recordRoot Slot at offset zero of the transient record.
    /// @return storedBalance Balance stored at record offset two.
    function balance(bytes32 recordRoot) internal view returns (uint256 storedBalance) {
        return recordRoot.offset(_BALANCE_OFFSET).asUint256().tload();
    }

    /// @notice Stores one token-balance record and publishes its explicit presence field last.
    /// @dev The caller must reject invalid or duplicate records before calling this function. No external call occurs
    ///      between these transient writes; an exceptional halt reverts every write in the current frame.
    /// @param recordRoot Slot at offset zero of the transient record.
    /// @param storedToken Token to store at record offset one.
    /// @param storedBalance Balance to store at record offset two; zero is valid and distinct from absence.
    function store(bytes32 recordRoot, address storedToken, uint256 storedBalance) internal {
        recordRoot.offset(_TOKEN_OFFSET).asAddress().tstore(storedToken);
        recordRoot.offset(_BALANCE_OFFSET).asUint256().tstore(storedBalance);
        recordRoot.asBoolean().tstore(true);
    }
}
