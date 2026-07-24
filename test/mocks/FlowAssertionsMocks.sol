// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";
import {TransientAssertionSnapshotTable} from "../../src/libraries/TransientAssertionSnapshotTable.sol";
import {TransientTokenBalanceRecord} from "../../src/libraries/TransientTokenBalanceRecord.sol";

contract AssertionBalanceToken {
    mapping(address account => uint256 balance) private _balances;

    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function produce(uint256 amount) external {
        _balances[msg.sender] += amount;
    }

    function consume(uint256 amount) external {
        _balances[msg.sender] -= amount;
    }
}

contract RevertingAssertionBalanceToken {
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

contract ShortReturnAssertionBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 0x1234)
            return(30, 2)
        }
    }
}

contract EmptyReturnAssertionBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract AssertionCaller {
    function snapshot(IFlowAssertions assertions, address token, bytes32 checkpointId) external {
        assertions.snapshotBalance(token, checkpointId);
    }

    function assertAtLeast(IFlowAssertions assertions, address token, uint256 minimum) external view {
        assertions.assertBalanceAtLeast(token, minimum);
    }

    function assertIncrease(IFlowAssertions assertions, address token, bytes32 checkpointId, uint256 minimumDelta)
        external
        view
    {
        assertions.assertBalanceIncreaseAtLeast(token, checkpointId, minimumDelta);
    }

    function assertDecrease(IFlowAssertions assertions, address token, bytes32 checkpointId, uint256 maximumDelta)
        external
        view
    {
        assertions.assertBalanceDecreaseAtMost(token, checkpointId, maximumDelta);
    }
}

contract FlowAssertionsHarness is FlowAssertions {
    using TransientTokenBalanceRecord for bytes32;

    function snapshotTableRoot() external pure returns (bytes32) {
        return TransientAssertionSnapshotTable.root();
    }

    function snapshotRecordRoot(address account, bytes32 checkpointId) external pure returns (bytes32) {
        return _snapshotRecordRoot(account, checkpointId);
    }

    function snapshotRecord(address account, bytes32 checkpointId)
        external
        view
        returns (bool present, address token, uint256 balance)
    {
        bytes32 recordRoot = _snapshotRecordRoot(account, checkpointId);
        present = recordRoot.isPresent();
        token = recordRoot.token();
        balance = recordRoot.balance();
    }
}
