// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IFlowAssertions
/// @notice Read-only post-condition checks and transaction-scoped ERC20 balance snapshots for DeFi flows.
/// @dev Every typed account subject is the direct caller. Implementations must not accept an
///      arbitrary account parameter for balance or Aave V3 health-factor assertions.
interface IFlowAssertions {
    /// @notice The supplied ERC20 token address is zero.
    /// @param token Invalid token address.
    error InvalidAssertionToken(address token);

    /// @notice The supplied assertion checkpoint identifier is zero.
    /// @param id Invalid checkpoint identifier.
    error InvalidAssertionCheckpointId(bytes32 id);

    /// @notice A checkpoint identifier already exists for the caller in this transaction.
    /// @param account Caller whose transaction-scoped checkpoint already exists.
    /// @param id Duplicate checkpoint identifier.
    error AssertionCheckpointAlreadyExists(address account, bytes32 id);

    /// @notice A checkpoint identifier does not exist for the caller in this transaction.
    /// @param account Caller whose transaction-scoped checkpoint was requested.
    /// @param id Missing checkpoint identifier.
    error AssertionCheckpointNotFound(address account, bytes32 id);

    /// @notice A checkpoint was created for a different ERC20 token.
    /// @param account Caller that owns the transaction-scoped checkpoint.
    /// @param id Checkpoint identifier whose token does not match.
    /// @param expected Token supplied by the consuming assertion.
    /// @param actual Token recorded by the checkpoint.
    error AssertionCheckpointTokenMismatch(address account, bytes32 id, address expected, address actual);

    /// @notice An ERC20 balance read failed or returned fewer than 32 bytes.
    /// @param token ERC20 whose balance could not be read.
    /// @param reason Complete revert data, or malformed successful returndata when the read was short.
    error AssertionBalanceReadFailed(address token, bytes reason);

    /// @notice The caller's current ERC20 balance is below the required minimum.
    /// @param token ERC20 whose balance was checked.
    /// @param actual Caller balance observed by the assertion.
    /// @param minimum Required minimum balance.
    error BalanceBelowMinimum(address token, uint256 actual, uint256 minimum);

    /// @notice The caller's ERC20 balance increase since a checkpoint is too small.
    /// @param token ERC20 whose balance increase was checked.
    /// @param id Checkpoint used as the initial balance.
    /// @param actualDelta Saturating balance increase observed by the assertion.
    /// @param minimumDelta Required minimum balance increase.
    error BalanceIncreaseTooSmall(address token, bytes32 id, uint256 actualDelta, uint256 minimumDelta);

    /// @notice The caller's ERC20 balance decrease since a checkpoint is too large.
    /// @param token ERC20 whose balance decrease was checked.
    /// @param id Checkpoint used as the initial balance.
    /// @param actualDelta Saturating balance decrease observed by the assertion.
    /// @param maximumDelta Allowed maximum balance decrease.
    error BalanceDecreaseTooLarge(address token, bytes32 id, uint256 actualDelta, uint256 maximumDelta);

    /// @notice An Aave V3 Pool account-data read failed or returned fewer than six words.
    /// @param pool Aave V3-compatible Pool whose account data could not be read.
    /// @param reason Complete revert data, or complete malformed successful returndata when the response was short.
    error AaveV3AccountDataReadFailed(address pool, bytes reason);

    /// @notice The caller's Aave V3 health factor is below the required minimum.
    /// @param pool Aave V3-compatible Pool whose account data was checked.
    /// @param actual Health factor reported by the Pool for the caller.
    /// @param minimum Required minimum health factor.
    error AaveV3HealthFactorTooLow(address pool, uint256 actual, uint256 minimum);

    /// @notice Records the caller's current ERC20 balance for later assertions in this transaction.
    /// @param token ERC20 whose `balanceOf(msg.sender)` value is recorded.
    /// @param checkpointId Nonzero caller-scoped identifier that must be unique in this transaction.
    function snapshotBalance(address token, bytes32 checkpointId) external;

    /// @notice Requires the caller's current ERC20 balance to be at least a minimum.
    /// @param token ERC20 whose `balanceOf(msg.sender)` value is checked.
    /// @param minimum Required minimum balance.
    function assertBalanceAtLeast(address token, uint256 minimum) external view;

    /// @notice Requires a minimum saturating ERC20 balance increase from a named checkpoint.
    /// @dev If the current balance is below the checkpoint balance, the observed increase is zero.
    /// @param token ERC20 whose balance increase is checked.
    /// @param checkpointId Existing caller-scoped checkpoint identifier for `token`.
    /// @param minimumDelta Required minimum balance increase.
    function assertBalanceIncreaseAtLeast(address token, bytes32 checkpointId, uint256 minimumDelta) external view;

    /// @notice Requires the saturating ERC20 balance decrease from a named checkpoint not to exceed a maximum.
    /// @dev If the current balance is above the checkpoint balance, the observed decrease is zero.
    /// @param token ERC20 whose balance decrease is checked.
    /// @param checkpointId Existing caller-scoped checkpoint identifier for `token`.
    /// @param maximumDelta Allowed maximum balance decrease.
    function assertBalanceDecreaseAtMost(address token, bytes32 checkpointId, uint256 maximumDelta) external view;

    /// @notice Requires the caller's Aave V3 health factor to be at least a minimum.
    /// @dev Trusts the supplied Aave V3-compatible Pool and its configured oracle/accounting view.
    ///      The function name is versioned and does not claim Aave V2 or future-version compatibility.
    /// @param pool Aave V3-compatible Pool queried with `getUserAccountData(msg.sender)`.
    /// @param minimumHealthFactor Required minimum health factor, expressed with Aave V3's 18-decimal convention.
    function assertAaveV3HealthFactorAtLeast(address pool, uint256 minimumHealthFactor) external view;
}
