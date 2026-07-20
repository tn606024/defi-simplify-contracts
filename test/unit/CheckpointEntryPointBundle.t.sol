// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {CheckpointBalanceToken, CheckpointTableHarness} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CheckpointEntryPointBundleTest is DelegatedAccountFixture {
    uint256 private constant ACCOUNT_AUTHORITY_KEY = 0x48B0;
    address private constant BUNDLER = address(0xB0D1E);
    address payable private constant BENEFICIARY = payable(address(0xBEEF));
    bytes32 private constant REUSED_CHECKPOINT_ID = keccak256("bundle-reused-checkpoint");

    EntryPoint private entryPoint;
    CheckpointTableHarness private implementation;
    address payable private account;
    CheckpointBalanceToken private token;
    DynamicExecutionTarget private target;

    function setUp() external {
        entryPoint = new EntryPoint();
        implementation = new CheckpointTableHarness(entryPoint);
        account = payable(vm.addr(ACCOUNT_AUTHORITY_KEY));
        require(account.code.length == 0, "authority already has code");
        vm.signAndAttachDelegation(address(implementation), ACCOUNT_AUTHORITY_KEY);
        require(_delegationTarget(account) == address(implementation), "wrong delegation target");

        token = new CheckpointBalanceToken();
        target = new DynamicExecutionTarget();
        token.setBalance(account, 211);
    }

    function test_MultipleValidUserOperationsReceiveSuccessiveScopesInOneBundle() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](2);
        operations[0] = _signedOperation(0, _successCall(1, "first"));
        operations[1] = _signedOperation(1, _successCall(2, "second"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(target.count(), 2, "both UserOperations must execute");
        assertEq(target.total(), 3, "bundle target total");
        vm.prank(account);
        assertEq(CheckpointTableHarness(account).invocationCounter(), 2, "bundle invocation counter");
        vm.prank(account);
        (bool firstPresent,, uint256 firstBalance) =
            CheckpointTableHarness(account).checkpointRecord(1, REUSED_CHECKPOINT_ID);
        vm.prank(account);
        (bool secondPresent,, uint256 secondBalance) =
            CheckpointTableHarness(account).checkpointRecord(2, REUSED_CHECKPOINT_ID);
        assertTrue(firstPresent && secondPresent, "bundle scopes absent");
        assertEq(firstBalance, 211, "first scope balance");
        assertEq(secondBalance, 211, "second scope balance");
    }

    function test_RevertedUserOperationBetweenSuccessesRollsBackTentativeScope() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](3);
        operations[0] = _signedOperation(0, _successCall(3, "before-revert"));
        operations[1] = _signedOperation(1, _failureCall(5, "reverted"));
        operations[2] = _signedOperation(2, _successCall(7, "after-revert"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(target.count(), 2, "bundle must continue after failed execution");
        assertEq(target.total(), 10, "only successful operations count");
        vm.prank(account);
        assertEq(CheckpointTableHarness(account).invocationCounter(), 2, "failed scope consumed counter");
        vm.prank(account);
        (bool secondPresent,, uint256 secondBalance) =
            CheckpointTableHarness(account).checkpointRecord(2, REUSED_CHECKPOINT_ID);
        vm.prank(account);
        (bool thirdPresent,,) = CheckpointTableHarness(account).checkpointRecord(3, REUSED_CHECKPOINT_ID);
        assertTrue(secondPresent, "post-revert scope absent");
        assertEq(secondBalance, 211, "post-revert scope balance");
        assertFalse(thirdPresent, "failed operation left an extra scope");
    }

    function _signedOperation(uint256 nonce, IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;

        operation.sender = account;
        operation.nonce = nonce;
        operation.callData = abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls));
        operation.accountGasLimits = bytes32((uint256(1_000_000) << 128) | uint256(1_000_000));
        operation.preVerificationGas = 100_000;
        operation.gasFees = bytes32(0);
        operation.signature = _signature(ACCOUNT_AUTHORITY_KEY, entryPoint.getUserOpHash(operation));
    }

    function _successCall(uint256 amount, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall = _baseCall(abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)));
    }

    function _failureCall(uint256 code, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall = _baseCall(abi.encodeCall(DynamicExecutionTarget.fail, (code, payload)));
    }

    function _baseCall(bytes memory data)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = address(target);
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        dynamicCall.checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: address(token), id: REUSED_CHECKPOINT_ID});
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}
