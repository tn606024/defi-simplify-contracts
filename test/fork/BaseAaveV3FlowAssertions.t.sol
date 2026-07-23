// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract BaseAaveV3FlowAssertionsForkTest is DelegatedAccountFixture {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_FORK_BLOCK = 48_961_870;
    /// @dev Suite-specific test authorities avoid collisions with existing Base delegations.
    uint256 private constant BASE_AAVE_V3_UPSTREAM_AUTHORITY_KEY =
        0x039f0136dcb023957c9feac01f53a8e90fc8b0f97c690eee9aa664aa560843f4;
    uint256 private constant BASE_AAVE_V3_CUSTOM_AUTHORITY_KEY =
        0x092568093386a1ad66995c4eb558bc93b04ebede486cb6e474ea0f622959e543;
    address private constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    DelegatedPair private pair;
    FlowAssertions private assertions;

    function setUp() external {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        vm.rollFork(BASE_FORK_BLOCK);
        require(AAVE_V3_POOL.code.length != 0, "Aave V3 Pool has no code");
        pair = _deployDelegatedPair(
            IEntryPoint(address(this)), BASE_AAVE_V3_UPSTREAM_AUTHORITY_KEY, BASE_AAVE_V3_CUSTOM_AUTHORITY_KEY
        );
        assertions = new FlowAssertions();
    }

    function test_BaseAaveV3PoolReportsAndAssertionChecksDelegatedEoaHealthFactor() external {
        (,,,,, uint256 healthFactor) = IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(pair.customAccount);
        assertEq(healthFactor, type(uint256).max, "unexpected no-position health factor");

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({
            target: address(assertions),
            value: 0,
            data: abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (AAVE_V3_POOL, type(uint256).max))
        });

        vm.prank(pair.customAccount, pair.customAccount);
        _customAccount(pair).executeBatch(calls);
    }
}
