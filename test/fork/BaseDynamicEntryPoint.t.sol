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
    /// @dev Suite-specific test authority avoids collisions with existing Base delegations.
    uint256 private constant BASE_DYNAMIC_ENTRY_POINT_AUTHORITY_KEY =
        0xf02eb8a746dc967763d82ad8e58c03473bfb5be2c00599bde2f77b31e525bb39;
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x433709009B8330FDa32311DF1C2AFA402eD8D009);
    address payable private constant BENEFICIARY = payable(address(0xBEEF));

    DelegatedDefiSimplifyAccount private accountUnderTest;

    function setUp() external {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(ENTRY_POINT, BASE_DYNAMIC_ENTRY_POINT_AUTHORITY_KEY);
        vm.deal(accountUnderTest.delegatedEoa, 1 ether);
    }

    function test_BaseEntryPointDepositToIsAValidDynamicTarget() external {
        uint256 deposit = 0.25 ether;
        uint256 depositBefore = ENTRY_POINT.balanceOf(accountUnderTest.delegatedEoa);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(ENTRY_POINT), abi.encodeCall(IStakeManager.depositTo, (accountUnderTest.delegatedEoa)), deposit
        );

        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(ENTRY_POINT.balanceOf(accountUnderTest.delegatedEoa), depositBefore + deposit, "EntryPoint deposit");
        assertEq(accountUnderTest.delegatedEoa.balance, 0.75 ether, "account native balance");
    }

    function test_BaseEntryPointHandleOpsTargetFailsWithEntryPointReentrancy() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](0);
        bytes memory targetReason = abi.encodeWithSelector(EntryPoint.Reentrancy.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildUnpatchedDynamicCall(
            address(ENTRY_POINT), abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY)), 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(ENTRY_POINT), targetReason
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
