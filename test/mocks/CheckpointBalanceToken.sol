// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

contract CheckpointBalanceToken {
    mapping(address account => uint256 balance) private _balances;

    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

contract PreCallCheckpointToken {
    error UnexpectedBalanceAccount(address actual, address expected);
    error UnexpectedTargetCount(uint256 actual, uint256 expected);

    address private immutable _expectedAccount;
    address private immutable _target;
    uint256 private immutable _expectedTargetCount;
    uint256 private immutable _balance;

    constructor(address expectedAccount, address target, uint256 expectedTargetCount, uint256 balance) {
        _expectedAccount = expectedAccount;
        _target = target;
        _expectedTargetCount = expectedTargetCount;
        _balance = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (account != _expectedAccount) {
            revert UnexpectedBalanceAccount(account, _expectedAccount);
        }

        (bool success, bytes memory returnData) = _target.staticcall(abi.encodeWithSignature("count()"));
        require(success && returnData.length >= 32, "target count read failed");
        uint256 targetCount = abi.decode(returnData, (uint256));
        if (targetCount != _expectedTargetCount) {
            revert UnexpectedTargetCount(targetCount, _expectedTargetCount);
        }

        return _balance;
    }
}

contract RevertingCheckpointToken {
    error BalanceReadFailure(uint256 code, bytes payload);

    uint256 private immutable _code;
    bytes private _payload;

    constructor(uint256 code, bytes memory payload) {
        _code = code;
        _payload = payload;
    }

    function balanceOf(address) external view returns (uint256) {
        revert BalanceReadFailure(_code, _payload);
    }
}

contract ShortReturnCheckpointToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 0x1234)
            return(30, 2)
        }
    }
}

contract EmptyReturnCheckpointToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract CheckpointTableHarness is DefiSimplify7702Account {
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    constructor(IEntryPoint entryPoint) DefiSimplify7702Account(entryPoint) {}

    function checkpointNamespaces()
        external
        pure
        returns (bytes32 lockSlot, bytes32 counterSlot, bytes32 tableNamespace)
    {
        return (_DYNAMIC_EXECUTION_LOCK_SLOT, _DYNAMIC_INVOCATION_COUNTER_SLOT, _CHECKPOINT_TABLE_NAMESPACE);
    }

    function invocationCounter() external view returns (uint256) {
        _requireForExecute();
        return _DYNAMIC_INVOCATION_COUNTER_SLOT.asUint256().tload();
    }

    function checkpointRecord(uint256 invocationId, bytes32 checkpointId)
        external
        view
        returns (bool present, address token, uint256 balance)
    {
        _requireForExecute();
        return _loadCheckpointRecord(invocationId, checkpointId);
    }

    function probeCheckpoints(uint256 invocationId, bytes32[] calldata checkpointIds, uint256 repetitions)
        external
        view
        returns (uint256 sum)
    {
        _requireForExecute();
        for (uint256 repetition = 0; repetition < repetitions; ++repetition) {
            for (uint256 i = 0; i < checkpointIds.length; ++i) {
                (bool present, address token, uint256 balance) = _loadCheckpointRecord(invocationId, checkpointIds[i]);
                require(present && token != address(0), "checkpoint probe missing");
                sum += balance;
            }
        }
    }

    function checkpointRecordRoot(uint256 invocationId, bytes32 checkpointId) external pure returns (bytes32) {
        return _checkpointRecordRoot(invocationId, checkpointId);
    }

    function _loadCheckpointRecord(uint256 invocationId, bytes32 checkpointId)
        private
        view
        returns (bool present, address token, uint256 balance)
    {
        bytes32 recordRoot = _checkpointRecordRoot(invocationId, checkpointId);
        present = recordRoot.asBoolean().tload();
        token = recordRoot.offset(1).asAddress().tload();
        balance = recordRoot.offset(2).asUint256().tload();
    }
}

contract TransientProbeTarget {
    bytes32 public lastObserved;

    function probe(bytes32 slot) external {
        bytes32 observed;
        assembly ("memory-safe") {
            observed := tload(slot)
        }
        lastObserved = observed;
    }

    function queryCheckpointHarness(address account, uint256 invocationId, bytes32 checkpointId) external view {
        CheckpointTableHarness(payable(account)).checkpointRecord(invocationId, checkpointId);
    }
}

contract RevertingCheckpointEntryPoint {
    error ContainingFrameReverted();

    function invoke(address account, IDefiSimplify7702Account.DynamicCall[] calldata calls) external {
        IDefiSimplify7702Account(account).executeBatchDynamic(calls);
        revert ContainingFrameReverted();
    }
}
