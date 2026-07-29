// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title BaseDeploymentCandidateManifestTest
/// @notice Independently reconstructs the active Base v1.1.0 candidate from
///         Solidity creation code without trusting the shell generator.
contract BaseDeploymentCandidateManifestTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";
    uint256 internal constant BASE_CHAIN_ID = 8453;
    address internal constant BASE_ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    address private constant RETIRED_ACCOUNT = 0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA;
    address private constant RETIRED_FLOW_ASSERTIONS = 0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5;
    address private constant RETIRED_STATIC_ASSERTIONS = 0x034ee940A644323463AB074DCA99504BF5a666EA;

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_CandidateManifest_BindsActiveBuildWithoutClaimingDeploymentTrustOrRelease() public view {
        assertEq(vm.parseJsonUint(manifest, ".schemaVersion"), 1, "schema version");
        assertEq(vm.parseJsonString(manifest, ".manifestStatus"), "candidate", "manifest status");
        assertEq(vm.parseJsonString(manifest, ".releaseVersion"), "v1.1.0", "candidate version");
        assertEq(vm.parseJsonString(manifest, ".releaseStatus"), "unreleased", "release status");
        assertEq(vm.parseJsonString(manifest, ".intendedTrustLevel"), "official", "intended trust");
        assertFalse(vm.keyExistsJson(manifest, ".trustLevel"), "assigned trust must be omitted");
        assertFalse(vm.keyExistsJson(manifest, ".deployment"), "deployment evidence must be omitted");

        assertEq(vm.parseJsonUint(manifest, ".network.chainId"), BASE_CHAIN_ID, "Base chain ID");
        assertEq(
            vm.parseJsonString(manifest, ".network.deploymentStatus"), "not-broadcast", "network deployment status"
        );
        assertEq(vm.parseJsonString(manifest, ".security.status"), "unaudited", "security status");
        assertTrue(vm.parseJsonBool(manifest, ".security.experimental"), "experimental status");
        assertFalse(vm.parseJsonBool(manifest, ".security.independentAuditCompleted"), "independent audit completion");
        assertFalse(vm.parseJsonBool(manifest, ".security.securityGuarantee"), "security guarantee");
        assertEq(vm.parseJsonString(manifest, ".security.warranty"), "none", "warranty");
        assertTrue(vm.parseJsonBool(manifest, ".security.totalLossRisk"), "total-loss risk");
        assertEq(vm.parseJsonString(manifest, ".sdkIntegrationStatus"), "not-integrated", "SDK status");
    }

    function test_CandidateManifest_FreezesReviewedArtifactSourceCommitAndTree() public view {
        assertEq(
            vm.parseJsonString(manifest, ".artifactSource.commit"),
            "ab073f845af86d130792baef6f4981be3c36781b",
            "artifact source commit"
        );
        assertEq(
            vm.parseJsonString(manifest, ".artifactSource.tree"),
            "953b1a3269f76352cbbb6cf3d27bcb366c79804b",
            "artifact source tree"
        );
        assertEq(vm.parseJsonUint(manifest, ".build.optimizerRuns"), 10_000, "optimizer runs");
    }

    function test_CandidateManifest_DerivesDistinctSaltsFromVersionedPreimages() public view {
        bytes32 accountSalt = _assertSaltMatchesPreimage("DefiSimplify7702Account");
        bytes32 flowAssertionsSalt = _assertSaltMatchesPreimage("FlowAssertions");
        bytes32 staticAssertionsSalt = _assertSaltMatchesPreimage("StaticCallUint256Assertions");

        assertNotEq(accountSalt, flowAssertionsSalt, "account and typed-checker salts");
        assertNotEq(accountSalt, staticAssertionsSalt, "account and generic-checker salts");
        assertNotEq(flowAssertionsSalt, staticAssertionsSalt, "checker salts");
    }

    function test_CandidateManifest_ReconstructsAccountInitcodeAndCreate2Address() public view {
        bytes memory initcode =
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(BASE_ENTRY_POINT)));
        _assertInitcodeAndAddress("DefiSimplify7702Account", initcode, RETIRED_ACCOUNT);

        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.DefiSimplify7702Account.constructor.arguments"),
            abi.encode(BASE_ENTRY_POINT),
            "account constructor arguments"
        );
    }

    function test_CandidateManifest_ReconstructsFlowAssertionsInitcodeAndCreate2Address() public view {
        _assertInitcodeAndAddress("FlowAssertions", type(FlowAssertions).creationCode, RETIRED_FLOW_ASSERTIONS);
        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.FlowAssertions.constructor.arguments"),
            bytes(""),
            "FlowAssertions constructor arguments"
        );
    }

    function test_CandidateManifest_ReconstructsStaticAssertionsInitcodeAndCreate2Address() public view {
        _assertInitcodeAndAddress(
            "StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode, RETIRED_STATIC_ASSERTIONS
        );
        assertEq(
            vm.parseJsonBytes(manifest, ".artifacts.StaticCallUint256Assertions.constructor.arguments"),
            bytes(""),
            "StaticCallUint256Assertions constructor arguments"
        );
    }

    function test_CandidateManifest_RuntimeHashesMatchDirectImmutableDeployments() public {
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

    /// @dev Proves one candidate salt is reviewable versioned text rather than
    ///      an unexplained value.
    function _assertSaltMatchesPreimage(string memory contractName) private view returns (bytes32 recordedSalt) {
        string memory saltRoot = string.concat(".artifacts.", contractName, ".salt");
        string memory preimage = vm.parseJsonString(manifest, string.concat(saltRoot, ".preimage"));
        recordedSalt = vm.parseJsonBytes32(manifest, string.concat(saltRoot, ".value"));
        assertEq(keccak256(bytes(preimage)), recordedSalt, string.concat(contractName, " salt"));
    }

    /// @dev Recomputes the complete initcode hash and raw EIP-1014 address, then
    ///      proves the candidate does not relabel a retired v1.0.0 address.
    function _assertInitcodeAndAddress(string memory contractName, bytes memory initcode, address retiredAddress)
        private
        view
    {
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
        assertNotEq(predictedAddress, retiredAddress, string.concat(contractName, " retired address reuse"));

        string memory artifactRoot = string.concat(".artifacts.", contractName);
        assertEq(
            vm.parseJsonString(manifest, string.concat(artifactRoot, ".deploymentStatus")),
            "not-broadcast",
            string.concat(contractName, " deployment status")
        );
        assertFalse(vm.keyExistsJson(manifest, string.concat(artifactRoot, ".address")), "deployed address omitted");
        assertFalse(
            vm.keyExistsJson(manifest, string.concat(artifactRoot, ".deploymentTransactionHash")),
            "deployment transaction omitted"
        );
        assertFalse(
            vm.keyExistsJson(manifest, string.concat(artifactRoot, ".verificationUrl")), "verification URL omitted"
        );
    }

    function _artifactAddress(string memory contractName, string memory field) private view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".artifacts.", contractName, ".", field));
    }

    function _artifactBytes32(string memory contractName, string memory field) private view returns (bytes32) {
        return vm.parseJsonBytes32(manifest, string.concat(".artifacts.", contractName, ".", field));
    }
}
