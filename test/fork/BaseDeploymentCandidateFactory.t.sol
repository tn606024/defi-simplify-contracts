// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";
import {DeployBaseV1_1Candidate} from "../../script/DeployBaseV1_1Candidate.s.sol";
import {DeterministicDeployment} from "../../script/libraries/DeterministicDeployment.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @title BaseDeploymentCandidateFactoryTest
/// @notice Proves candidate vacancy, prerequisites, payloads, and direct runtime
///         identities against the actual Base factory on a disposable fork.
contract BaseDeploymentCandidateFactoryTest is Test {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";

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

    function test_BaseCandidateAddresses_BeforeBroadcast_AreVacant() public view {
        _assertCandidateAddressVacant("DefiSimplify7702Account");
        _assertCandidateAddressVacant("FlowAssertions");
        _assertCandidateAddressVacant("StaticCallUint256Assertions");
    }

    function test_BaseFactory_CandidatePayloadsDeployExactDirectRuntimesOnDisposableFork() public {
        address entryPoint = vm.parseJsonAddress(manifest, ".entryPoint.address");

        _deployCandidateOnFork(
            "DefiSimplify7702Account",
            abi.encodePacked(type(DefiSimplify7702Account).creationCode, abi.encode(IEntryPoint(entryPoint)))
        );
        _deployCandidateOnFork("FlowAssertions", type(FlowAssertions).creationCode);
        _deployCandidateOnFork("StaticCallUint256Assertions", type(StaticCallUint256Assertions).creationCode);
    }

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
