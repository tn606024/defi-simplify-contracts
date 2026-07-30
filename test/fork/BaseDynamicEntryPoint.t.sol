// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

/// @title Base EntryPoint Dynamic-Target Fork Tests
/// @notice Proves that the pinned Base v0.9 EntryPoint remains an admissible dynamic CALL target:
///         depositTo succeeds, while a nested handleOps attempt fails at the EntryPoint's own
///         reentrancy boundary and is wrapped with the dynamic call index and complete reason.
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
        calls[0] = DynamicCallTestBuilder.buildOrdinaryCall(
            address(ENTRY_POINT), deposit, abi.encodeCall(IStakeManager.depositTo, (accountUnderTest.delegatedEoa))
        );

        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(ENTRY_POINT.balanceOf(accountUnderTest.delegatedEoa), depositBefore + deposit, "EntryPoint deposit");
        assertEq(accountUnderTest.delegatedEoa.balance, 0.75 ether, "account native balance");
    }

    /// @dev The delegated EOA is already executing account code when it CALLs handleOps. The real
    ///      EntryPoint must reject that code-bearing caller with Reentrancy before any authorized
    ///      account reentry, and the account must preserve that nested reason at outer call 0.
    function test_BaseEntryPointHandleOpsTargetFailsWithEntryPointReentrancy() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](0);
        bytes memory targetReason = abi.encodeWithSelector(EntryPoint.Reentrancy.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildOrdinaryCall(
            address(ENTRY_POINT), 0, abi.encodeCall(IEntryPoint.handleOps, (operations, BENEFICIARY))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(ENTRY_POINT), targetReason
            )
        );
        vm.prank(accountUnderTest.delegatedEoa, accountUnderTest.delegatedEoa);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }
}
