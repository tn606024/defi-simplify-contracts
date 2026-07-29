// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DefiSimplify7702Account} from "../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../src/StaticCallUint256Assertions.sol";
import {DeterministicDeployment} from "./libraries/DeterministicDeployment.sol";

/// @title BaseDeployment
/// @notice Version-independent deployment engine for the DeFi Simplify account
///         and checker artifact family on Base.
/// @dev Version adapters supply only their manifest and execution policy. The
///      engine validates all identities before recording factory calls.
abstract contract BaseDeployment is Script {
    /// @notice The deployment script was run on a chain other than the manifest chain.
    /// @param expectedChainId Chain ID frozen by the deployment manifest.
    /// @param actualChainId Chain ID reported by the active RPC.
    error DeploymentChainMismatch(uint256 expectedChainId, uint256 actualChainId);

    /// @notice The Arachnid factory rejected an exact salt-plus-initcode deployment payload.
    /// @param contractName Human-readable artifact name.
    /// @param reason Complete revert data returned by the factory.
    error FactoryDeploymentFailed(string contractName, bytes reason);

    /// @notice Reproduces or deploys the three manifest-bound artifact identities.
    /// @dev The version adapter authorizes the execution context and chooses the
    ///      broadcast sender before any factory call is recorded.
    /// @return account Expected and runtime-verified account implementation address.
    /// @return flowAssertions Expected and runtime-verified typed checker address.
    /// @return staticCallAssertions Expected and runtime-verified generic checker address.
    function run() external returns (address account, address flowAssertions, address staticCallAssertions) {
        _authorizeExecutionContext();

        string memory manifest = vm.readFile(_manifestPath());
        (address factory, address entryPoint) = _requireDeploymentPrerequisites(manifest);
        _requireAllArtifactIdentities(manifest, factory, entryPoint);

        _startBroadcast();
        account = _deployAccount(manifest, factory, entryPoint);
        flowAssertions = _deployFlowAssertions(manifest, factory);
        staticCallAssertions = _deployStaticAssertions(manifest, factory);
        vm.stopBroadcast();

        console2.log(string.concat("DefiSimplify7702Account ", _executionLabel()), account);
        console2.log(string.concat("FlowAssertions ", _executionLabel()), flowAssertions);
        console2.log(string.concat("StaticCallUint256Assertions ", _executionLabel()), staticCallAssertions);
    }

    /// @dev Returns the version-specific deployment manifest path.
    /// @return manifestPath Repository-relative reviewed manifest path.
    function _manifestPath() internal pure virtual returns (string memory manifestPath);

    /// @dev Authorizes the current Forge execution context before manifest reads.
    function _authorizeExecutionContext() internal view virtual;

    /// @dev Starts recording factory calls with the version adapter's sender policy.
    function _startBroadcast() internal virtual;

    /// @dev Returns the concise label used in script output.
    /// @return label Human-readable execution mode.
    function _executionLabel() internal pure virtual returns (string memory label);

    /// @dev Verifies the active chain, factory runtime, and immutable EntryPoint runtime.
    /// @param manifest Complete deployment manifest JSON.
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
        DeterministicDeployment.requireRuntimeCodeHash(
            factory, vm.parseJsonBytes32(manifest, ".factory.runtimeCodeHash")
        );
        entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");
        DeterministicDeployment.requireRuntimeCodeHash(
            entryPoint, vm.parseJsonBytes32(manifest, ".entryPoint.runtimeCodeHash")
        );
    }

    /// @dev Rejects every stale initcode or address before recording factory calls.
    /// @param manifest Complete deployment manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param entryPoint Verified immutable account EntryPoint.
    function _requireAllArtifactIdentities(string memory manifest, address factory, address entryPoint) private pure {
        DeterministicDeployment.requireArtifactIdentity(
            factory, _loadArtifactIdentity(manifest, "DefiSimplify7702Account"), _accountInitcode(entryPoint)
        );
        DeterministicDeployment.requireArtifactIdentity(
            factory, _loadArtifactIdentity(manifest, "FlowAssertions"), type(FlowAssertions).creationCode
        );
        DeterministicDeployment.requireArtifactIdentity(
            factory,
            _loadArtifactIdentity(manifest, "StaticCallUint256Assertions"),
            type(StaticCallUint256Assertions).creationCode
        );
    }

    /// @dev Runs the account factory call after all artifacts pass prevalidation.
    /// @param manifest Complete deployment manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param entryPoint Verified immutable account EntryPoint.
    /// @return deployedAddress Expected address whose runtime was verified.
    function _deployAccount(string memory manifest, address factory, address entryPoint)
        private
        returns (address deployedAddress)
    {
        DeterministicDeployment.ArtifactIdentity memory identity =
            _loadArtifactIdentity(manifest, "DefiSimplify7702Account");
        _deployOrVerify(factory, identity, _accountInitcode(entryPoint));
        return identity.expectedAddress;
    }

    /// @dev Runs the typed-checker factory call after prevalidation.
    /// @param manifest Complete deployment manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @return deployedAddress Expected address whose runtime was verified.
    function _deployFlowAssertions(string memory manifest, address factory) private returns (address deployedAddress) {
        DeterministicDeployment.ArtifactIdentity memory identity = _loadArtifactIdentity(manifest, "FlowAssertions");
        _deployOrVerify(factory, identity, type(FlowAssertions).creationCode);
        return identity.expectedAddress;
    }

    /// @dev Runs the generic-checker factory call after prevalidation.
    /// @param manifest Complete deployment manifest JSON.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @return deployedAddress Expected address whose runtime was verified.
    function _deployStaticAssertions(string memory manifest, address factory)
        private
        returns (address deployedAddress)
    {
        DeterministicDeployment.ArtifactIdentity memory identity =
            _loadArtifactIdentity(manifest, "StaticCallUint256Assertions");
        _deployOrVerify(factory, identity, type(StaticCallUint256Assertions).creationCode);
        return identity.expectedAddress;
    }

    /// @dev Reconstructs account initcode with the sole immutable constructor argument.
    /// @param entryPoint Verified immutable account EntryPoint.
    /// @return initcode Complete account creation code and ABI-encoded constructor argument.
    function _accountInitcode(address entryPoint) private pure returns (bytes memory initcode) {
        return abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(entryPoint)));
    }

    /// @dev Loads one artifact identity from a versioned deployment manifest.
    /// @param manifest Complete deployment manifest JSON.
    /// @param contractName Object key and human-readable artifact name.
    /// @return identity Salt, hashes, and expected address used by deployment checks.
    function _loadArtifactIdentity(string memory manifest, string memory contractName)
        private
        pure
        returns (DeterministicDeployment.ArtifactIdentity memory identity)
    {
        string memory root = string.concat(".artifacts.", contractName);
        identity = DeterministicDeployment.ArtifactIdentity({
            contractName: contractName,
            salt: vm.parseJsonBytes32(manifest, string.concat(root, ".salt.value")),
            initcodeHash: vm.parseJsonBytes32(manifest, string.concat(root, ".initcodeHash")),
            expectedAddress: vm.parseJsonAddress(manifest, string.concat(root, ".expectedAddress")),
            runtimeCodeHash: vm.parseJsonBytes32(manifest, string.concat(root, ".runtimeCodeHash"))
        });
    }

    /// @dev Sends `salt || initcode` only when the predicted address is vacant,
    ///      then requires the exact expected direct-runtime identity.
    /// @param factory Verified Arachnid deterministic deployment proxy.
    /// @param identity Manifest identity for the selected artifact.
    /// @param initcode Reconstructed creation code and constructor arguments.
    function _deployOrVerify(
        address factory,
        DeterministicDeployment.ArtifactIdentity memory identity,
        bytes memory initcode
    ) private {
        if (identity.expectedAddress.code.length == 0) {
            (bool success, bytes memory reason) = factory.call(abi.encodePacked(identity.salt, initcode));
            if (!success) {
                revert FactoryDeploymentFailed(identity.contractName, reason);
            }
        }

        DeterministicDeployment.requireRuntimeCodeHash(identity.expectedAddress, identity.runtimeCodeHash);
    }
}

/// @title BaseDeploymentCandidate
/// @notice Reusable non-broadcast execution policy for versioned candidates.
abstract contract BaseDeploymentCandidate is BaseDeployment {
    /// @notice A candidate-only script was invoked in a state-changing context.
    error CandidateBroadcastNotAuthorized();

    /// @inheritdoc BaseDeployment
    function _authorizeExecutionContext() internal view virtual override {
        if (vmSafe.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vmSafe.isContext(VmSafe.ForgeContext.ScriptResume))
        {
            revert CandidateBroadcastNotAuthorized();
        }
    }

    /// @inheritdoc BaseDeployment
    function _startBroadcast() internal virtual override {
        vm.startBroadcast();
    }

    /// @inheritdoc BaseDeployment
    function _executionLabel() internal pure virtual override returns (string memory label) {
        return "candidate";
    }
}

/// @title BaseDeploymentLive
/// @notice Reusable public-deployer and explicit-approval execution policy for
///         versioned live deployments.
abstract contract BaseDeploymentLive is BaseDeployment {
    /// @notice The configured public deployment sender is missing.
    error LiveDeploymentDeployerRequired();

    /// @notice A live Forge context lacks the exact issue-scoped approval phrase.
    error LiveDeploymentApprovalRequired();

    /// @dev Returns the environment variable containing the public deployer.
    /// @return environmentVariable Name of the public-deployer environment variable.
    function _deployerEnvironmentVariable() internal pure virtual returns (string memory environmentVariable);

    /// @dev Returns the environment variable containing the approval guard.
    /// @return environmentVariable Name of the approval environment variable.
    function _approvalEnvironmentVariable() internal pure virtual returns (string memory environmentVariable);

    /// @dev Returns the exact issue-scoped approval phrase.
    /// @return approvalPhrase Required approval guard value.
    function _approvalPhrase() internal pure virtual returns (string memory approvalPhrase);

    /// @inheritdoc BaseDeployment
    function _authorizeExecutionContext() internal view virtual override {
        address deployer = vm.envOr(_deployerEnvironmentVariable(), address(0));
        _requirePublicDeployer(deployer);

        if (vmSafe.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vmSafe.isContext(VmSafe.ForgeContext.ScriptResume))
        {
            _requireLiveApproval();
        }
    }

    /// @dev Requires the exact issue-scoped phrase before a live or resumed run.
    function _requireLiveApproval() internal view {
        string memory approval = vm.envOr(_approvalEnvironmentVariable(), string(""));
        _requireLiveApprovalValue(approval);
    }

    /// @dev Rejects a missing public sender before any manifest or RPC work.
    /// @param deployer Configured public deployment sender.
    function _requirePublicDeployer(address deployer) internal pure {
        if (deployer == address(0)) {
            revert LiveDeploymentDeployerRequired();
        }
    }

    /// @dev Compares a supplied approval against the version adapter's frozen phrase.
    /// @param approval Approval value read from the environment.
    function _requireLiveApprovalValue(string memory approval) internal pure {
        if (keccak256(bytes(approval)) != keccak256(bytes(_approvalPhrase()))) {
            revert LiveDeploymentApprovalRequired();
        }
    }

    /// @inheritdoc BaseDeployment
    function _startBroadcast() internal virtual override {
        vm.startBroadcast(vm.envAddress(_deployerEnvironmentVariable()));
    }

    /// @inheritdoc BaseDeployment
    function _executionLabel() internal pure virtual override returns (string memory label) {
        return "live target";
    }
}
