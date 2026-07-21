// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract BaseDynamicEntryPointForkTest is DelegatedAccountFixture {
    uint256 private constant BASE_CHAIN_ID = 8453;
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x433709009B8330FDa32311DF1C2AFA402eD8D009);
    address payable private constant BENEFICIARY = payable(address(0xBEEF));

    DelegatedPair private pair;

    function setUp() external {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        pair = _deployDelegatedPair(ENTRY_POINT);
        vm.deal(pair.customAccount, 1 ether);
    }

    function test_BaseEntryPointDepositToIsAValidDynamicTarget() external {
        uint256 deposit = 0.25 ether;
        uint256 depositBefore = ENTRY_POINT.balanceOf(pair.customAccount);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(ENTRY_POINT), abi.encodeCall(IStakeManager.depositTo, (pair.customAccount)), deposit
        );

        vm.prank(pair.customAccount, pair.customAccount);
        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(ENTRY_POINT.balanceOf(pair.customAccount), depositBefore + deposit, "EntryPoint deposit");
        assertEq(pair.customAccount.balance, 0.75 ether, "account native balance");
    }

    function test_BaseEntryPointHandleOpsTargetFailsWithEntryPointReentrancy() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](0);
        bytes memory targetReason = abi.encodeWithSelector(EntryPoint.Reentrancy.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _emptyDynamicCall(
            address(ENTRY_POINT), abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY)), 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(ENTRY_POINT), targetReason
            )
        );
        vm.prank(pair.customAccount, pair.customAccount);
        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);
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
