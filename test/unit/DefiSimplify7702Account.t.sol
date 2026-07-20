// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {StaticCallRecorder} from "../mocks/StaticCallRecorder.sol";

contract DefiSimplify7702AccountTest {
    function test_DeploysDirectlyWithImmutableEntryPoint() external {
        DefiSimplify7702Account account = _deployAccount();

        require(address(account).code.length != 0, "account was not deployed");
        require(address(account.entryPoint()) == address(this), "unexpected EntryPoint");
    }

    function test_ConfiguredEntryPointCanUseInheritedExecute() external {
        DefiSimplify7702Account account = _deployAccount();
        StaticCallRecorder recorder = new StaticCallRecorder();

        account.execute(address(recorder), 0, abi.encodeCall(StaticCallRecorder.record, (42)));

        require(recorder.caller() == address(account), "target did not observe account caller");
        require(recorder.value() == 42, "target did not execute");
    }

    function test_AccountSelfCallCanUseInheritedExecute() external {
        DefiSimplify7702Account account = _deployAccount();
        StaticCallRecorder recorder = new StaticCallRecorder();
        bytes memory targetCall = abi.encodeCall(StaticCallRecorder.record, (84));
        bytes memory selfCall = abi.encodeCall(BaseAccount.execute, (address(recorder), 0, targetCall));

        account.execute(address(account), 0, selfCall);

        require(recorder.caller() == address(account), "self-call target did not observe account caller");
        require(recorder.value() == 84, "self-call target did not execute");
    }

    function test_ConfiguredEntryPointCanUseInheritedExecuteBatch() external {
        DefiSimplify7702Account account = _deployAccount();
        StaticCallRecorder recorder = new StaticCallRecorder();
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({
            target: address(recorder), value: 0, data: abi.encodeCall(StaticCallRecorder.record, (126))
        });

        account.executeBatch(calls);

        require(recorder.caller() == address(account), "batch target did not observe account caller");
        require(recorder.value() == 126, "batch target did not execute");
    }

    function _deployAccount() internal returns (DefiSimplify7702Account) {
        return new DefiSimplify7702Account(IEntryPoint(address(this)));
    }
}
