// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";

/// @dev Records deterministic deployment-cost evidence for each direct artifact.
///      DSC-87 compares the released 200-run build with the 10,000-run candidate;
///      these tests do not deploy to a chain or assign an official identity.
contract ArtifactDeploymentGasBenchmarkTest {
    function test_Gas_DeployDefiSimplify7702Account() external {
        new DefiSimplify7702Account(IEntryPoint(address(this)));
    }

    function test_Gas_DeployFlowAssertions() external {
        new FlowAssertions();
    }

    function test_Gas_DeployStaticCallUint256Assertions() external {
        new StaticCallUint256Assertions();
    }
}
