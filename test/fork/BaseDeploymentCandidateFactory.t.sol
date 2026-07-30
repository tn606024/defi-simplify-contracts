// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DeployBaseV1_1Candidate} from "../../script/DeployBaseV1_1Candidate.s.sol";
import {DeterministicDeployment} from "../../script/libraries/DeterministicDeployment.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title Base v1.1 Deployment Candidate Factory Fork Tests
/// @notice Replays the frozen v1.1 candidate against the actual Base factory at reviewed
///         pre-deployment block 49,268,704, then distinguishes that historical vacancy proof from
///         the active post-broadcast runtime identities. Every deployment occurs only on the fork.
contract BaseDeploymentCandidateFactoryTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";
    uint256 internal constant PRE_DEPLOYMENT_BLOCK = 49_268_704;

    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
    }

    function test_BaseCandidatePrerequisites_HaveFrozenRuntimeIdentities() public view {
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

    function test_BaseCandidateAddresses_AtReviewedPreDeploymentBlock_AreVacant() public {
        vm.rollFork(PRE_DEPLOYMENT_BLOCK);

        _assertCandidateAddressVacant("DefiSimplify7702Account");
        _assertCandidateAddressVacant("FlowAssertions");
        _assertCandidateAddressVacant("StaticCallUint256Assertions");
    }

    /// @dev Given vacant reviewed candidate addresses and frozen salts/initcode hashes. When the
    ///      three payloads call the live Arachnid factory inside the disposable pre-deployment fork.
    ///      Then each returned address and direct runtime must match the candidate manifest without
    ///      broadcasting or mutating Base.
    function test_BaseFactory_CandidatePayloadsDeployExactDirectRuntimesOnDisposableFork() public {
        vm.rollFork(PRE_DEPLOYMENT_BLOCK);
        address entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");

        _deployCandidateOnFork(
            "DefiSimplify7702Account",
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(entryPoint)))
        );
        _deployCandidateOnFork("FlowAssertions", type(FlowAssertions).creationCode);
        _deployCandidateOnFork("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);
    }

    function test_BaseV1_1Addresses_AfterBroadcast_HaveFrozenRuntimeIdentities() public view {
        _assertCandidateAddressHasExpectedRuntime("DefiSimplify7702Account");
        _assertCandidateAddressHasExpectedRuntime("FlowAssertions");
        _assertCandidateAddressHasExpectedRuntime("StaticCallUint256Assertions");
    }

    /// @dev Runs the shared script twice at current post-broadcast state to prove exact existing
    ///      runtimes are accepted idempotently rather than redeployed.
    function test_CandidateScript_WhenExactRuntimesAlreadyExist_RemainsIdempotent() public {
        DeployBaseV1_1Candidate deploymentScript = new DeployBaseV1_1Candidate();
        (address account, address flowAssertions, address staticAssertions) = deploymentScript.run();

        bytes32 accountCodeHash = account.codehash;
        bytes32 flowAssertionsCodeHash = flowAssertions.codehash;
        bytes32 staticAssertionsCodeHash = staticAssertions.codehash;

        deploymentScript.run();

        assertEq(account.codehash, accountCodeHash, "account runtime changed");
        assertEq(flowAssertions.codehash, flowAssertionsCodeHash, "typed-checker runtime changed");
        assertEq(staticAssertions.codehash, staticAssertionsCodeHash, "generic-checker runtime changed");
    }

    /// @dev Replaces the expected account runtime only on the fork so the permanent occupied-address
    ///      guard must reject the mismatched code hash before any deployment attempt.
    function test_CandidateScript_WhenAddressHasUnexpectedRuntime_RejectsOccupiedAddress() public {
        address account = vm.parseJsonAddress(manifest, ".artifacts.DefiSimplify7702Account.expectedAddress");
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".artifacts.DefiSimplify7702Account.runtimeCodeHash");
        vm.etch(account, hex"00");
        DeployBaseV1_1Candidate deploymentScript = new DeployBaseV1_1Candidate();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeterministicDeployment.RuntimeCodeHashMismatch.selector, account, expectedCodeHash, account.codehash
            )
        );
        deploymentScript.run();
    }

    function _assertCandidateAddressVacant(string memory contractName) private view {
        address expectedAddress =
            vm.parseJsonAddress(manifest, string.concat(".artifacts.", contractName, ".expectedAddress"));
        assertEq(expectedAddress.code.length, 0, string.concat(contractName, " candidate address occupied"));
    }

    function _assertCandidateAddressHasExpectedRuntime(string memory contractName) private view {
        string memory artifactRoot = string.concat(".artifacts.", contractName);
        address expectedAddress = vm.parseJsonAddress(manifest, string.concat(artifactRoot, ".expectedAddress"));
        assertGt(expectedAddress.code.length, 0, string.concat(contractName, " deployed runtime missing"));
        assertEq(
            expectedAddress.codehash,
            vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".runtimeCodeHash")),
            string.concat(contractName, " deployed runtime hash")
        );
    }

    /// @dev Calls the live Base factory only inside the disposable fork and
    ///      verifies both its return shape and the resulting direct runtime.
    function _deployCandidateOnFork(string memory contractName, bytes memory initcode) private {
        string memory artifactRoot = string.concat(".artifacts.", contractName);
        bytes32 expectedInitcodeHash = vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".initcodeHash"));
        assertEq(keccak256(initcode), expectedInitcodeHash, string.concat(contractName, " initcode hash"));

        address expectedAddress = vm.parseJsonAddress(manifest, string.concat(artifactRoot, ".expectedAddress"));
        assertEq(expectedAddress.code.length, 0, string.concat(contractName, " candidate address occupied"));

        address factory = vm.parseJsonAddress(manifest, ".factory.address");
        bytes32 salt = vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".salt.value"));
        (bool success, bytes memory returnedAddress) = factory.call(abi.encodePacked(salt, initcode));
        assertTrue(success, string.concat(contractName, " factory deployment failed"));
        assertEq(returnedAddress.length, 20, string.concat(contractName, " factory return length"));
        assertEq(
            keccak256(returnedAddress),
            keccak256(abi.encodePacked(expectedAddress)),
            string.concat(contractName, " factory return")
        );

        assertGt(expectedAddress.code.length, 0, string.concat(contractName, " runtime missing"));
        assertEq(
            expectedAddress.codehash,
            vm.parseJsonBytes32(manifest, string.concat(artifactRoot, ".runtimeCodeHash")),
            string.concat(contractName, " direct-runtime hash")
        );
    }
}
