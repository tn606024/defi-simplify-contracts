// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DefiSimplify7702Account} from "../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../src/StaticCallUint256Assertions.sol";

/// @title DeployBaseV1_1Candidate
/// @notice Dry-runs the three Base v1.1.0 candidate deployments against the
///         pinned Arachnid Deterministic Deployment Proxy.
/// @dev The candidate manifest is treated as untrusted input: every initcode,
///      CREATE2 address, prerequisite runtime, and final direct runtime is
///      reconstructed or checked before the dry run succeeds. Broadcast and
///      resume contexts are deliberately rejected until a separately approved
///      live-deployment change removes the guard.
contract DeployBaseV1_1Candidate is Script {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";

    /// @notice The candidate-only script was invoked in a state-changing context.
    error CandidateBroadcastNotAuthorized();

    /// @notice The deployment script was run on a chain other than the manifest chain.
    /// @param expectedChainId Chain ID frozen by the candidate manifest.
    /// @param actualChainId Chain ID reported by the active RPC.
    error DeploymentChainMismatch(uint256 expectedChainId, uint256 actualChainId);

    /// @notice An on-chain prerequisite or dry-run artifact has unexpected runtime code.
    /// @param target Address whose runtime identity was checked.
    /// @param expectedHash Runtime code hash frozen by the candidate manifest.
    /// @param actualHash Runtime code hash observed in the active execution context.
    error DeploymentRuntimeCodeHashMismatch(address target, bytes32 expectedHash, bytes32 actualHash);

    /// @notice Reconstructed artifact initcode does not match the candidate manifest.
    /// @param contractName Human-readable artifact name.
    /// @param expectedHash Initcode hash frozen by the candidate manifest.
    /// @param actualHash Hash of the initcode reconstructed from the current build.
    error DeploymentInitcodeHashMismatch(string contractName, bytes32 expectedHash, bytes32 actualHash);

    /// @notice Independently predicted CREATE2 address does not match the candidate manifest.
    /// @param contractName Human-readable artifact name.
    /// @param expectedAddress Address frozen by the candidate manifest.
    /// @param actualAddress Address predicted from factory, salt, and initcode hash.
    error DeploymentAddressMismatch(string contractName, address expectedAddress, address actualAddress);

    /// @notice The Arachnid factory rejected an exact salt-plus-initcode dry-run payload.
    /// @param contractName Human-readable artifact name.
    /// @param reason Complete revert data returned by the factory.
    error FactoryDeploymentFailed(string contractName, bytes reason);

    struct ArtifactIdentity {
        string contractName;
        bytes32 salt;
        bytes32 initcodeHash;
        address expectedAddress;
        bytes32 runtimeCodeHash;
    }

    /// @notice Reproduces the three Base v1.1.0 deployment candidates in a dry run.
    /// @dev Invoke with the pinned Foundry release and omit `--broadcast`.
    /// @return account Expected and dry-run-verified account implementation address.
    /// @return flowAssertions Expected and dry-run-verified typed checker address.
    /// @return staticCallAssertions Expected and dry-run-verified generic checker address.
    function run() external returns (address account, address flowAssertions, address staticCallAssertions) {
        if (vmSafe.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vmSafe.isContext(VmSafe.ForgeContext.ScriptResume))
        {
            revert CandidateBroadcastNotAuthorized();
        }

        string memory manifest = vm.readFile(MANIFEST_PATH);
        (address factory, address entryPoint) = _requireDeploymentPrerequisites(manifest);
        _requireAllArtifactIdentities(manifest, factory, entryPoint);

        vm.startBroadcast();
        account = _deployAccount(manifest, factory, entryPoint);
        flowAssertions = _deployFlowAssertions(manifest, factory);
        staticCallAssertions = _deployStaticAssertions(manifest, factory);
        vm.stopBroadcast();

        console2.log("DefiSimplify7702Account candidate", account);
        console2.log("FlowAssertions candidate", flowAssertions);
        console2.log("StaticCallUint256Assertions candidate", staticCallAssertions);
    }

    /// @dev Verifies the active chain, factory runtime, and immutable EntryPoint runtime.
    /// @param manifest Complete candidate manifest JSON.
    /// @return factory Verified Arachnid deterministic deployment proxy.
    /// @return entryPoint Verified immutable account EntryPoint.
    function _requireDeploymentPrerequisites(string memory manifest)
        private
        view
        returns (address factory, address entryPoint)
    {
        uint256 expectedChainId = vm.parseJsonUint(manifest, ".network.chainId");
        if (block.chainid != expectedChainId) {
            revert DeploymentChainMismatch(expectedChainId, block.chainid);
        }

        factory = vm.parseJsonAddress(manifest, ".factory.address");
        _requireRuntimeCodeHash(factory, vm.parseJsonBytes32(manifest, ".factory.runtimeCodeHash"));
        entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");
        _requireRuntimeCodeHash(entryPoint, vm.parseJsonBytes32(manifest, ".entryPoint.runtimeCodeHash"));
    }

    /// @dev Rejects every stale initcode or address before recording dry-run calls.
    /// @param manifest Complete candidate manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param entryPoint Verified immutable account EntryPoint.
    function _requireAllArtifactIdentities(string memory manifest, address factory, address entryPoint) private pure {
        _requireArtifactIdentity(
            factory, _loadArtifactIdentity(manifest, "DefiSimplify7702Account"), _accountInitcode(entryPoint)
        );
        _requireArtifactIdentity(
            factory, _loadArtifactIdentity(manifest, "FlowAssertions"), type(FlowAssertions).creationCode
        );
        _requireArtifactIdentity(
            factory,
            _loadArtifactIdentity(manifest, "StaticCallUint256Assertions"),
            type(StaticCallUint256Assertions).creationCode
        );
    }

    /// @dev Dry-runs the account factory call after all artifacts pass prevalidation.
    /// @param manifest Complete candidate manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param entryPoint Verified immutable account EntryPoint.
    /// @return deployedAddress Expected address whose dry-run runtime was verified.
    function _deployAccount(string memory manifest, address factory, address entryPoint)
        private
        returns (address deployedAddress)
    {
        ArtifactIdentity memory identity = _loadArtifactIdentity(manifest, "DefiSimplify7702Account");
        _deployOrVerify(factory, identity, _accountInitcode(entryPoint));
        return identity.expectedAddress;
    }

    /// @dev Dry-runs the typed-checker factory call after prevalidation.
    /// @param manifest Complete candidate manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @return deployedAddress Expected address whose dry-run runtime was verified.
    function _deployFlowAssertions(string memory manifest, address factory) private returns (address deployedAddress) {
        ArtifactIdentity memory identity = _loadArtifactIdentity(manifest, "FlowAssertions");
        _deployOrVerify(factory, identity, type(FlowAssertions).creationCode);
        return identity.expectedAddress;
    }

    /// @dev Dry-runs the generic-checker factory call after prevalidation.
    /// @param manifest Complete candidate manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @return deployedAddress Expected address whose dry-run runtime was verified.
    function _deployStaticAssertions(string memory manifest, address factory)
        private
        returns (address deployedAddress)
    {
        ArtifactIdentity memory identity = _loadArtifactIdentity(manifest, "StaticCallUint256Assertions");
        _deployOrVerify(factory, identity, type(StaticCallUint256Assertions).creationCode);
        return identity.expectedAddress;
    }

    /// @dev Reconstructs account initcode with the sole immutable constructor argument.
    /// @param entryPoint Verified immutable account EntryPoint.
    /// @return initcode Complete account creation code and ABI-encoded constructor argument.
    function _accountInitcode(address entryPoint) private pure returns (bytes memory initcode) {
        return abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(entryPoint)));
    }

    /// @dev Loads one generated artifact identity from the candidate manifest.
    /// @param manifest Complete candidate manifest JSON.
    /// @param contractName Object key and human-readable artifact name.
    /// @return identity Salt, hashes, and expected address used by deployment checks.
    function _loadArtifactIdentity(string memory manifest, string memory contractName)
        private
        pure
        returns (ArtifactIdentity memory identity)
    {
        string memory root = string.concat(".artifacts.", contractName);
        identity = ArtifactIdentity({
            contractName: contractName,
            salt: vm.parseJsonBytes32(manifest, string.concat(root, ".salt.value")),
            initcodeHash: vm.parseJsonBytes32(manifest, string.concat(root, ".initcodeHash")),
            expectedAddress: vm.parseJsonAddress(manifest, string.concat(root, ".expectedAddress")),
            runtimeCodeHash: vm.parseJsonBytes32(manifest, string.concat(root, ".runtimeCodeHash"))
        });
    }

    /// @dev Recomputes the initcode hash and raw EIP-1014 address formula.
    /// @param factory Pinned Arachnid factory address.
    /// @param identity Candidate deployment identity for the selected artifact.
    /// @param initcode Reconstructed creation code and constructor arguments.
    function _requireArtifactIdentity(address factory, ArtifactIdentity memory identity, bytes memory initcode)
        private
        pure
    {
        bytes32 actualInitcodeHash = keccak256(initcode);
        if (actualInitcodeHash != identity.initcodeHash) {
            revert DeploymentInitcodeHashMismatch(identity.contractName, identity.initcodeHash, actualInitcodeHash);
        }

        address actualAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, identity.salt, actualInitcodeHash))))
        );
        if (actualAddress != identity.expectedAddress) {
            revert DeploymentAddressMismatch(identity.contractName, identity.expectedAddress, actualAddress);
        }
    }

    /// @dev Sends `salt || initcode` only when the predicted address is vacant,
    ///      then requires the exact expected direct-runtime identity.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param identity Candidate deployment identity for the selected artifact.
    /// @param initcode Reconstructed creation code and constructor arguments.
    function _deployOrVerify(address factory, ArtifactIdentity memory identity, bytes memory initcode) private {
        if (identity.expectedAddress.code.length == 0) {
            (bool success, bytes memory reason) = factory.call(abi.encodePacked(identity.salt, initcode));
            if (!success) {
                revert FactoryDeploymentFailed(identity.contractName, reason);
            }
        }

        _requireRuntimeCodeHash(identity.expectedAddress, identity.runtimeCodeHash);
    }

    /// @dev Requires nonempty runtime code whose `EXTCODEHASH` matches the manifest.
    /// @param target Prerequisite or dry-run-deployed artifact address.
    /// @param expectedHash Frozen expected runtime code hash.
    function _requireRuntimeCodeHash(address target, bytes32 expectedHash) private view {
        bytes32 actualHash = target.code.length == 0 ? bytes32(0) : target.codehash;
        if (actualHash != expectedHash) {
            revert DeploymentRuntimeCodeHashMismatch(target, expectedHash, actualHash);
        }
    }
}
