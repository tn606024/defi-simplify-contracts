// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title DeterministicDeployment
/// @notice Version-independent CREATE2 identity and runtime validation helpers
///         for direct immutable deployments.
/// @dev All functions are internal and embedded in the calling script. The
///      library performs no factory call and introduces no linked deployment
///      or `DELEGATECALL`.
library DeterministicDeployment {
    /// @notice An on-chain prerequisite or deployment artifact has unexpected runtime code.
    /// @param target Address whose runtime identity was checked.
    /// @param expectedHash Runtime code hash frozen by the deployment manifest.
    /// @param actualHash Runtime code hash observed in the active execution context.
    error RuntimeCodeHashMismatch(address target, bytes32 expectedHash, bytes32 actualHash);

    /// @notice Reconstructed artifact initcode does not match the deployment manifest.
    /// @param contractName Human-readable artifact name.
    /// @param expectedHash Initcode hash frozen by the deployment manifest.
    /// @param actualHash Hash of the initcode reconstructed from the current build.
    error InitcodeHashMismatch(string contractName, bytes32 expectedHash, bytes32 actualHash);

    /// @notice Independently predicted CREATE2 address does not match the deployment manifest.
    /// @param contractName Human-readable artifact name.
    /// @param expectedAddress Address frozen by the deployment manifest.
    /// @param actualAddress Address predicted from factory, salt, and initcode hash.
    error AddressMismatch(string contractName, address expectedAddress, address actualAddress);

    /// @notice Manifest identity required to validate one direct immutable artifact.
    /// @param contractName Human-readable artifact name used for error attribution.
    /// @param salt CREATE2 salt supplied to the deterministic deployment factory.
    /// @param initcodeHash Hash of complete creation code and constructor arguments.
    /// @param expectedAddress CREATE2 address derived from factory, salt, and initcode hash.
    /// @param runtimeCodeHash Expected final direct-runtime code hash.
    struct ArtifactIdentity {
        string contractName;
        bytes32 salt;
        bytes32 initcodeHash;
        address expectedAddress;
        bytes32 runtimeCodeHash;
    }

    /// @notice Validates reconstructed initcode and its raw EIP-1014 address.
    /// @param factory Deterministic deployment factory address.
    /// @param identity Manifest identity for the selected artifact.
    /// @param initcode Reconstructed creation code and constructor arguments.
    function requireArtifactIdentity(address factory, ArtifactIdentity memory identity, bytes memory initcode)
        internal
        pure
    {
        bytes32 actualInitcodeHash = keccak256(initcode);
        if (actualInitcodeHash != identity.initcodeHash) {
            revert InitcodeHashMismatch(identity.contractName, identity.initcodeHash, actualInitcodeHash);
        }

        address actualAddress = predictAddress(factory, identity.salt, actualInitcodeHash);
        if (actualAddress != identity.expectedAddress) {
            revert AddressMismatch(identity.contractName, identity.expectedAddress, actualAddress);
        }
    }

    /// @notice Computes the raw EIP-1014 CREATE2 address.
    /// @param factory Address that executes CREATE2.
    /// @param salt CREATE2 salt.
    /// @param initcodeHash Hash of complete creation code and constructor arguments.
    /// @return predictedAddress Address derived from factory, salt, and initcode hash.
    function predictAddress(address factory, bytes32 salt, bytes32 initcodeHash)
        internal
        pure
        returns (address predictedAddress)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initcodeHash)))));
    }

    /// @notice Requires nonempty runtime code with the exact expected code hash.
    /// @param target Prerequisite or deployed artifact address.
    /// @param expectedHash Frozen expected runtime code hash.
    function requireRuntimeCodeHash(address target, bytes32 expectedHash) internal view {
        bytes32 actualHash = target.code.length == 0 ? bytes32(0) : target.codehash;
        if (actualHash != expectedHash) {
            revert RuntimeCodeHashMismatch(target, expectedHash, actualHash);
        }
    }
}
