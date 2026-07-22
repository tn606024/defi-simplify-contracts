// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AssertionBalanceToken, FlowAssertionsHarness} from "../mocks/FlowAssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract FlowAssertionsBatchIntegrationTest is DelegatedAccountFixture {
    bytes32 private constant STATIC_CHECKPOINT = keccak256("static-flow-assertion");
    bytes32 private constant DYNAMIC_CHECKPOINT = keccak256("dynamic-flow-assertion");

    DelegatedPair private pair;
    FlowAssertionsHarness private assertions;
    AssertionBalanceToken private token;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        assertions = new FlowAssertionsHarness();
        token = new AssertionBalanceToken();
    }

    function test_AssertionsWorkAsFinalStepsOfInheritedStaticBatches() external {
        token.setBalance(pair.upstreamAccount, 251);
        token.setBalance(pair.customAccount, 257);

        _upstream().executeBatch(_staticIncreasePlan(STATIC_CHECKPOINT, 11, 11));
        _custom().executeBatch(_staticIncreasePlan(STATIC_CHECKPOINT, 13, 13));

        assertEq(token.balanceOf(pair.upstreamAccount), 262, "upstream static balance");
        assertEq(token.balanceOf(pair.customAccount), 270, "custom static balance");
        (bool upstreamPresent, address upstreamToken, uint256 upstreamSnapshot) =
            assertions.snapshotRecord(pair.upstreamAccount, STATIC_CHECKPOINT);
        (bool customPresent, address customToken, uint256 customSnapshot) =
            assertions.snapshotRecord(pair.customAccount, STATIC_CHECKPOINT);
        assertTrue(upstreamPresent && customPresent, "static snapshots absent");
        assertEq(upstreamToken, address(token), "upstream static token");
        assertEq(customToken, address(token), "custom static token");
        assertEq(upstreamSnapshot, 251, "upstream static snapshot");
        assertEq(customSnapshot, 257, "custom static snapshot");
    }

    function test_FailedFinalStaticAssertionRollsBackEarlierCallsAndSnapshot() external {
        token.setBalance(pair.customAccount, 271);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.BalanceIncreaseTooSmall.selector, address(token), STATIC_CHECKPOINT, 17, 18
        );

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 2, assertionReason));
        _custom().executeBatch(_staticIncreasePlan(STATIC_CHECKPOINT, 17, 18));

        assertEq(token.balanceOf(pair.customAccount), 271, "failed static producer survived");
        (bool present,,) = assertions.snapshotRecord(pair.customAccount, STATIC_CHECKPOINT);
        assertFalse(present, "failed static snapshot survived");
    }

    function test_AssertionsWorkAsFinalStepsOfDynamicBatch() external {
        token.setBalance(pair.customAccount, 277);

        _dynamic().executeBatchDynamic(_dynamicIncreasePlan(DYNAMIC_CHECKPOINT, 19, 19));

        assertEq(token.balanceOf(pair.customAccount), 296, "dynamic balance");
        (bool present, address snapshotToken, uint256 snapshotBalance) =
            assertions.snapshotRecord(pair.customAccount, DYNAMIC_CHECKPOINT);
        assertTrue(present, "dynamic snapshot absent");
        assertEq(snapshotToken, address(token), "dynamic snapshot token");
        assertEq(snapshotBalance, 277, "dynamic snapshot balance");
    }

    function test_FailedFinalDynamicAssertionRollsBackEarlierCallsAndSnapshot() external {
        token.setBalance(pair.customAccount, 281);
        bytes memory assertionReason = abi.encodeWithSelector(
            IFlowAssertions.BalanceIncreaseTooSmall.selector, address(token), DYNAMIC_CHECKPOINT, 23, 24
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 2, address(assertions), assertionReason
            )
        );
        _dynamic().executeBatchDynamic(_dynamicIncreasePlan(DYNAMIC_CHECKPOINT, 23, 24));

        assertEq(token.balanceOf(pair.customAccount), 281, "failed dynamic producer survived");
        (bool present,,) = assertions.snapshotRecord(pair.customAccount, DYNAMIC_CHECKPOINT);
        assertFalse(present, "failed dynamic snapshot survived");
    }

    function _staticIncreasePlan(bytes32 checkpointId, uint256 producedAmount, uint256 minimumDelta)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](3);
        calls[0] = BaseAccount.Call({
            target: address(assertions),
            value: 0,
            data: abi.encodeCall(IFlowAssertions.snapshotBalance, (address(token), checkpointId))
        });
        calls[1] = BaseAccount.Call({
            target: address(token), value: 0, data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[2] = BaseAccount.Call({
            target: address(assertions),
            value: 0,
            data: abi.encodeCall(
                IFlowAssertions.assertBalanceIncreaseAtLeast, (address(token), checkpointId, minimumDelta)
            )
        });
    }

    function _dynamicIncreasePlan(bytes32 checkpointId, uint256 producedAmount, uint256 minimumDelta)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](3);
        calls[0] = _dynamicCall(
            address(assertions), abi.encodeCall(IFlowAssertions.snapshotBalance, (address(token), checkpointId))
        );
        calls[1] = _dynamicCall(address(token), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount)));
        calls[2] = _dynamicCall(
            address(assertions),
            abi.encodeCall(IFlowAssertions.assertBalanceIncreaseAtLeast, (address(token), checkpointId, minimumDelta))
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
