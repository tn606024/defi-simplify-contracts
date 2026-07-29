// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeterministicDeployment} from "../../script/libraries/DeterministicDeployment.sol";

contract DeterministicDeploymentHarness {
    function predictAddress(address factory, bytes32 salt, bytes32 initcodeHash)
        external
        pure
        returns (address predictedAddress)
    {
        return DeterministicDeployment.predictAddress(factory, salt, initcodeHash);
    }

    function requireArtifactIdentity(
        string memory contractName,
        address factory,
        bytes32 salt,
        bytes32 expectedInitcodeHash,
        address expectedAddress,
        bytes memory initcode
    ) external pure {
        DeterministicDeployment.requireArtifactIdentity(
            factory,
            DeterministicDeployment.ArtifactIdentity({
                contractName: contractName,
                salt: salt,
                initcodeHash: expectedInitcodeHash,
                expectedAddress: expectedAddress,
                runtimeCodeHash: bytes32(0)
            }),
            initcode
        );
    }

    function requireRuntimeCodeHash(address target, bytes32 expectedHash) external view {
        DeterministicDeployment.requireRuntimeCodeHash(target, expectedHash);
    }
}

/// @title DeterministicDeploymentTest
/// @notice Verifies the version-independent identity primitives used by all
///         current and future version adapters.
contract DeterministicDeploymentTest is Test {
    string private constant ARTIFACT_NAME = "ReusableArtifact";
    address private constant FACTORY = address(0x4E59);
    bytes32 private constant SALT = keccak256("reusable-deployment-salt");
    bytes private constant INITCODE = hex"6001600c60003960016000f300";

    DeterministicDeploymentHarness private deploymentHarness;

    function setUp() public {
        deploymentHarness = new DeterministicDeploymentHarness();
    }

    function test_PredictAddress_UsesRawEip1014Formula() public view {
        bytes32 initcodeHash = keccak256(INITCODE);
        address independentlyPredicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, SALT, initcodeHash)))));

        assertEq(deploymentHarness.predictAddress(FACTORY, SALT, initcodeHash), independentlyPredicted);
    }

    function test_RequireArtifactIdentity_WhenInitcodeAndAddressMatch_Succeeds() public view {
        bytes32 initcodeHash = keccak256(INITCODE);
        address expectedAddress = deploymentHarness.predictAddress(FACTORY, SALT, initcodeHash);

        deploymentHarness.requireArtifactIdentity(ARTIFACT_NAME, FACTORY, SALT, initcodeHash, expectedAddress, INITCODE);
    }

    function test_RequireArtifactIdentity_WhenInitcodeHashDiffers_RevertsWithArtifactContext() public {
        bytes32 expectedInitcodeHash = keccak256("different initcode");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeterministicDeployment.InitcodeHashMismatch.selector,
                ARTIFACT_NAME,
                expectedInitcodeHash,
                keccak256(INITCODE)
            )
        );
        deploymentHarness.requireArtifactIdentity(
            ARTIFACT_NAME, FACTORY, SALT, expectedInitcodeHash, address(0), INITCODE
        );
    }

    function test_RequireArtifactIdentity_WhenPredictedAddressDiffers_RevertsWithArtifactContext() public {
        bytes32 initcodeHash = keccak256(INITCODE);
        address actualAddress = deploymentHarness.predictAddress(FACTORY, SALT, initcodeHash);
        address wrongExpectedAddress = address(0xBADC0DE);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeterministicDeployment.AddressMismatch.selector, ARTIFACT_NAME, wrongExpectedAddress, actualAddress
            )
        );
        deploymentHarness.requireArtifactIdentity(
            ARTIFACT_NAME, FACTORY, SALT, initcodeHash, wrongExpectedAddress, INITCODE
        );
    }

    function test_RequireRuntimeCodeHash_WhenRuntimeMatches_Succeeds() public view {
        deploymentHarness.requireRuntimeCodeHash(address(deploymentHarness), address(deploymentHarness).codehash);
    }

    function test_RequireRuntimeCodeHash_WhenTargetIsVacant_RevertsWithZeroActualHash() public {
        address vacantTarget = address(0xC0DE);
        bytes32 expectedHash = keccak256("expected runtime");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeterministicDeployment.RuntimeCodeHashMismatch.selector, vacantTarget, expectedHash, bytes32(0)
            )
        );
        deploymentHarness.requireRuntimeCodeHash(vacantTarget, expectedHash);
    }
}
