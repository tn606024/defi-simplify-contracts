// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentLive} from "./BaseDeployment.sol";

/// @title DeployBaseV1_1
/// @notice Dry-runs or, after explicit approval, broadcasts the reviewed Base
///         v1.1.0 deterministic deployment.
/// @dev The script never loads a private key. The caller must configure a
///      Foundry wallet for `BASE_V1_1_DEPLOYER_ADDRESS`. Broadcast and resume
///      contexts additionally require the exact DSC-91 approval phrase.
contract DeployBaseV1_1 is BaseDeploymentLive {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";
    string internal constant APPROVAL_ENV = "BASE_V1_1_BROADCAST_APPROVAL";
    string internal constant APPROVAL_PHRASE = "DSC-91 APPROVE BASE V1.1.0 BROADCAST";
    string internal constant DEPLOYER_ENV = "BASE_V1_1_DEPLOYER_ADDRESS";

    /// @dev Returns the reviewed Base v1.1.0 candidate manifest.
    /// @return manifestPath Repository-relative candidate manifest path.
    function _manifestPath() internal pure override returns (string memory manifestPath) {
        return MANIFEST_PATH;
    }

    /// @inheritdoc BaseDeploymentLive
    function _deployerEnvironmentVariable() internal pure override returns (string memory environmentVariable) {
        return DEPLOYER_ENV;
    }

    /// @inheritdoc BaseDeploymentLive
    function _approvalEnvironmentVariable() internal pure override returns (string memory environmentVariable) {
        return APPROVAL_ENV;
    }

    /// @inheritdoc BaseDeploymentLive
    function _approvalPhrase() internal pure override returns (string memory approvalPhrase) {
        return APPROVAL_PHRASE;
    }
}
