// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IStaticCallUint256Assertions} from "./interfaces/IStaticCallUint256Assertions.sol";

/// @title StaticCallUint256Assertions
/// @notice Independent generic checker for one fixed-position uint256 returned by a STATICCALL.
/// @dev This permissionless direct immutable contract has no owner, upgrade path, storage,
///      payable path, asset-moving method, or custom events. Account binding is only an adapter
///      guardrail: the SDK and signer must admit exact reviewed checker and target semantics.
contract StaticCallUint256Assertions is IStaticCallUint256Assertions {
    /// @inheritdoc IStaticCallUint256Assertions
    function assertStaticCallUint256AtLeast(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 minimum
    ) external view {
        (bytes4 selector, uint256 actual) = _readUint256(target, data, accountOffset, returnOffset);
        if (actual < minimum) {
            revert StaticCallUint256BelowMinimum(
                target, selector, uint256(accountOffset), uint256(returnOffset), actual, minimum
            );
        }
    }

    /// @inheritdoc IStaticCallUint256Assertions
    function assertStaticCallUint256AtMost(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 maximum
    ) external view {
        (bytes4 selector, uint256 actual) = _readUint256(target, data, accountOffset, returnOffset);
        if (actual > maximum) {
            revert StaticCallUint256AboveMaximum(
                target, selector, uint256(accountOffset), uint256(returnOffset), actual, maximum
            );
        }
    }

    /// @dev Validates and optionally account-binds target calldata, performs STATICCALL, and reads
    ///      exactly one ABI-aligned return word. Offsets describe an SDK-reviewed ABI layout;
    ///      Solidity targets may ignore trailing calldata, so replacement is not authorization.
    /// @param target Contract queried by low-level STATICCALL.
    /// @param data Complete target calldata including its selector.
    /// @param accountOffset Account word offset, or `type(uint32).max` for global-read mode.
    /// @param returnOffset ABI-aligned byte offset of the selected returndata word.
    /// @return selector Selector preserved for indexed error attribution.
    /// @return actual Selected uint256 returndata word.
    function _readUint256(address target, bytes calldata data, uint32 accountOffset, uint32 returnOffset)
        private
        view
        returns (bytes4 selector, uint256 actual)
    {
        if (target == address(0) || target == address(this)) {
            revert InvalidAssertionTarget(target);
        }

        uint256 dataLength = data.length;
        if (dataLength < 4) {
            revert InvalidAssertionCallData(dataLength);
        }

        assembly ("memory-safe") {
            selector := calldataload(data.offset)
        }

        uint256 accountWordOffset = uint256(accountOffset);
        bool isGlobalRead = accountOffset == type(uint32).max;
        if (
            !isGlobalRead
                && (accountWordOffset < 4 || (accountWordOffset - 4) % 32 != 0 || accountWordOffset + 32 > dataLength)
        ) {
            revert InvalidAssertionAccountOffset(accountWordOffset, dataLength);
        }

        bytes memory callData = data;
        if (!isGlobalRead) {
            assembly ("memory-safe") {
                mstore(add(add(callData, 32), accountWordOffset), caller())
            }
        }

        (bool success, bytes memory returnData) = target.staticcall(callData);
        if (!success) {
            revert AssertionStaticCallFailed(target, selector, accountWordOffset, returnData);
        }

        uint256 returnWordOffset = uint256(returnOffset);
        uint256 returnDataLength = returnData.length;
        if (returnWordOffset % 32 != 0 || returnWordOffset + 32 > returnDataLength) {
            revert InvalidAssertionReturnOffset(returnWordOffset, returnDataLength);
        }

        assembly ("memory-safe") {
            actual := mload(add(add(returnData, 32), returnWordOffset))
        }
    }
}
