// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Adversarial nested-revert coverage for dynamic call atomicity and error wrapping.
contract DynamicExecutionAdversarialFuzzTest is DelegatedAccountFixture {
    DelegatedDefiSimplifyAccount private accountUnderTest;
    DynamicExecutionTarget private recordingTarget;

    /// @dev Installs the delegated account fixture and target used by each fuzz case.
    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        recordingTarget = new DynamicExecutionTarget();
    }

    /// @dev Fuzzes complete nested revert payload preservation and prior-call rollback.
    /// @param amount Amount written by the earlier call before rollback.
    /// @param code Arbitrary nested target error code.
    /// @param payload Arbitrary nested target revert payload.
    function testFuzz_CompleteNestedRevertDataIsPreservedAndEarlierStateRollsBack(
        uint128 amount,
        uint256 code,
        bytes calldata payload
    ) external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildTargetCall(abi.encodeCall(DynamicExecutionTarget.record, (uint256(amount), bytes("rollback"))));
        calls[1] = _buildTargetCall(abi.encodeCall(DynamicExecutionTarget.fail, (code, payload)));
        bytes memory targetReason = abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, code, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 1, address(recordingTarget), targetReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 0, "earlier target state survived nested revert");
        assertEq(recordingTarget.total(), 0, "earlier target total survived nested revert");
    }

    function _buildTargetCall(bytes memory callData)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = address(recordingTarget);
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
