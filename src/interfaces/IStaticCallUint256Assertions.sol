// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IStaticCallUint256Assertions
/// @notice Generic fixed-word uint256 post-condition checks over read-only target calls.
/// @dev Account binding is an adapter guardrail, not an authorization boundary. Callers and
///      policy-enforcing signers must authenticate the checker, target, selector, offsets,
///      comparison direction, and bound semantics independently.
interface IStaticCallUint256Assertions {
    /// @notice The supplied staticcall target is zero or the checker itself.
    /// @param target Invalid target address.
    error InvalidAssertionTarget(address target);

    /// @notice The supplied target calldata is shorter than a four-byte selector.
    /// @param dataLength Actual calldata length.
    error InvalidAssertionCallData(uint256 dataLength);

    /// @notice The account-binding offset is below the arguments, unaligned, or out of bounds.
    /// @param offset Selector-relative byte offset supplied for the account word.
    /// @param dataLength Actual target calldata length.
    error InvalidAssertionAccountOffset(uint256 offset, uint256 dataLength);

    /// @notice The selected return offset is unaligned or does not contain a complete word.
    /// @param offset Byte offset supplied for the uint256 return word.
    /// @param returnDataLength Actual successful returndata length.
    error InvalidAssertionReturnOffset(uint256 offset, uint256 returnDataLength);

    /// @notice The target staticcall reverted.
    /// @param target Target whose staticcall failed.
    /// @param selector Selector of the target calldata.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param reason Complete target revert data.
    error AssertionStaticCallFailed(address target, bytes4 selector, uint256 accountOffset, bytes reason);

    /// @notice The selected target return word is below the required minimum.
    /// @param target Target whose return word was checked.
    /// @param selector Selector of the target calldata.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param returnOffset Byte offset of the selected return word.
    /// @param actual Selected uint256 value returned by the target.
    /// @param minimum Required minimum value.
    error StaticCallUint256BelowMinimum(
        address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 minimum
    );

    /// @notice The selected target return word is above the allowed maximum.
    /// @param target Target whose return word was checked.
    /// @param selector Selector of the target calldata.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param returnOffset Byte offset of the selected return word.
    /// @param actual Selected uint256 value returned by the target.
    /// @param maximum Allowed maximum value.
    error StaticCallUint256AboveMaximum(
        address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 maximum
    );

    /// @notice Requires a selected uint256 return word to be at least a minimum.
    /// @dev In account-binding mode, `accountOffset` includes the four-byte selector and identifies
    ///      one ABI-aligned calldata word replaced with zero-left-padded `msg.sender`. The explicit
    ///      `type(uint32).max` sentinel selects global-read mode and leaves `data` unchanged.
    /// @param target Contract queried by low-level STATICCALL.
    /// @param data Complete target calldata including its selector.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param returnOffset ABI-aligned byte offset of the selected returndata word.
    /// @param minimum Required minimum value.
    function assertStaticCallUint256AtLeast(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 minimum
    ) external view;

    /// @notice Requires a selected uint256 return word not to exceed a maximum.
    /// @dev In account-binding mode, `accountOffset` includes the four-byte selector and identifies
    ///      one ABI-aligned calldata word replaced with zero-left-padded `msg.sender`. The explicit
    ///      `type(uint32).max` sentinel selects global-read mode and leaves `data` unchanged.
    /// @param target Contract queried by low-level STATICCALL.
    /// @param data Complete target calldata including its selector.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param returnOffset ABI-aligned byte offset of the selected returndata word.
    /// @param maximum Allowed maximum value.
    function assertStaticCallUint256AtMost(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 maximum
    ) external view;
}
