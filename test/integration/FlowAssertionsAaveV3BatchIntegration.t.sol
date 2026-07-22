// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3PoolMock} from "../mocks/AaveV3PoolMocks.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract FlowAssertionsAaveV3BatchIntegrationTest is DelegatedAccountFixture {
    DelegatedPair private pair;
    FlowAssertions private assertions;
    AaveV3PoolMock private pool;
    AssertionBalanceToken private token;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        assertions = new FlowAssertions();
        pool = new AaveV3PoolMock();
        token = new AssertionBalanceToken();
    }

    function test_AaveV3AssertionWorksAsFinalStepOfInheritedStaticBatches() external {
        pool.setHealthFactor(pair.upstreamAccount, 1.5e18);
        pool.setHealthFactor(pair.customAccount, 1.6e18);

        _upstream().executeBatch(_staticPlan(31, 1.5e18));
        _custom().executeBatch(_staticPlan(37, 1.6e18));

        assertEq(token.balanceOf(pair.upstreamAccount), 31, "upstream producer");
        assertEq(token.balanceOf(pair.customAccount), 37, "custom producer");
    }

    function test_FailedFinalStaticAaveV3AssertionRollsBackEarlierState() external {
        pool.setHealthFactor(pair.customAccount, 1.2e18);
        bytes memory assertionReason =
            abi.encodeWithSelector(IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(pool), 1.2e18, 1.3e18);

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, assertionReason));
        _custom().executeBatch(_staticPlan(41, 1.3e18));

        assertEq(token.balanceOf(pair.customAccount), 0, "failed static producer survived");
    }

    function test_AaveV3AssertionWorksAsFinalStepOfDynamicBatch() external {
        pool.setHealthFactor(pair.customAccount, 1.4e18);

        _dynamic().executeBatchDynamic(_dynamicPlan(43, 1.4e18));

        assertEq(token.balanceOf(pair.customAccount), 43, "dynamic producer");
    }

    function test_FailedFinalDynamicAaveV3AssertionRollsBackEarlierState() external {
        pool.setHealthFactor(pair.customAccount, 1.1e18);
        bytes memory assertionReason =
            abi.encodeWithSelector(IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(pool), 1.1e18, 1.2e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(assertions), assertionReason
            )
        );
        _dynamic().executeBatchDynamic(_dynamicPlan(47, 1.2e18));

        assertEq(token.balanceOf(pair.customAccount), 0, "failed dynamic producer survived");
    }

    function _staticPlan(uint256 producedAmount, uint256 minimumHealthFactor)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: address(token), value: 0, data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[1] = BaseAccount.Call({
            target: address(assertions),
            value: 0,
            data: abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (address(pool), minimumHealthFactor))
        });
    }

    function _dynamicPlan(uint256 producedAmount, uint256 minimumHealthFactor)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _dynamicCall(address(token), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount)));
        calls[1] = _dynamicCall(
            address(assertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (address(pool), minimumHealthFactor))
        );
    }

    function _dynamicCall(address target, bytes memory data)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = target;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _upstream() private view returns (Simple7702Account) {
        return Simple7702Account(pair.upstreamAccount);
    }

    function _custom() private view returns (DefiSimplify7702Account) {
        return DefiSimplify7702Account(pair.customAccount);
    }

    function _dynamic() private view returns (IDefiSimplify7702Account) {
        return IDefiSimplify7702Account(pair.customAccount);
    }
}
