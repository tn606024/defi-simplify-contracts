// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title BaseDeploymentManifestTest
/// @notice Independently reconstructs every candidate deployment identity from
///         Solidity creation code rather than trusting the manifest generator.
contract BaseDeploymentManifestTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.candidate.json";
    uint256 internal constant BASE_CHAIN_ID = 8453;
    address internal constant BASE_ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_CandidateManifest_LabelsDeploymentAndSecurityStatusWithoutOverclaiming() public view {
        assertEq(vm.parseJsonUint(manifest, ".schemaVersion"), 1, "schema version");
        assertEq(vm.parseJsonString(manifest, ".manifestStatus"), "candidate", "manifest status");
        assertEq(vm.parseJsonString(manifest, ".intendedTrustLevel"), "official", "intended trust level");
        assertEq(vm.parseJsonUint(manifest, ".network.chainId"), BASE_CHAIN_ID, "Base chain ID");
        assertEq(
            vm.parseJsonString(manifest, ".network.deploymentStatus"), "not-broadcast", "network deployment status"
        );
        assertEq(vm.parseJsonString(manifest, ".security.status"), "unaudited", "security status");
        assertTrue(vm.parseJsonBool(manifest, ".security.experimental"), "experimental status");
        assertFalse(vm.parseJsonBool(manifest, ".security.independentAuditPlanned"), "independent audit status");
        assertEq(vm.parseJsonString(manifest, ".sdkIntegrationStatus"), "not-integrated", "SDK status");
    }

    function test_CandidateManifest_DerivesEachSaltFromItsDocumentedPreimage() public view {
        _assertSaltMatchesPreimage("DefiSimplify7702Account");
        _assertSaltMatchesPreimage("FlowAssertions");
        _assertSaltMatchesPreimage("StaticCallUint256Assertions");
    }

    function test_CandidateManifest_ReconstructsAccountInitcodeAndCreate2Address() public view {
        bytes memory initcode =
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(BASE_ENTRY_POINT)));
        _assertInitcodeAndAddress("DefiSimplify7702Account", initcode);

        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.DefiSimplify7702Account.constructor.arguments"),
            abi.encode(BASE_ENTRY_POINT),
            "account constructor arguments"
        );
    }

    function test_CandidateManifest_ReconstructsFlowAssertionsInitcodeAndCreate2Address() public view {
        _assertInitcodeAndAddress("FlowAssertions", type(FlowAssertions).creationCode);
        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.FlowAssertions.constructor.arguments"),
            bytes(""),
            "FlowAssertions constructor arguments"
        );
    }

    function test_CandidateManifest_ReconstructsStaticAssertionsInitcodeAndCreate2Address() public view {
        _assertInitcodeAndAddress("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);
        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.StaticCallUint256Assertions.constructor.arguments"),
            bytes(""),
            "StaticCallUint256Assertions constructor arguments"
        );
    }

    function test_CandidateManifest_RuntimeHashesMatchDirectDeployments() public {
        DefiSimplify7702Account account = new DefiSimplify7702Account(IEntryPoint(BASE_ENTRY_POINT));
        FlowAssertions flowAssertions = new FlowAssertions();
        StaticCallUint256Assertions staticAssertions = new StaticCallUint256Assertions();

        assertEq(
            address(account).codehash,
            _artifactBytes32("DefiSimplify7702Account", "runtimeCodeHash"),
            "account direct-runtime hash"
        );
        assertEq(
            address(flowAssertions).codehash,
            _artifactBytes32("FlowAssertions", "runtimeCodeHash"),
            "FlowAssertions direct-runtime hash"
        );
        assertEq(
            address(staticAssertions).codehash,
            _artifactBytes32("StaticCallUint256Assertions", "runtimeCodeHash"),
            "StaticCallUint256Assertions direct-runtime hash"
        );
    }

    /// @dev Proves the salt is reviewable text with a frozen hash, not an
    ///      unexplained magic value.
    function _assertSaltMatchesPreimage(string memory contractName) private view {
        string memory saltRoot = string.concat(".artifacts.", contractName, ".salt");
        string memory preimage = vm.parseJsonString(manifest, string.concat(saltRoot, ".preimage"));
        bytes32 recordedSalt = vm.parseJsonBytes32(manifest, string.concat(saltRoot, ".value"));
        assertEq(keccak256(bytes(preimage)), recordedSalt, string.concat(contractName, " salt"));
    }

    /// @dev Recomputes both the complete initcode hash and raw EIP-1014 address
    ///      formula so the test is independent of the shell generator and Cast.
    function _assertInitcodeAndAddress(string memory contractName, bytes memory initcode) private view {
        bytes32 initcodeHash = keccak256(initcode);
        assertEq(
            initcodeHash, _artifactBytes32(contractName, "initcodeHash"), string.concat(contractName, " initcode hash")
        );

        address factory = vm.parseJsonAddress(manifest, ".factory.address");
        bytes32 salt = _artifactBytes32(contractName, "salt.value");
        address predictedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initcodeHash)))));
        assertEq(
            predictedAddress,
            _artifactAddress(contractName, "expectedAddress"),
            string.concat(contractName, " CREATE2 address")
        );
    }

    function _artifactAddress(string memory contractName, string memory field) private view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".artifacts.", contractName, ".", field));
    }

    function _artifactBytes32(string memory contractName, string memory field) private view returns (bytes32) {
        return vm.parseJsonBytes32(manifest, string.concat(".artifacts.", contractName, ".", field));
    }
}
