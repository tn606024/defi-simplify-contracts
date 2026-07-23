// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AssertionBalanceToken, FlowAssertionsHarness} from "../mocks/FlowAssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract FlowAssertionsBatchIntegrationTest is DelegatedAccountFixture {
    bytes32 private constant STATIC_ASSERTION_CHECKPOINT_ID = keccak256("static-flow-assertion");
    bytes32 private constant DYNAMIC_ASSERTION_CHECKPOINT_ID = keccak256("dynamic-flow-assertion");

    UpstreamCompatibilityFixture private compatibilityFixture;
    FlowAssertionsHarness private flowAssertions;
    AssertionBalanceToken private balanceToken;

    function setUp() external {
        compatibilityFixture = _deployUpstreamCompatibilityFixture(IEntryPoint(address(this)));
        flowAssertions = new FlowAssertionsHarness();
        balanceToken = new AssertionBalanceToken();
    }

    function test_InheritedStaticBatches_WhenFinalBalanceAssertionPasses_CommitProducerAndSnapshot() external {
        balanceToken.setBalance(compatibilityFixture.upstream.delegatedEoa, 251);
        balanceToken.setBalance(compatibilityFixture.defiSimplify.delegatedEoa, 257);

        _upstreamAccountView(compatibilityFixture)
            .executeBatch(_buildStaticBalanceIncreaseBatch(STATIC_ASSERTION_CHECKPOINT_ID, 11, 11));
        _defiSimplifyAccountView(compatibilityFixture)
            .executeBatch(_buildStaticBalanceIncreaseBatch(STATIC_ASSERTION_CHECKPOINT_ID, 13, 13));

        assertEq(balanceToken.balanceOf(compatibilityFixture.upstream.delegatedEoa), 262, "upstream static balance");
        assertEq(
            balanceToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa), 270, "DeFi Simplify static balance"
        );
        (bool upstreamPresent, address upstreamToken, uint256 upstreamSnapshot) =
            flowAssertions.snapshotRecord(compatibilityFixture.upstream.delegatedEoa, STATIC_ASSERTION_CHECKPOINT_ID);
        (bool defiSimplifyPresent, address defiSimplifyToken, uint256 defiSimplifySnapshot) = flowAssertions.snapshotRecord(
            compatibilityFixture.defiSimplify.delegatedEoa, STATIC_ASSERTION_CHECKPOINT_ID
        );
        assertTrue(upstreamPresent && defiSimplifyPresent, "static snapshots absent");
        assertEq(upstreamToken, address(balanceToken), "upstream static token");
        assertEq(defiSimplifyToken, address(balanceToken), "DeFi Simplify static token");
        assertEq(upstreamSnapshot, 251, "upstream static snapshot");
        assertEq(defiSimplifySnapshot, 257, "DeFi Simplify static snapshot");
    }

    function test_InheritedStaticBatch_WhenFinalBalanceAssertionFails_RollsBackProducerAndSnapshot() external {
        balanceToken.setBalance(compatibilityFixture.defiSimplify.delegatedEoa, 271);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.BalanceIncreaseTooSmall.selector,
            address(balanceToken),
            STATIC_ASSERTION_CHECKPOINT_ID,
            17,
            18
        );

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 2, assertionReason));
        _defiSimplifyAccountView(compatibilityFixture)
            .executeBatch(_buildStaticBalanceIncreaseBatch(STATIC_ASSERTION_CHECKPOINT_ID, 17, 18));

        assertEq(
            balanceToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa),
            271,
            "failed static producer survived"
        );
        (bool present,,) = flowAssertions.snapshotRecord(
            compatibilityFixture.defiSimplify.delegatedEoa, STATIC_ASSERTION_CHECKPOINT_ID
        );
        assertFalse(present, "failed static snapshot survived");
    }

    function test_DynamicBatch_WhenFinalBalanceAssertionPasses_CommitsProducerAndSnapshot() external {
        balanceToken.setBalance(compatibilityFixture.defiSimplify.delegatedEoa, 277);

        _dynamicExecutionInterfaceView(compatibilityFixture.defiSimplify.delegatedEoa)
            .executeBatchDynamic(_buildDynamicBalanceIncreaseBatch(DYNAMIC_ASSERTION_CHECKPOINT_ID, 19, 19));

        assertEq(balanceToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa), 296, "dynamic balance");
        (bool present, address snapshotToken, uint256 snapshotBalance) = flowAssertions.snapshotRecord(
            compatibilityFixture.defiSimplify.delegatedEoa, DYNAMIC_ASSERTION_CHECKPOINT_ID
        );
        assertTrue(present, "dynamic snapshot absent");
        assertEq(snapshotToken, address(balanceToken), "dynamic snapshot token");
        assertEq(snapshotBalance, 277, "dynamic snapshot balance");
    }

    function test_DynamicBatch_WhenFinalBalanceAssertionFails_RollsBackProducerAndSnapshot() external {
        balanceToken.setBalance(compatibilityFixture.defiSimplify.delegatedEoa, 281);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.BalanceIncreaseTooSmall.selector,
            address(balanceToken),
            DYNAMIC_ASSERTION_CHECKPOINT_ID,
            23,
            24
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 2, address(flowAssertions), assertionReason
            )
        );
        _dynamicExecutionInterfaceView(compatibilityFixture.defiSimplify.delegatedEoa)
            .executeBatchDynamic(_buildDynamicBalanceIncreaseBatch(DYNAMIC_ASSERTION_CHECKPOINT_ID, 23, 24));

        assertEq(
            balanceToken.balanceOf(compatibilityFixture.defiSimplify.delegatedEoa),
            281,
            "failed dynamic producer survived"
        );
        (bool present,,) = flowAssertions.snapshotRecord(
            compatibilityFixture.defiSimplify.delegatedEoa, DYNAMIC_ASSERTION_CHECKPOINT_ID
        );
        assertFalse(present, "failed dynamic snapshot survived");
    }

    function _buildStaticBalanceIncreaseBatch(bytes32 checkpointId, uint256 producedAmount, uint256 minimumDelta)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](3);
        calls[0] = BaseAccount.Call({
            target: address(flowAssertions),
            value: 0,
            data: abi.encodeCall(IFlowAssertions.snapshotBalance, (address(balanceToken), checkpointId))
        });
        calls[1] = BaseAccount.Call({
            target: address(balanceToken),
            value: 0,
            data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[2] = BaseAccount.Call({
            target: address(flowAssertions),
            value: 0,
            data: abi.encodeCall(
                IFlowAssertions.assertBalanceIncreaseAtLeast, (address(balanceToken), checkpointId, minimumDelta)
            )
        });
    }

    function _buildDynamicBalanceIncreaseBatch(bytes32 checkpointId, uint256 producedAmount, uint256 minimumDelta)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _buildUnpatchedDynamicCall(
            address(flowAssertions),
            abi.encodeCall(IFlowAssertions.snapshotBalance, (address(balanceToken), checkpointId))
        );
        calls[1] = _buildUnpatchedDynamicCall(
            address(balanceToken), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        );
        calls[2] = _buildUnpatchedDynamicCall(
            address(flowAssertions),
            abi.encodeCall(
                IFlowAssertions.assertBalanceIncreaseAtLeast, (address(balanceToken), checkpointId, minimumDelta)
            )
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
