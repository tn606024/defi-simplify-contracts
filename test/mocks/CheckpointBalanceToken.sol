// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

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
    constructor() DefiSimplify7702Account(IEntryPoint(address(1))) {}

    function capture(IDefiSimplify7702Account.BalanceCheckpoint[] calldata checkpoints, uint256 callIndex)
        external
        view
        returns (CheckpointRecord[] memory records)
    {
        records = new CheckpointRecord[](checkpoints.length);
        uint256 populatedLength = _createCheckpoints(callIndex, checkpoints, records, 0);
        assert(populatedLength == checkpoints.length);
    }
}
