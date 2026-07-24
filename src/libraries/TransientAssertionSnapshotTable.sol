// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

/// @title TransientAssertionSnapshotTable
/// @notice Canonical root derivation for caller-scoped FlowAssertions balance snapshots.
/// @dev The library owns the ERC-7201-derived table root and reproduces Solidity's logical
///      `mapping(address => mapping(bytes32 => Record))` derivation. It does not read or write
///      record fields and does not own assertion lifecycle, validation, or error policy.
library TransientAssertionSnapshotTable {
    using SlotDerivation for bytes32;

    // keccak256(abi.encode(uint256(keccak256(
    //     "FlowAssertions.transient.balanceSnapshotTable.v1"
    // )) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _TABLE_ROOT = 0x1f963d8cb67bb3d40e230a621403ddab3d6ffdd1872aa9e122595073131e5b00;

    /// @notice Returns the frozen assertion snapshot table root for independent layout verification.
    /// @return tableRoot ERC-7201-derived root of the logical nested mapping.
    function root() internal pure returns (bytes32 tableRoot) {
        return _TABLE_ROOT;
    }

    /// @notice Derives one caller-local assertion snapshot record root.
    /// @param account Caller that owns the transaction-scoped snapshot.
    /// @param checkpointId Caller-local snapshot identifier.
    /// @return recordRoot Slot at record offset zero for presence.
    function recordRoot(address account, bytes32 checkpointId) internal pure returns (bytes32) {
        return _TABLE_ROOT.deriveMapping(account).deriveMapping(checkpointId);
    }
}
