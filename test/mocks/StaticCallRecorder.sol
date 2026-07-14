// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract StaticCallRecorder {
    address public caller;
    uint256 public value;

    function record(uint256 newValue) external {
        caller = msg.sender;
        value = newValue;
    }
}
