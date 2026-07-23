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
    DelegatedPair private pair;

    function setUp() external {
        entryPoint = new EntryPoint();
        pair = _deployDelegatedPair(entryPoint);
        vm.deal(pair.customAccount, 1 ether);
    }

    function test_EntryPointDepositToIsAValidDynamicTarget() external {
        uint256 deposit = 0.25 ether;
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(entryPoint), abi.encodeCall(IStakeManager.depositTo, (pair.customAccount)), deposit
        );

        vm.prank(pair.customAccount, pair.customAccount);
        _dynamicAccount(pair).executeBatchDynamic(calls);

        assertEq(entryPoint.balanceOf(pair.customAccount), deposit, "EntryPoint deposit");
        assertEq(pair.customAccount.balance, 0.75 ether, "account native balance");
    }

    function test_EntryPointHandleOpsTargetFailsWithEntryPointReentrancy() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](0);
        bytes memory targetReason = abi.encodeWithSelector(EntryPoint.Reentrancy.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] =
            _emptyDynamicCall(address(entryPoint), abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(entryPoint), targetReason
            )
        );
        vm.prank(pair.customAccount, pair.customAccount);
        _dynamicAccount(pair).executeBatchDynamic(calls);
    }

    function _emptyDynamicCall(address target, bytes memory data, uint256 value)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = target;
        dynamicCall.value = value;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
