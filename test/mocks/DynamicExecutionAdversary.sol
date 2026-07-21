// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";

contract DynamicExecutionAdversary {
    error TargetAssertionFailed(bytes payload);

    function failWithReturnDataSize(uint256 size) external pure {
        bytes memory reason = new bytes(size);
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    function assertCondition(bool condition, bytes calldata payload) external pure {
        if (!condition) {
            revert TargetAssertionFailed(payload);
        }
    }

    function returnPayload(bytes calldata payload) external pure returns (bytes memory) {
        return payload;
    }

    function callAccountExecute(address account) external {
        BaseAccount(account).execute(address(this), 0, "");
    }

    function callAccountExecuteBatch(address account) external {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](0);
        BaseAccount(account).executeBatch(calls);
    }
}
