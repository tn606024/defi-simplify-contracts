// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";

contract StaticCompatibilityTarget {
    error TargetFailure(uint256 code, bytes payload);

    event Recorded(uint256 indexed sequence, uint256 amount, uint256 callValue, bytes32 payloadHash);

    address public lastCaller;
    uint256 public count;
    uint256 public total;
    uint256 public totalCallValue;
    bytes32 public lastPayloadHash;

    function record(uint256 amount, bytes calldata payload) external payable {
        lastCaller = msg.sender;
        count += 1;
        total += amount;
        totalCallValue += msg.value;
        lastPayloadHash = keccak256(payload);
        emit Recorded(count, amount, msg.value, lastPayloadHash);
    }

    function fail(uint256 code, bytes calldata payload) external pure {
        revert TargetFailure(code, payload);
    }

    function callAccountExecute(address account) external {
        BaseAccount(account).execute(address(this), 0, "");
    }
}
