// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3PoolMock} from "../mocks/AaveV3PoolMocks.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract FlowAssertionsAaveV3BatchIntegrationTest is DelegatedAccountFixture {
    UpstreamCompatibilityFixture private compatibilityFixture;
    FlowAssertions private flowAssertions;
    AaveV3PoolMock private aavePool;
    AssertionBalanceToken private producedToken;

    function setUp() external {
        compatibilityFixture = _deployUpstreamCompatibilityFixture(IEntryPoint(address(this)));
        flowAssertions = new FlowAssertions();
        aavePool = new AaveV3PoolMock();
        producedToken = new AssertionBalanceToken();
    }

    function test_InheritedStaticBatches_WhenAaveHealthFactorMeetsMinimum_CommitProducerState() external {
        aavePool.setHealthFactor(compatibilityFixture.upstream.delegatedEoa, 1.5e18);
        aavePool.setHealthFactor(compatibilityFixture.defiSimplify.delegatedEoa, 1.6e18);

        _upstreamAccountView(compatibilityFixture).executeBatch(_buildStaticAaveAssertionBatch(31, 1.5e18));
        _defiSimplifyAccountView(compatibilityFixture).executeBatch(_buildStaticAaveAssertionBatch(37, 1.6e18));

        assertEq(producedToken.balanceOf(compatibilityFixture.upstream.delegatedEoa), 31, "upstream producer");
        assertEq(producedToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa), 37, "DeFi Simplify producer");
    }

    function test_InheritedStaticBatch_WhenFinalAaveAssertionFails_RollsBackProducerState() external {
        aavePool.setHealthFactor(compatibilityFixture.defiSimplify.delegatedEoa, 1.2e18);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(aavePool), 1.2e18, 1.3e18
        );

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, assertionReason));
        _defiSimplifyAccountView(compatibilityFixture).executeBatch(_buildStaticAaveAssertionBatch(41, 1.3e18));

        assertEq(
            producedToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa),
            0,
            "failed static producer survived"
        );
    }

    function test_DynamicBatch_WhenAaveHealthFactorMeetsMinimum_CommitsProducerState() external {
        aavePool.setHealthFactor(compatibilityFixture.defiSimplify.delegatedEoa, 1.4e18);

        _dynamicExecutionInterfaceView(compatibilityFixture.defiSimplify.delegatedEoa)
            .executeBatchDynamic(_buildDynamicAaveAssertionBatch(43, 1.4e18));

        assertEq(producedToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa), 43, "dynamic producer");
    }

    function test_DynamicBatch_WhenFinalAaveAssertionFails_RollsBackProducerState() external {
        aavePool.setHealthFactor(compatibilityFixture.defiSimplify.delegatedEoa, 1.1e18);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.AaveV3HealthFactorTooLow.selector, address(aavePool), 1.1e18, 1.2e18
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(flowAssertions), assertionReason
            )
        );
        _dynamicExecutionInterfaceView(compatibilityFixture.defiSimplify.delegatedEoa)
            .executeBatchDynamic(_buildDynamicAaveAssertionBatch(47, 1.2e18));

        assertEq(
            producedToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa),
            0,
            "failed dynamic producer survived"
        );
    }

    function _buildStaticAaveAssertionBatch(uint256 producedAmount, uint256 minimumHealthFactor)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: address(producedToken),
            value: 0,
            data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[1] = BaseAccount.Call({
            target: address(flowAssertions),
            value: 0,
            data: abi.encodeCall(
                IFlowAssertions.assertAaveV3HealthFactorAtLeast, (address(aavePool), minimumHealthFactor)
            )
        });
    }

    function _buildDynamicAaveAssertionBatch(uint256 producedAmount, uint256 minimumHealthFactor)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildUnpatchedDynamicCall(
            address(producedToken), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        );
        calls[1] = _buildUnpatchedDynamicCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.assertAaveV3HealthFactorAtLeast, (address(aavePool), minimumHealthFactor))
        );
    }

    function _buildUnpatchedDynamicCall(address callTarget, bytes memory callData)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = callTarget;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
