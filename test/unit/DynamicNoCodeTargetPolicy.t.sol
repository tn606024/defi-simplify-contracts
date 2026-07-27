// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

contract DynamicNoCodeTargetPolicyTest is DelegatedAccountFixture {
    address private constant NO_CODE_PROTOCOL_LIKE_TARGET = address(0xC0DE);

    DelegatedDefiSimplifyAccount private accountUnderTest;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        vm.deal(accountUnderTest.delegatedEoa, 10 ether);
    }

    function test_DynamicCallToNoCodeTargetWithCalldataRetainsGenericEvmSuccess() external {
        assertEq(NO_CODE_PROTOCOL_LIKE_TARGET.code.length, 0, "fixture target must have no code");
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueOrdinaryCall(NO_CODE_PROTOCOL_LIKE_TARGET, hex"12345678");

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(NO_CODE_PROTOCOL_LIKE_TARGET.code.length, 0, "execution must not create target code");
    }

    function test_DynamicCallToNoCodeTargetWithValueTransfersNativeEth() external {
        assertEq(NO_CODE_PROTOCOL_LIKE_TARGET.code.length, 0, "fixture target must have no code");
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildOrdinaryCall(NO_CODE_PROTOCOL_LIKE_TARGET, 0.4 ether, hex"12345678");

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(NO_CODE_PROTOCOL_LIKE_TARGET.balance, 0.4 ether, "no-code target must receive declared value");
        assertEq(accountUnderTest.delegatedEoa.balance, 9.6 ether, "delegated account must fund declared value");
    }
}
