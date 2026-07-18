// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {CheckpointBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CheckpointIsolationHandler {
    bytes32 private constant REUSED_CHECKPOINT_ID = keccak256("invariant-reused-checkpoint");

    IDefiSimplify7702Account private _account;
    DynamicExecutionTarget private _target;
    address private _token;
    bool private _configured;

    uint256 public successfulInvocations;
    uint256 public revertedAndRecoveredInvocations;

    function configure(address account, DynamicExecutionTarget target, address token) external {
        require(!_configured, "already configured");
        _account = IDefiSimplify7702Account(account);
        _target = target;
        _token = token;
        _configured = true;
    }

    function executeWithReusedId(uint96 amount) external {
        _executeRecord(amount);
        ++successfulInvocations;
    }

    function revertThenExecuteWithReusedId(uint96 amount) external {
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(abi.encodeCall(DynamicExecutionTarget.fail, (uint256(amount), bytes("invariant-revert"))));
        (bool success,) = address(_account).call(abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)));
        require(!success, "target failure unexpectedly succeeded");

        _executeRecord(amount);
        ++successfulInvocations;
        ++revertedAndRecoveredInvocations;
    }

    function _executeRecord(uint96 amount) private {
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(abi.encodeCall(DynamicExecutionTarget.record, (uint256(amount), bytes("invariant-success"))));
        _account.executeBatchDynamic(calls);
    }

    function _singleCall(bytes memory data) private view returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(_target);
        calls[0].data = data;
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        calls[0].checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: _token, id: REUSED_CHECKPOINT_ID});
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }
}

contract CheckpointIsolationInvariant is DelegatedAccountFixture {
    CheckpointIsolationHandler private handler;
    DynamicExecutionTarget private target;

    function setUp() external {
        handler = new CheckpointIsolationHandler();
        DelegatedPair memory pair = _deployDelegatedPair(IEntryPoint(address(handler)));
        target = new DynamicExecutionTarget();
        CheckpointBalanceToken token = new CheckpointBalanceToken();
        handler.configure(pair.customAccount, target, address(token));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = CheckpointIsolationHandler.executeWithReusedId.selector;
        selectors[1] = CheckpointIsolationHandler.revertThenExecuteWithReusedId.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_EachInvocationReceivesFreshCheckpointMemory() external view {
        assertEq(target.count(), handler.successfulInvocations(), "successful invocation accounting");
    }
}
