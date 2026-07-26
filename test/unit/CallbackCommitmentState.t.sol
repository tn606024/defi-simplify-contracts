// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {TransientCallbackCommitment} from "../../src/libraries/TransientCallbackCommitment.sol";
import {TransientDynamicExecutionLock} from "../../src/libraries/TransientDynamicExecutionLock.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract CallbackCommitmentHarness is DefiSimplify7702Account {
    constructor() DefiSimplify7702Account(IEntryPoint(address(0x4337))) {}

    function forceCallbackState(uint256 state) external {
        bytes32 stateSlot = TransientCallbackCommitment.root();
        assembly ("memory-safe") {
            tstore(stateSlot, state)
        }
    }

    function openCallbackCommitment(uint256 callIndex, address target, bytes32 calldataHash) external {
        _openCallbackCommitment(callIndex, target, calldataHash);
    }

    function configureLockedCallbackState(
        TransientCallbackCommitment.CallbackState state,
        address target,
        bytes32 calldataHash,
        uint256 callIndex
    ) external {
        TransientDynamicExecutionLock.lock();
        TransientCallbackCommitment.storeFields(target, calldataHash, callIndex, address(0));
        TransientCallbackCommitment.setState(state);
    }
}

contract CallbackCommitmentStateTest is Test {
    function test_OpeningCallbackCommitmentRequiresIdleState() external {
        CallbackCommitmentHarness accountHarness = new CallbackCommitmentHarness();
        accountHarness.forceCallbackState(2);

        vm.expectRevert(abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 7, uint8(2)));
        accountHarness.openCallbackCommitment(7, address(0xA11CE), keccak256("committed-calldata"));
    }

    function test_ExecuteOperationRejectsEveryLockedStateExceptAwaitingBeforeSenderOrPlanChecks() external {
        CallbackCommitmentHarness accountHarness = new CallbackCommitmentHarness();
        uint256 committedCallIndex = 17;
        TransientCallbackCommitment.CallbackState[3] memory rejectedStates = [
            TransientCallbackCommitment.CallbackState.Idle,
            TransientCallbackCommitment.CallbackState.ExecutingCallback,
            TransientCallbackCommitment.CallbackState.Consumed
        ];

        for (uint256 i = 0; i < rejectedStates.length; ++i) {
            accountHarness.configureLockedCallbackState(
                rejectedStates[i], address(this), keccak256("irrelevant-origin"), committedCallIndex
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefiSimplify7702Account.CallbackNotAwaiting.selector, committedCallIndex, uint8(rejectedStates[i])
                )
            );
            accountHarness.executeOperation(address(0xA55E7), 1, 0, address(accountHarness), bytes(""));
        }
    }
}
