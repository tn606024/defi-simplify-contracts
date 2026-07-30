// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title Retired Base v1.0 Deployment Factory Fork Tests
/// @notice Retains the historical v1.0 manifest's factory, initcode, address, and runtime evidence
///         against Base inside a local fork. These retired addresses are not deployments of the
///         active v1.1 bytecode, and this suite never broadcasts.
contract BaseDeploymentFactoryTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.json";

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_BaseDeploymentPrerequisites_HaveFrozenRuntimeIdentities() public view {
        assertEq(block.chainid, vm.parseJsonUint(manifest, ".network.chainId"), "Base chain");

        address factory = vm.parseJsonAddress(manifest, ".factory.address");
        assertGt(factory.code.length, 0, "factory runtime missing");
        assertEq(factory.codehash, vm.parseJsonBytes32(manifest, ".factory.runtimeCodeHash"), "factory runtime hash");

        address entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");
        assertGt(entryPoint.code.length, 0, "EntryPoint runtime missing");
        assertEq(
            entryPoint.codehash, vm.parseJsonBytes32(manifest, ".entryPoint.runtimeCodeHash"), "EntryPoint runtime hash"
        );
    }

    /// @dev Given the historical manifest and current fork state. When each frozen v1.0 payload is
    ///      reconstructed, the suite verifies an existing historical runtime or deploys it only on
    ///      a vacant disposable fork address, then requires the exact direct runtime hash.
    function test_BaseFactory_OfficialPayloadsResolveToExactDirectRuntimes() public {
        address entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");

        _deployOrVerifyOnFork(
            "DefiSimplify7702Account",
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(entryPoint)))
        );
        _deployOrVerifyOnFork("FlowAssertions", type(FlowAssertions).creationCode);
        _deployOrVerifyOnFork("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);
    }

    /// @dev Verifies an existing historical Base runtime. The vacancy branch
    ///      preserves the same disposable-fork proof for an equivalent
    ///      chain state without broadcasting a transaction.
    function _deployOrVerifyOnFork(string memory contractName, bytes memory initcode) private {
        string memory artifactRoot = string.concat(".artifacts.", contractName);
        bytes32 expectedInitcodeHash = vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".initcodeHash"));
        assertEq(keccak256(initcode), expectedInitcodeHash, string.concat(contractName, " initcode hash"));

        address expectedAddress = vm.parseJsonAddress(manifest, string.concat(artifactRoot, ".expectedAddress"));
        if (expectedAddress.code.length == 0) {
            address factory = vm.parseJsonAddress(manifest, ".factory.address");
            bytes32 salt = vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".salt.value"));
            (bool success, bytes memory reason) = factory.call(abi.encodePacked(salt, initcode));
            assertTrue(success, string.concat(contractName, " factory deployment failed"));
            assertEq(reason.length, 20, string.concat(contractName, " factory return length"));
        }

        assertGt(expectedAddress.code.length, 0, string.concat(contractName, " runtime missing"));
        assertEq(
            expectedAddress.codehash,
            vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".runtimeCodeHash")),
            string.concat(contractName, " direct-runtime hash")
        );
    }
}
