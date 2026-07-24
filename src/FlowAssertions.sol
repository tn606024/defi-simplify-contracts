// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IFlowAssertions} from "./interfaces/IFlowAssertions.sol";
import {TransientTokenBalanceRecord} from "./libraries/TransientTokenBalanceRecord.sol";

/// @title FlowAssertions
/// @notice Permissionless post-condition checker for delegated-account DeFi flows.
/// @dev This direct immutable contract has no owner, asset-moving method, or permanent storage.
///      Snapshot records live only for the current transaction and are scoped to `msg.sender`.
contract FlowAssertions is IFlowAssertions {
    using SlotDerivation for bytes32;
    using TransientTokenBalanceRecord for bytes32;

    /// @dev Domain-separated root of the sender- and checkpoint-keyed transient snapshot table.
    // keccak256("FlowAssertions.balanceSnapshotTable")
    bytes32 internal constant _BALANCE_SNAPSHOT_TABLE_SLOT =
        0xa140f7bcbac33064b18ae2b2aecf05c745c280261f40758c51e4753fae052f7f;

    /// @dev Aave V3 `getUserAccountData` returns six statically encoded words.
    uint256 private constant _AAVE_V3_ACCOUNT_DATA_RETURN_LENGTH = 6 * 32;

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

    /// @inheritdoc IFlowAssertions
    function assertAaveV3HealthFactorAtLeast(address pool, uint256 minimumHealthFactor) external view {
        uint256 healthFactor = _readAaveV3HealthFactor(pool);
        if (healthFactor < minimumHealthFactor) {
            revert AaveV3HealthFactorTooLow(pool, healthFactor, minimumHealthFactor);
        }
    }

    /// @dev Derives the root slot of the transient snapshot record scoped by
    ///      `(account, checkpointId)`. The logical record layout is:
    ///      offset 0 = presence, offset 1 = token, offset 2 = checkpoint balance.
    /// @param account Caller that owns the transaction-scoped snapshot.
    /// @param checkpointId Caller-local snapshot identifier.
    /// @return recordRoot Slot at offset zero of the logical transient record.
    function _snapshotRecordRoot(address account, bytes32 checkpointId) internal pure returns (bytes32 recordRoot) {
        return _BALANCE_SNAPSHOT_TABLE_SLOT.deriveMapping(account).deriveMapping(checkpointId);
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

    /// @dev Reads the sixth word of Aave V3 `getUserAccountData(msg.sender)` only after validating
    ///      the complete six-word static tuple. Failed calls and short successful responses preserve
    ///      their complete returned bytes for target-specific attribution.
    /// @param pool Aave V3-compatible Pool selected and verified by the caller's SDK.
    /// @return healthFactor Health factor reported by the supplied Pool for `msg.sender`.
    function _readAaveV3HealthFactor(address pool) private view returns (uint256 healthFactor) {
        (bool success, bytes memory returnData) =
            pool.staticcall(abi.encodeCall(IAaveV3Pool.getUserAccountData, (msg.sender)));
        if (!success || returnData.length < _AAVE_V3_ACCOUNT_DATA_RETURN_LENGTH) {
            revert AaveV3AccountDataReadFailed(pool, returnData);
        }

        assembly ("memory-safe") {
            healthFactor := mload(add(returnData, 192))
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
