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
    uint256 internal constant DEFI_SIMPLIFY_AUTHORITY_KEY =
        0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    /// @dev One EOA delegated to the pinned upstream implementation.
    struct DelegatedUpstreamAccount {
        Simple7702Account implementation;
        address payable delegatedEoa;
    }

    /// @dev One EOA delegated to the DeFi Simplify implementation under test.
    struct DelegatedDefiSimplifyAccount {
        DefiSimplify7702Account implementation;
        address payable delegatedEoa;
    }

    /// @dev Two independent EOAs used only for upstream compatibility comparisons.
    struct UpstreamCompatibilityFixture {
        DelegatedUpstreamAccount upstream;
        DelegatedDefiSimplifyAccount defiSimplify;
    }

    /// @dev Deploys the DeFi Simplify implementation and attaches the default
    ///      authority EOA using Foundry's Prague EIP-7702 cheatcode. Calls must
    ///      target `delegatedEoa`, where implementation code runs in EOA context.
    function _deployDelegatedDefiSimplifyAccount(IEntryPoint entryPoint)
        internal
        returns (DelegatedDefiSimplifyAccount memory accountUnderTest)
    {
        return _deployDelegatedDefiSimplifyAccount(entryPoint, DEFI_SIMPLIFY_AUTHORITY_KEY);
    }

    /// @dev Same delegated-account setup with an explicit authority key. The EOA
    ///      must start without code so the fixture cannot silently replace a
    ///      prior delegation or ordinary contract runtime.
    function _deployDelegatedDefiSimplifyAccount(IEntryPoint entryPoint, uint256 authorityKey)
        internal
        returns (DelegatedDefiSimplifyAccount memory accountUnderTest)
    {
        accountUnderTest.implementation = new DefiSimplify7702Account(entryPoint);
        accountUnderTest.delegatedEoa = payable(vm.addr(authorityKey));

        require(accountUnderTest.delegatedEoa.code.length == 0, "DeFi Simplify authority already has code");

        vm.signAndAttachDelegation(address(accountUnderTest.implementation), authorityKey);

        require(
            _delegationTarget(accountUnderTest.delegatedEoa) == address(accountUnderTest.implementation),
            "wrong DeFi Simplify delegation target"
        );
    }

    /// @dev Deploys and attaches the pinned upstream implementation to the
    ///      default upstream authority for differential tests.
    function _deployDelegatedUpstreamAccount(IEntryPoint entryPoint)
        internal
        returns (DelegatedUpstreamAccount memory upstreamAccount)
    {
        return _deployDelegatedUpstreamAccount(entryPoint, UPSTREAM_AUTHORITY_KEY);
    }

    /// @dev Same upstream delegated-account setup with an explicit authority key.
    function _deployDelegatedUpstreamAccount(IEntryPoint entryPoint, uint256 authorityKey)
        internal
        returns (DelegatedUpstreamAccount memory upstreamAccount)
    {
        upstreamAccount.implementation = new Simple7702Account(entryPoint);
        upstreamAccount.delegatedEoa = payable(vm.addr(authorityKey));

        require(upstreamAccount.delegatedEoa.code.length == 0, "upstream authority already has code");

        vm.signAndAttachDelegation(address(upstreamAccount.implementation), authorityKey);

        require(
            _delegationTarget(upstreamAccount.delegatedEoa) == address(upstreamAccount.implementation),
            "wrong upstream delegation target"
        );
    }

    /// @dev Creates two independent delegated EOAs for upstream compatibility
    ///      comparisons; the two ABI views never represent separate contexts for
    ///      one authority.
    function _deployUpstreamCompatibilityFixture(IEntryPoint entryPoint)
        internal
        returns (UpstreamCompatibilityFixture memory compatibilityFixture)
    {
        return _deployUpstreamCompatibilityFixture(entryPoint, UPSTREAM_AUTHORITY_KEY, DEFI_SIMPLIFY_AUTHORITY_KEY);
    }

    /// @dev Same two-EOA compatibility fixture with explicit authority keys.
    function _deployUpstreamCompatibilityFixture(
        IEntryPoint entryPoint,
        uint256 upstreamAuthorityKey,
        uint256 defiSimplifyAuthorityKey
    ) internal returns (UpstreamCompatibilityFixture memory compatibilityFixture) {
        compatibilityFixture.upstream = _deployDelegatedUpstreamAccount(entryPoint, upstreamAuthorityKey);
        compatibilityFixture.defiSimplify = _deployDelegatedDefiSimplifyAccount(entryPoint, defiSimplifyAuthorityKey);
    }

    /// @dev Parses the 23-byte EIP-7702 designator `0xef0100 || implementation`.
    ///
    /// `delegatedEoa.code` copies the designator into `bytes memory`; the first
    /// word at `code` is its length and payload starts at `code + 32`. The first
    /// load extracts the three-byte prefix. The implementation begins at payload
    /// byte offset 3, so `code + 35` points to its first byte and `shr(96, ...)`
    /// keeps the left-aligned 20-byte address. No Solidity storage slot is read
    /// or written by this assembly.
    ///
    /// Foundry's Prague cheatcode makes calls through the EOA execute the attached
    /// implementation in delegated EOA context. Calling the implementation
    /// directly or replacing EOA code with `vm.etch` would not test that context.
    function _delegationTarget(address delegatedEoa) internal view returns (address implementation) {
        bytes memory code = delegatedEoa.code;
        require(code.length == 23, "invalid delegation indicator length");
        uint24 prefix;
        assembly ("memory-safe") {
            prefix := shr(232, mload(add(code, 32)))
            implementation := shr(96, mload(add(code, 35)))
        }
        require(prefix == 0xef0100, "invalid delegation indicator prefix");
    }

    /// @dev Views the fixture's upstream delegated EOA through the pinned account ABI.
    function _upstreamAccountView(UpstreamCompatibilityFixture storage compatibilityFixture)
        internal
        view
        returns (Simple7702Account)
    {
        return Simple7702Account(compatibilityFixture.upstream.delegatedEoa);
    }

    /// @dev Views the fixture's delegated EOA through the concrete DeFi Simplify ABI.
    function _defiSimplifyAccountView(DelegatedDefiSimplifyAccount storage accountUnderTest)
        internal
        view
        returns (DefiSimplify7702Account)
    {
        return DefiSimplify7702Account(accountUnderTest.delegatedEoa);
    }

    /// @dev Views the comparison fixture's DeFi Simplify EOA through its concrete ABI.
    function _defiSimplifyAccountView(UpstreamCompatibilityFixture storage compatibilityFixture)
        internal
        view
        returns (DefiSimplify7702Account)
    {
        return DefiSimplify7702Account(compatibilityFixture.defiSimplify.delegatedEoa);
    }

    /// @dev Views the same delegated EOA through the frozen dynamic-execution interface.
    function _dynamicExecutionInterfaceView(DelegatedDefiSimplifyAccount storage accountUnderTest)
        internal
        view
        returns (IDefiSimplify7702Account)
    {
        return IDefiSimplify7702Account(accountUnderTest.delegatedEoa);
    }

    /// @dev Views an explicitly supplied delegated EOA through the frozen dynamic interface.
    function _dynamicExecutionInterfaceView(address payable delegatedEoa)
        internal
        pure
        returns (IDefiSimplify7702Account)
    {
        return IDefiSimplify7702Account(delegatedEoa);
    }

    function _signature(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
