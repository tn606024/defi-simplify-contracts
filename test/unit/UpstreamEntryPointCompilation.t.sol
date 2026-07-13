// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";

contract UpstreamEntryPointCompilationTest {
    function test_UpstreamEntryPointCompilesWithPinnedToolchain() external pure {
        require(keccak256(type(EntryPoint).creationCode) != bytes32(0), "empty EntryPoint creation code");
    }
}
