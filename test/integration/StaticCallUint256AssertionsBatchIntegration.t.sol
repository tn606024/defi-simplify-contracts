// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AssertionBalanceToken} from "../mocks/FlowAssertionsMocks.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract StaticCallUint256AssertionsBatchIntegrationTest is DelegatedAccountFixture {
    uint32 private constant SUBJECT_OFFSET = 36;
    address private constant PLACEHOLDER_SUBJECT = 0x1111111111111111111111111111111111111111;

    DelegatedPair private pair;
    StaticCallUint256Assertions private assertions;
    StaticCallUint256TargetMock private target;
    AssertionBalanceToken private token;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        assertions = new StaticCallUint256Assertions();
        target = new StaticCallUint256TargetMock();
        token = new AssertionBalanceToken();
    }

    function test_GenericCheckerWorksAsFinalStepOfInheritedStaticBatches() external {
        _upstream().executeBatch(_staticPlan(31, 31));
        _custom().executeBatch(_staticPlan(37, 37));

        assertEq(token.balanceOf(pair.upstreamAccount), 31, "upstream producer");
        assertEq(token.balanceOf(pair.customAccount), 37, "custom producer");
    }

    function test_FailedFinalStaticCheckRollsBackEarlierBatchState() external {
        bytes memory assertionReason = _belowMinimumReason(41, 42);

        vm.expectRevert(abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, assertionReason));
        _custom().executeBatch(_staticPlan(41, 42));

        assertEq(token.balanceOf(pair.customAccount), 0, "failed static producer survived");
    }

    function test_GenericCheckerWorksAsFinalStepOfDynamicBatch() external {
        _dynamic().executeBatchDynamic(_dynamicPlan(43, 43));

        assertEq(token.balanceOf(pair.customAccount), 43, "dynamic producer");
    }

    function test_FailedFinalDynamicCheckRollsBackEarlierBatchState() external {
        bytes memory assertionReason = _belowMinimumReason(47, 48);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(assertions), assertionReason
            )
        );
        _dynamic().executeBatchDynamic(_dynamicPlan(47, 48));

        assertEq(token.balanceOf(pair.customAccount), 0, "failed dynamic producer survived");
    }

    function _staticPlan(uint256 producedAmount, uint256 minimum)
        private
        view
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({
            target: address(token), value: 0, data: abi.encodeCall(AssertionBalanceToken.produce, (producedAmount))
        });
        calls[1] = BaseAccount.Call({target: address(assertions), value: 0, data: _assertionData(minimum)});
    }

    function _dynamicPlan(uint256 producedAmount, uint256 minimum)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _dynamicCall(address(token), abi.encodeCall(AssertionBalanceToken.produce, (producedAmount)));
        calls[1] = _dynamicCall(address(assertions), _assertionData(minimum));
    }

    function _assertionData(uint256 minimum) private view returns (bytes memory) {
        bytes memory readData =
            abi.encodeCall(StaticCallUint256TargetMock.tokenBalance, (address(token), PLACEHOLDER_SUBJECT));
        return abi.encodeCall(
            IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
            (address(target), readData, SUBJECT_OFFSET, uint32(0), minimum)
        );
    }

    function _belowMinimumReason(uint256 actual, uint256 minimum) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
            address(target),
            StaticCallUint256TargetMock.tokenBalance.selector,
            uint256(SUBJECT_OFFSET),
            0,
            actual,
            minimum
        );
    }

    function _dynamicCall(address targetAddress, bytes memory data)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = targetAddress;
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
