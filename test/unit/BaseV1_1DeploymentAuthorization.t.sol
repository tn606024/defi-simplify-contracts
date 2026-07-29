// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BaseDeploymentLive} from "../../script/BaseDeployment.sol";
import {DeployBaseV1_1} from "../../script/DeployBaseV1_1.s.sol";

contract DeployBaseV1_1Harness is DeployBaseV1_1 {
    function requirePublicDeployer(address deployer) external pure {
        _requirePublicDeployer(deployer);
    }

    function requireLiveApprovalValue(string memory approval) external pure {
        _requireLiveApprovalValue(approval);
    }
}

/// @title BaseV1_1DeploymentAuthorizationTest
/// @notice Verifies the public-deployer and issue-scoped approval gates without
///         entering a Forge broadcast context.
contract BaseV1_1DeploymentAuthorizationTest is Test {
    string private constant APPROVAL_PHRASE = "DSC-91 APPROVE BASE V1.1.0 BROADCAST";

    DeployBaseV1_1Harness private deploymentScript;

    function setUp() public {
        deploymentScript = new DeployBaseV1_1Harness();
    }

    function test_LiveDeployment_WhenPublicDeployerIsZero_RevertsBeforeManifestOrFactoryAccess() public {
        vm.expectRevert(BaseDeploymentLive.LiveDeploymentDeployerRequired.selector);
        deploymentScript.requirePublicDeployer(address(0));
    }

    function test_LiveDeployment_WhenPublicDeployerIsConfigured_AllowsNoBroadcastPreflight() public view {
        deploymentScript.requirePublicDeployer(address(0xD3E10));
    }

    function test_LiveDeployment_WhenApprovalPhraseIsMissing_RejectsLiveApproval() public {
        vm.expectRevert(BaseDeploymentLive.LiveDeploymentApprovalRequired.selector);
        deploymentScript.requireLiveApprovalValue("");
    }

    function test_LiveDeployment_WhenApprovalPhraseMatches_AcceptsLiveApproval() public view {
        deploymentScript.requireLiveApprovalValue(APPROVAL_PHRASE);
    }
}
