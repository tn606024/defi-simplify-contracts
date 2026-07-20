// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

contract BaseEntryPointForkTest {
    uint256 private constant BASE_CHAIN_ID = 8453;
    address private constant ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes32 private constant ENTRY_POINT_RUNTIME_CODE_HASH =
        0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d;

    function test_BaseV090EntryPointExistsAndMatchesExpectedRuntimeCode() external view {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        require(ENTRY_POINT.code.length != 0, "EntryPoint has no code");
        require(ENTRY_POINT.codehash == ENTRY_POINT_RUNTIME_CODE_HASH, "unexpected EntryPoint runtime code");
    }
}
