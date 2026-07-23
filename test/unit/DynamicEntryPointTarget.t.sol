// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract DynamicEntryPointTargetTest is DelegatedAccountFixture {
    address payable private constant BENEFICIARY = payable(address(0xBEEF));

    EntryPoint private entryPoint;
    DelegatedDefiSimplifyAccount private accountUnderTest;

    function setUp() external {
        entryPoint = new EntryPoint();
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(entryPoint);
        vm.deal(accountUnderTest.delegatedEoa, 1 ether);
    }

    function test_EntryPointDepositToIsAValidDynamicTarget() external {
        uint256 deposit = 0.25 ether;
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(entryPoint), abi.encodeCall(IStakeManager.depositTo, (accountUnderTest.delegatedEoa)), deposit
        );

        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(entryPoint.balanceOf(accountUnderTest.delegatedEoa), deposit, "EntryPoint deposit");
        assertEq(accountUnderTest.delegatedEoa.balance, 0.75 ether, "account native balance");
    }

    function test_EntryPointHandleOpsTargetFailsWithEntryPointReentrancy() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](0);
        bytes memory targetReason = abi.encodeWithSelector(EntryPoint.Reentrancy.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(entryPoint), abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY)), 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(entryPoint), targetReason
            )
        );
        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function _buildUnpatchedDynamicCall(address callTarget, bytes memory callData, uint256 callValue)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = callTarget;
        dynamicCall.value = callValue;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
