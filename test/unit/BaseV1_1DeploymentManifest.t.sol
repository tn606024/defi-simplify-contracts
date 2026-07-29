// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title BaseV1_1DeploymentManifestTest
/// @notice Independently binds the Base v1.1.0 deployment evidence to the
///         frozen direct artifact family and exact BaseScan verification
///         without claiming trust, release, SDK readiness, or an audit.
contract BaseV1_1DeploymentManifestTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1.json";
    uint256 internal constant BASE_CHAIN_ID = 8453;
    address internal constant BASE_ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    address internal constant DEPLOYER = 0xb5FD9f60Fc6ca7662Ff22D09ec7832CD221fbcdD;

    bytes32 private constant ACCOUNT_TRANSACTION = 0x9256cd73512476ad7ec3e955bbeb91d9b9f8d34d2c26aaafec0d18f4d4c80855;
    bytes32 private constant FLOW_ASSERTIONS_TRANSACTION =
        0x93604354100fef930e19b8924b624c8b1044d2360cbf62cd28aadba6437d22c6;
    bytes32 private constant STATIC_ASSERTIONS_TRANSACTION =
        0x944c827a13313750bd6ee282c2424a576b57bce73026bf31abcac34b7fbb9900;

    bytes32 private constant ACCOUNT_BLOCK_HASH = 0x82e43677f62d1c2219a3aedd50cf8993031836e7790ca86f5b0a720dc9729ee8;
    bytes32 private constant FLOW_ASSERTIONS_BLOCK_HASH =
        0xf09e25e511cccad6f22b2c9fd2c4b78342499df84d000e5cd820a3ba2df64e18;
    bytes32 private constant STATIC_ASSERTIONS_BLOCK_HASH =
        0xe89b143ca2cbda3d626d40555e534066833586ad9321b22a81b78ffcf098e7f9;

    bytes32 private constant ACCOUNT_CALLDATA_HASH = 0xa751ece8c234412457665221945a59f49302c9b789dcc3f2f7d0f8ca24111229;
    bytes32 private constant FLOW_ASSERTIONS_CALLDATA_HASH =
        0x2368b45d470c348226355a567312d939be401eb261beb26725b9bb3dae69fedf;
    bytes32 private constant STATIC_ASSERTIONS_CALLDATA_HASH =
        0x455a14a432c2885e3be76d3d48287662a241b026c3e615292d5a757e43f3a795;

    string private constant ACCOUNT_VERIFICATION_URL =
        "https://basescan.org/address/0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69#code";
    string private constant FLOW_ASSERTIONS_VERIFICATION_URL =
        "https://basescan.org/address/0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16#code";
    string private constant STATIC_ASSERTIONS_VERIFICATION_URL =
        "https://basescan.org/address/0x28734029a24448cAA307D286823cA21DC57e8393#code";

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_DeploymentManifest_RecordsMinedStateWithoutOverclaimingExternalGates() public view {
        assertEq(vm.parseJsonUint(manifest, ".schemaVersion"), 1, "schema version");
        assertEq(vm.parseJsonString(manifest, ".manifestStatus"), "deployed", "manifest status");
        assertEq(vm.parseJsonString(manifest, ".releaseVersion"), "v1.1.0", "release version");
        assertEq(vm.parseJsonString(manifest, ".releaseStatus"), "unreleased", "release status");
        assertEq(vm.parseJsonString(manifest, ".verificationStatus"), "exact-match", "verification status");
        assertEq(vm.parseJsonString(manifest, ".intendedTrustLevel"), "official", "intended trust");
        assertFalse(vm.keyExistsJson(manifest, ".trustLevel"), "assigned trust must be omitted");

        assertEq(vm.parseJsonUint(manifest, ".network.chainId"), BASE_CHAIN_ID, "Base chain ID");
        assertEq(vm.parseJsonString(manifest, ".network.deploymentStatus"), "deployed", "network deployment status");
        assertEq(vm.parseJsonAddress(manifest, ".deployment.deployerAddress"), DEPLOYER, "deployment EOA");
        assertEq(vm.parseJsonUint(manifest, ".deployment.totalObservedFeeWei"), 21_190_994_086_480, "total fee");

        assertEq(vm.parseJsonString(manifest, ".security.status"), "unaudited", "security status");
        assertTrue(vm.parseJsonBool(manifest, ".security.experimental"), "experimental status");
        assertFalse(vm.parseJsonBool(manifest, ".security.independentAuditCompleted"), "independent audit completion");
        assertFalse(vm.parseJsonBool(manifest, ".security.securityGuarantee"), "security guarantee");
        assertEq(vm.parseJsonString(manifest, ".security.warranty"), "none", "warranty");
        assertTrue(vm.parseJsonBool(manifest, ".security.totalLossRisk"), "total-loss risk");
        assertEq(vm.parseJsonString(manifest, ".sdkIntegrationStatus"), "not-integrated", "SDK status");
    }

    function test_DeploymentManifest_RecordsExactTransactionAndReceiptEvidence() public view {
        _assertDeploymentEvidence(
            "DefiSimplify7702Account",
            ACCOUNT_TRANSACTION,
            49_268_705,
            ACCOUNT_BLOCK_HASH,
            44,
            ACCOUNT_CALLDATA_HASH,
            2_665_587,
            6_000_000,
            28_993_318_008,
            16_022_515_318_008,
            ACCOUNT_VERIFICATION_URL
        );
        _assertDeploymentEvidence(
            "FlowAssertions",
            FLOW_ASSERTIONS_TRANSACTION,
            49_268_853,
            FLOW_ASSERTIONS_BLOCK_HASH,
            45,
            FLOW_ASSERTIONS_CALLDATA_HASH,
            527_397,
            6_000_000,
            5_556_565_266,
            3_169_938_565_266,
            FLOW_ASSERTIONS_VERIFICATION_URL
        );
        _assertDeploymentEvidence(
            "StaticCallUint256Assertions",
            STATIC_ASSERTIONS_TRANSACTION,
            49_268_875,
            STATIC_ASSERTIONS_BLOCK_HASH,
            46,
            STATIC_ASSERTIONS_CALLDATA_HASH,
            398_346,
            5_005_043,
            4_801_344_328,
            1_998_540_203_206,
            STATIC_ASSERTIONS_VERIFICATION_URL
        );
    }

    function test_DeploymentManifest_ReconstructsFrozenCreate2AndDirectRuntimeIdentities() public {
        bytes memory accountInitcode =
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(BASE_ENTRY_POINT)));
        _assertInitcodeAndAddress("DefiSimplify7702Account", accountInitcode);
        _assertInitcodeAndAddress("FlowAssertions", type(FlowAssertions).creationCode);
        _assertInitcodeAndAddress("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);

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
            "typed-checker direct-runtime hash"
        );
        assertEq(
            address(staticAssertions).codehash,
            _artifactBytes32("StaticCallUint256Assertions", "runtimeCodeHash"),
            "generic-checker direct-runtime hash"
        );
    }

    function _assertDeploymentEvidence(
        string memory contractName,
        bytes32 transactionHash,
        uint256 blockNumber,
        bytes32 blockHash,
        uint256 nonce,
        bytes32 calldataHash,
        uint256 gasUsed,
        uint256 effectiveGasPriceWei,
        uint256 l1FeeWei,
        uint256 observedTotalFeeWei,
        string memory verificationUrl
    ) private view {
        string memory artifactRoot = string.concat(".artifacts.", contractName);
        assertEq(
            vm.parseJsonString(manifest, string.concat(artifactRoot, ".deploymentStatus")),
            "deployed",
            string.concat(contractName, " deployment status")
        );
        assertEq(
            _artifactAddress(contractName, "address"),
            _artifactAddress(contractName, "expectedAddress"),
            string.concat(contractName, " deployed address")
        );
        assertEq(
            _artifactBytes32(contractName, "deploymentTransactionHash"),
            transactionHash,
            string.concat(contractName, " transaction")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".deploymentBlockNumber")),
            blockNumber,
            string.concat(contractName, " block")
        );
        assertEq(
            _artifactBytes32(contractName, "deploymentBlockHash"), blockHash, string.concat(contractName, " block hash")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".deploymentNonce")),
            nonce,
            string.concat(contractName, " nonce")
        );
        assertEq(
            _artifactBytes32(contractName, "deploymentCalldataKeccak256"),
            calldataHash,
            string.concat(contractName, " calldata")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".receiptStatus")),
            1,
            string.concat(contractName, " receipt")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".gasUsed")),
            gasUsed,
            string.concat(contractName, " gas used")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".effectiveGasPriceWei")),
            effectiveGasPriceWei,
            string.concat(contractName, " effective gas price")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".l1FeeWei")),
            l1FeeWei,
            string.concat(contractName, " L1 fee")
        );
        assertEq(
            vm.parseJsonUint(manifest, string.concat(artifactRoot, ".observedTotalFeeWei")),
            observedTotalFeeWei,
            string.concat(contractName, " total fee")
        );
        assertEq(
            vm.parseJsonString(manifest, string.concat(artifactRoot, ".verificationStatus")),
            "exact-match",
            string.concat(contractName, " verification status")
        );
        assertEq(
            vm.parseJsonString(manifest, string.concat(artifactRoot, ".verificationUrl")),
            verificationUrl,
            string.concat(contractName, " verification URL")
        );
    }

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
        assertEq(
            _artifactAddress(contractName, "address"),
            predictedAddress,
            string.concat(contractName, " deployed address")
        );
    }

    function _artifactAddress(string memory contractName, string memory field) private view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".artifacts.", contractName, ".", field));
    }

    function _artifactBytes32(string memory contractName, string memory field) private view returns (bytes32) {
        return vm.parseJsonBytes32(manifest, string.concat(".artifacts.", contractName, ".", field));
    }
}
