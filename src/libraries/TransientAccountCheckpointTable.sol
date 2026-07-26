// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

/// @title TransientAccountCheckpointTable
/// @notice Canonical root derivation for invocation-scoped DeFi Simplify account checkpoints.
/// @dev The library owns the ERC-7201-derived table root and reproduces Solidity's logical
///      `mapping(uint256 => mapping(bytes32 => Record))` derivation. It does not read or write
///      record fields and does not own checkpoint lifecycle, validation, or error policy.
library TransientAccountCheckpointTable {
    using SlotDerivation for bytes32;

    // keccak256(abi.encode(uint256(keccak256(
    //     "DefiSimplify7702Account.transient.checkpointTable.v1"
    // )) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _TABLE_ROOT = 0x1df8d66d1c593deebc9f7e8f07809a380ea5f1f0b42382a31a52db4f6ff66e00;

    /// @notice Returns the frozen checkpoint table root for independent layout verification.
    /// @return tableRoot ERC-7201-derived root of the logical nested mapping.
    function root() internal pure returns (bytes32 tableRoot) {
        return _TABLE_ROOT;
    }

    /// @notice Derives one invocation-local checkpoint record root.
    /// @param invocationId Active invocation scope containing the checkpoint.
    /// @param checkpointId Invocation-local checkpoint identifier.
    /// @return recordRoot Slot at record offset zero for presence.
    function recordRoot(uint256 invocationId, bytes32 checkpointId) internal pure returns (bytes32) {
        return _TABLE_ROOT.deriveMapping(invocationId).deriveMapping(checkpointId);
    }
}
