// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ProjectBootstrap} from "../mocks/ProjectBootstrap.sol";

contract ProjectBootstrapTest {
    function test_BootstrapFixtureCompilesAndRuns() external {
        ProjectBootstrap fixture = new ProjectBootstrap();
        require(fixture.version() == 1, "unexpected bootstrap version");
    }
}
