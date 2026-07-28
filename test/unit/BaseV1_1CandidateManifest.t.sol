// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title BaseV1_1CandidateManifestTest
/// @notice Independently reconstructs the unbroadcast v1.1 artifact identities
///         from the active 10,000-run Solidity build.
contract BaseV1_1CandidateManifestTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    address internal constant BASE_ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_CandidateManifest_RecordsUnreleasedIdentityWithoutDeploymentOrSecurityClaims() public view {
        assertEq(vm.parseJsonString(manifest, ".artifactVersion"), "v1.1.0", "artifact version");
        assertEq(vm.parseJsonString(manifest, ".manifestStatus"), "candidate", "manifest status");
        assertEq(vm.parseJsonString(manifest, ".intendedTrustLevel"), "official", "intended trust");
        assertEq(vm.parseJsonString(manifest, ".releaseStatus"), "unreleased", "release status");
        assertEq(vm.parseJsonString(manifest, ".network.deploymentStatus"), "not-broadcast", "deployment status");
        assertEq(vm.parseJsonString(manifest, ".security.status"), "unaudited", "security status");
        assertTrue(vm.parseJsonBool(manifest, ".security.experimental"), "experimental status");
        assertTrue(vm.parseJsonBool(manifest, ".security.independentAuditPlanned"), "audit plan");
        assertFalse(vm.parseJsonBool(manifest, ".security.securityGuarantee"), "security guarantee");
        assertTrue(vm.parseJsonBool(manifest, ".security.totalLossRisk"), "total-loss risk");
    }

    function test_CandidateManifest_DerivesEachVersionedSaltFromItsPreimage() public view {
        _assertSaltMatchesPreimage("DefiSimplify7702Account");
        _assertSaltMatchesPreimage("FlowAssertions");
        _assertSaltMatchesPreimage("StaticCallUint256Assertions");
    }

    function test_CandidateManifest_ReconstructsEveryInitcodeHashAndPredictedAddress() public view {
        _assertInitcodeAndAddress(
            "DefiSimplify7702Account",
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(BASE_ENTRY_POINT)))
        );
        _assertInitcodeAndAddress("FlowAssertions", type(FlowAssertions).creationCode);
        _assertInitcodeAndAddress("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);
    }

    function test_CandidateManifest_RuntimeHashesMatchCurrentDirectArtifacts() public {
        DefiSimplify7702Account account = new DefiSimplify7702Account(IEntryPoint(BASE_ENTRY_POINT));
        FlowAssertions flowAssertions = new FlowAssertions();
        StaticCallUint256Assertions staticAssertions = new StaticCallUint256Assertions();

        assertEq(
            address(account).codehash, _artifactBytes32("DefiSimplify7702Account", "runtimeCodeHash"), "account runtime"
        );
        assertEq(
            address(flowAssertions).codehash,
            _artifactBytes32("FlowAssertions", "runtimeCodeHash"),
            "FlowAssertions runtime"
        );
        assertEq(
            address(staticAssertions).codehash,
            _artifactBytes32("StaticCallUint256Assertions", "runtimeCodeHash"),
            "static assertions runtime"
        );
    }

    function test_CandidateManifest_RecordsPositiveEip170AndEip3860Headroom() public view {
        _assertCodeSizeHeadroom("DefiSimplify7702Account");
        _assertCodeSizeHeadroom("FlowAssertions");
        _assertCodeSizeHeadroom("StaticCallUint256Assertions");
    }

    function _assertSaltMatchesPreimage(string memory contractName) private view {
        string memory saltRoot = string.concat(".artifacts.", contractName, ".salt");
        string memory preimage = vm.parseJsonString(manifest, string.concat(saltRoot, ".preimage"));
        bytes32 salt = vm.parseJsonBytes32(manifest, string.concat(saltRoot, ".value"));
        assertEq(keccak256(bytes(preimage)), salt, string.concat(contractName, " salt"));
    }

    function _assertInitcodeAndAddress(string memory contractName, bytes memory initcode) private view {
        bytes32 initcodeHash = keccak256(initcode);
        assertEq(initcodeHash, _artifactBytes32(contractName, "initcodeHash"), string.concat(contractName, " initcode"));

        address factory = vm.parseJsonAddress(manifest, ".factory.address");
        bytes32 salt = _artifactBytes32(contractName, "salt.value");
        address predictedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initcodeHash)))));
        assertEq(
            predictedAddress,
            vm.parseJsonAddress(manifest, string.concat(".artifacts.", contractName, ".expectedAddress")),
            string.concat(contractName, " predicted address")
        );
    }

    function _assertCodeSizeHeadroom(string memory contractName) private view {
        string memory artifactRoot = string.concat(".artifacts.", contractName);
        uint256 runtimeSize = vm.parseJsonUint(manifest, string.concat(artifactRoot, ".runtimeCodeSize"));
        uint256 initcodeSize = vm.parseJsonUint(manifest, string.concat(artifactRoot, ".initcodeSize"));
        assertLt(runtimeSize, EIP_170_RUNTIME_LIMIT, string.concat(contractName, " EIP-170"));
        assertLt(initcodeSize, EIP_3860_INITCODE_LIMIT, string.concat(contractName, " EIP-3860"));
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".limits.runtimeCodeHeadroom")),
            EIP_170_RUNTIME_LIMIT - runtimeSize,
            string.concat(contractName, " runtime headroom")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".limits.initcodeHeadroom")),
            EIP_3860_INITCODE_LIMIT - initcodeSize,
            string.concat(contractName, " initcode headroom")
        );
    }

    function _artifactBytes32(string memory contractName, string memory field) private view returns (bytes32) {
        return vm.parseJsonBytes32(manifest, string.concat(".artifacts.", contractName, ".", field));
    }
}
