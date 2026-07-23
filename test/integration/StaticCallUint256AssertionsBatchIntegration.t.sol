// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract StaticCallUint256AssertionsBatchIntegrationTest is DelegatedAccountFixture {
    uint32 private constant ACCOUNT_ARGUMENT_OFFSET = 36;
    address private constant PLACEHOLDER_ACCOUNT = 0x1111111111111111111111111111111111111111;

    DelegatedPair private pair;
    StaticCallUint256Assertions private uint256Assertions;
    StaticCallUint256TargetMock private balanceReadTarget;
    AssertionBalanceToken private balanceToken;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        uint256Assertions = new StaticCallUint256Assertions();
        balanceReadTarget = new StaticCallUint256TargetMock();
        balanceToken = new AssertionBalanceToken();
    }

    function test_StaticBatchesExecuteBalanceAssertionAsFinalCall() external {
        _upstreamAccount(pair).executeBatch(_buildStaticAssertionBatch(31, 31));
        _customAccount(pair).executeBatch(_buildStaticAssertionBatch(37, 37));

        assertEq(balanceToken.balanceOf(pair.upstreamAccount), 31, "upstream producer");
        assertEq(balanceToken.balanceOf(pair.customAccount), 37, "custom producer");
    }

    function test_StaticBatchRevertsProducerWhenFinalBalanceAssertionFails() external {
        bytes memory assertionReason = _encodeBelowMinimumError(41, 42);

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, assertionReason));
        _customAccount(pair).executeBatch(_buildStaticAssertionBatch(41, 42));

        assertEq(balanceToken.balanceOf(pair.customAccount), 0, "failed static producer survived");
    }

    function test_DynamicBatchExecutesBalanceAssertionAsFinalCall() external {
        _dynamicAccount(pair).executeBatchDynamic(_buildDynamicAssertionBatch(43, 43));

        assertEq(balanceToken.balanceOf(pair.customAccount), 43, "dynamic producer");
    }

    function test_DynamicBatchRevertsProducerWhenFinalBalanceAssertionFails() external {
        bytes memory assertionReason = _encodeBelowMinimumError(47, 48);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(uint256Assertions), assertionReason
            )
        );
        _dynamicAccount(pair).executeBatchDynamic(_buildDynamicAssertionBatch(47, 48));

        assertEq(balanceToken.balanceOf(pair.customAccount), 0, "failed dynamic producer survived");
    }

    function _buildStaticAssertionBatch(uint256 producedAmount, uint256 minimum)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: address(balanceToken),
            value: 0,
            data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[1] = BaseAccount.Call({
            target: address(uint256Assertions), value: 0, data: _encodeMinimumBalanceAssertion(minimum)
        });
    }

    function _buildDynamicAssertionBatch(uint256 producedAmount, uint256 minimum)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] =
            _buildDynamicCall(address(balanceToken), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount)));
        calls[1] = _buildDynamicCall(address(uint256Assertions), _encodeMinimumBalanceAssertion(minimum));
    }

    function _encodeMinimumBalanceAssertion(uint256 minimum) private view returns (bytes memory) {
        bytes memory balanceReadData =
            abi.encodeCall(StaticCallUint256TargetMock.tokenBalance, (address(balanceToken), PLACEHOLDER_ACCOUNT));
        return abi.encodeCall(
            IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
            (address(balanceReadTarget), balanceReadData, ACCOUNT_ARGUMENT_OFFSET, uint32(0), minimum)
        );
    }

    function _encodeBelowMinimumError(uint256 actual, uint256 minimum) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
            address(balanceReadTarget),
            StaticCallUint256TargetMock.tokenBalance.selector,
            uint256(ACCOUNT_ARGUMENT_OFFSET),
            0,
            actual,
            minimum
        );
    }

    function _buildDynamicCall(address callTarget, bytes memory callData)
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
