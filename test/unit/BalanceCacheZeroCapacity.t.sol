// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

contract ZeroCapacityBalanceCacheTarget {
    uint256 public callCount;

    function recordCall() external {
        ++callCount;
    }

    fallback() external {}
}

/// @dev Proves that calls with no patch/checkpoint metadata remain executable
///      when the account leaves both zero-capacity cache arrays unallocated.
contract BalanceCacheZeroCapacityTest is DelegatedAccountFixture {
    DelegatedDefiSimplifyAccount private accountUnderTest;
    ZeroCapacityBalanceCacheTarget private executionTarget;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        executionTarget = new ZeroCapacityBalanceCacheTarget();
    }

    function test_ZeroCapacityCacheExecutesCallWithoutBalanceMetadata() external {
        IDefiSimplify7702Account.DynamicCall memory ordinaryCall = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(executionTarget), abi.encodeCall(ZeroCapacityBalanceCacheTarget.recordCall, ())
        );

        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeBatchDynamic(DynamicCallTestBuilder.singleCall(ordinaryCall));

        assertEq(executionTarget.callCount(), 1, "zero-capacity target call");
    }

    function test_Gas_ZeroCapacityBalanceCacheCall() external {
        IDefiSimplify7702Account.DynamicCall memory ordinaryCall =
            DynamicCallTestBuilder.buildZeroValueOrdinaryCall(address(executionTarget), bytes(""));
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeBatchDynamic(DynamicCallTestBuilder.singleCall(ordinaryCall));
    }
}
