// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {IFlowAssertions} from "./interfaces/IFlowAssertions.sol";
import {TransientTokenBalanceRecord} from "./libraries/TransientTokenBalanceRecord.sol";

/// @title FlowAssertions
/// @notice Permissionless post-condition checker for transaction-scoped ERC20 balance flows.
/// @dev This direct immutable contract has no owner, asset-moving method, or permanent storage.
///      Snapshot records live only for the current transaction and are scoped to `msg.sender`.
contract FlowAssertions is IFlowAssertions {
    using SlotDerivation for bytes32;
    using TransientTokenBalanceRecord for bytes32;

    /// @dev Domain-separated root of the sender- and checkpoint-keyed transient snapshot table.
    bytes32 internal constant _BALANCE_SNAPSHOT_TABLE_NAMESPACE = keccak256("FlowAssertions.balanceSnapshotTable.v1");

    /// @inheritdoc IFlowAssertions
    function snapshotBalance(address token, bytes32 checkpointId) external {
        _requireValidToken(token);
        if (checkpointId == bytes32(0)) {
            revert InvalidAssertionCheckpointId(checkpointId);
        }

        address account = msg.sender;
        bytes32 recordRoot = _snapshotRecordRoot(account, checkpointId);
        if (recordRoot.isPresent()) {
            revert AssertionCheckpointAlreadyExists(account, checkpointId);
        }

        uint256 balance = _readBalance(token);
        recordRoot.store(token, balance);
    }

    /// @inheritdoc IFlowAssertions
    function assertBalanceAtLeast(address token, uint256 minimum) external view {
        _requireValidToken(token);
        uint256 currentBalance = _readBalance(token);
        if (currentBalance < minimum) {
            revert BalanceBelowMinimum(token, currentBalance, minimum);
        }
    }

    /// @inheritdoc IFlowAssertions
    function assertBalanceIncreaseAtLeast(address token, bytes32 checkpointId, uint256 minimumDelta) external view {
        _requireValidToken(token);
        uint256 checkpointBalance = _loadSnapshot(token, checkpointId);
        uint256 currentBalance = _readBalance(token);
        uint256 actualDelta = currentBalance > checkpointBalance ? currentBalance - checkpointBalance : 0;
        if (actualDelta < minimumDelta) {
            revert BalanceIncreaseTooSmall(token, checkpointId, actualDelta, minimumDelta);
        }
    }

    /// @inheritdoc IFlowAssertions
    function assertBalanceDecreaseAtMost(address token, bytes32 checkpointId, uint256 maximumDelta) external view {
        _requireValidToken(token);
        uint256 checkpointBalance = _loadSnapshot(token, checkpointId);
        uint256 currentBalance = _readBalance(token);
        uint256 actualDelta = checkpointBalance > currentBalance ? checkpointBalance - currentBalance : 0;
        if (actualDelta > maximumDelta) {
            revert BalanceDecreaseTooLarge(token, checkpointId, actualDelta, maximumDelta);
        }
    }

    /// @dev Derives the root slot of the transient snapshot record scoped by
    ///      `(account, checkpointId)`. The logical record layout is:
    ///      offset 0 = presence, offset 1 = token, offset 2 = checkpoint balance.
    /// @param account Caller that owns the transaction-scoped snapshot.
    /// @param checkpointId Caller-local snapshot identifier.
    /// @return recordRoot Slot at offset zero of the logical transient record.
    function _snapshotRecordRoot(address account, bytes32 checkpointId) internal pure returns (bytes32 recordRoot) {
        return _BALANCE_SNAPSHOT_TABLE_NAMESPACE.deriveMapping(account).deriveMapping(checkpointId);
    }

    /// @dev Loads a caller-owned snapshot and validates its token before any current-balance read
    ///      or threshold evaluation. A successful assertion deliberately does not consume the record.
    /// @param token Token expected by the consuming assertion.
    /// @param checkpointId Caller-local snapshot identifier.
    /// @return checkpointBalance Balance recorded when the snapshot was created.
    function _loadSnapshot(address token, bytes32 checkpointId) private view returns (uint256 checkpointBalance) {
        address account = msg.sender;
        bytes32 recordRoot = _snapshotRecordRoot(account, checkpointId);
        if (!recordRoot.isPresent()) {
            revert AssertionCheckpointNotFound(account, checkpointId);
        }

        address checkpointToken = recordRoot.token();
        if (checkpointToken != token) {
            revert AssertionCheckpointTokenMismatch(account, checkpointId, token, checkpointToken);
        }

        return recordRoot.balance();
    }

    /// @dev Rejects the zero token before any snapshot lookup or external balance read.
    /// @param token ERC20 address supplied to an assertion operation.
    function _requireValidToken(address token) private pure {
        if (token == address(0)) {
            revert InvalidAssertionToken(token);
        }
    }

    /// @dev Reads `balanceOf(msg.sender)` by low-level `STATICCALL`, preserving complete
    ///      revert data or short successful returndata for failure attribution.
    /// @param token ERC20 whose caller balance is read.
    /// @return tokenBalance First returned word when the call succeeds with at least 32 bytes.
    function _readBalance(address token) private view returns (uint256 tokenBalance) {
        (bool success, bytes memory returnData) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (msg.sender)));
        if (!success || returnData.length < 32) {
            revert AssertionBalanceReadFailed(token, returnData);
        }

        assembly ("memory-safe") {
            tokenBalance := mload(add(returnData, 32))
        }
    }
}
