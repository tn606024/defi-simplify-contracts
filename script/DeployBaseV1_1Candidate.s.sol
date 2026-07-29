// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentCandidate} from "./BaseDeployment.sol";

/// @title DeployBaseV1_1Candidate
/// @notice Dry-runs the three Base v1.1.0 candidate deployments against the
///         pinned Arachnid Deterministic Deployment Proxy.
/// @dev Broadcast and resume contexts are permanently rejected. Live
///      deployment uses the separately gated `DeployBaseV1_1` script.
contract DeployBaseV1_1Candidate is BaseDeploymentCandidate {
    string internal constant MANIFEST_PATH = "deployments/base-v1.1-candidate.json";

    /// @dev Returns the reviewed Base v1.1.0 candidate manifest.
    /// @return manifestPath Repository-relative candidate manifest path.
    function _manifestPath() internal pure override returns (string memory manifestPath) {
        return MANIFEST_PATH;
    }
}
