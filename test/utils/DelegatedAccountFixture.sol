// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Canonical local EIP-7702 fixture for unit and Base fork tests.
///      Both account variants execute in EOA context through Foundry's Prague
///      delegation cheatcode; direct implementation calls are not a substitute.
abstract contract DelegatedAccountFixture is Test {
    uint256 internal constant UPSTREAM_AUTHORITY_KEY =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant CUSTOM_AUTHORITY_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    struct DelegatedPair {
        Simple7702Account upstreamImplementation;
        DefiSimplify7702Account customImplementation;
        address payable upstreamAccount;
        address payable customAccount;
    }

    function _deployDelegatedPair(IEntryPoint entryPoint) internal returns (DelegatedPair memory pair) {
        return _deployDelegatedPair(entryPoint, UPSTREAM_AUTHORITY_KEY, CUSTOM_AUTHORITY_KEY);
    }

    function _deployDelegatedPair(IEntryPoint entryPoint, uint256 upstreamKey, uint256 customKey)
        internal
        returns (DelegatedPair memory pair)
    {
        pair.upstreamImplementation = new Simple7702Account(entryPoint);
        pair.customImplementation = new DefiSimplify7702Account(entryPoint);
        pair.upstreamAccount = payable(vm.addr(upstreamKey));
        pair.customAccount = payable(vm.addr(customKey));

        require(pair.upstreamAccount.code.length == 0, "upstream authority already has code");
        require(pair.customAccount.code.length == 0, "custom authority already has code");

        vm.signAndAttachDelegation(address(pair.upstreamImplementation), upstreamKey);
        vm.signAndAttachDelegation(address(pair.customImplementation), customKey);

        require(
            _delegationTarget(pair.upstreamAccount) == address(pair.upstreamImplementation), "wrong upstream target"
        );
        require(_delegationTarget(pair.customAccount) == address(pair.customImplementation), "wrong custom target");
    }

    function _delegationTarget(address account) internal view returns (address implementation) {
        bytes memory code = account.code;
        require(code.length == 23, "invalid delegation indicator length");
        uint24 prefix;
        assembly ("memory-safe") {
            prefix := shr(232, mload(add(code, 32)))
            implementation := shr(96, mload(add(code, 35)))
        }
        require(prefix == 0xef0100, "invalid delegation indicator prefix");
    }

    /// @dev Returns the upstream delegated EOA through its inherited static-account ABI.
    function _upstreamAccount(DelegatedPair storage pair) internal view returns (Simple7702Account) {
        return Simple7702Account(pair.upstreamAccount);
    }

    /// @dev Returns the custom delegated EOA through its concrete account ABI.
    function _customAccount(DelegatedPair storage pair) internal view returns (DefiSimplify7702Account) {
        return DefiSimplify7702Account(pair.customAccount);
    }

    /// @dev Returns the custom delegated EOA through the frozen dynamic interface.
    function _dynamicAccount(DelegatedPair storage pair) internal view returns (IDefiSimplify7702Account) {
        return IDefiSimplify7702Account(pair.customAccount);
    }

    /// @dev Returns a delegated EOA address through the frozen dynamic interface.
    function _dynamicAccount(address payable account) internal pure returns (IDefiSimplify7702Account) {
        return IDefiSimplify7702Account(account);
    }

    function _signature(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
