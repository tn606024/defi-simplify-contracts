// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

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
        calls[0] = DynamicCallTestBuilder.buildOrdinaryCall(
            address(entryPoint), deposit, abi.encodeCall(IStakeManager.depositTo, (accountUnderTest.delegatedEoa))
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
        calls[0] = DynamicCallTestBuilder.buildOrdinaryCall(
            address(entryPoint), 0, abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(entryPoint), targetReason
            )
        );
        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }
}
