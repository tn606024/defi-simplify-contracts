// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @title DefiSimplify7702Account
/// @notice Minimal EIP-7702 delegated account baseline with unmodified upstream static execution.
/// @dev This implementation is deployed directly and used as an EIP-7702 delegation target.
///      During delegated execution, `address(this)` is the delegated EOA, not this implementation's
///      deployment address. The immutable EntryPoint and all account behavior are inherited from
///      the pinned upstream Simple7702Account v0.9.0 implementation.
contract DefiSimplify7702Account is Simple7702Account {
    constructor(IEntryPoint anEntryPoint) Simple7702Account(anEntryPoint) {}
}
