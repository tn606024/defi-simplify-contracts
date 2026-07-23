// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Verifies language-neutral callback ABI fixtures against Solidity encoding.
contract CallbackGoldenVectorsTest is Test {
    string private constant FIXTURE_PATH = "abi/CallbackExecution.golden.json";
    address private constant FIRST_ADDRESS = 0x1111111111111111111111111111111111111111;
    address private constant SECOND_ADDRESS = 0x2222222222222222222222222222222222222222;
    address private constant TARGET = 0x3333333333333333333333333333333333333333;
    bytes32 private constant EXPECTED_HASH = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 private constant ACTUAL_HASH = 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;

    function test_FinalSelectorsAndInterfaceIdMatchGoldenFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        assertEq(
            _parseBytes4(fixture, ".selectors.executeBatchDynamic"),
            IDefiSimplify7702Account.executeBatchDynamic.selector,
            "final executeBatchDynamic selector"
        );
        assertEq(
            _parseBytes4(fixture, ".selectors.executeOperation"),
            IDefiSimplify7702Account.executeOperation.selector,
            "executeOperation selector"
        );
        assertEq(
            _parseBytes4(fixture, ".selectors.interfaceId"),
            type(IDefiSimplify7702Account).interfaceId,
            "callback-enabled interface ID"
        );
    }

    function test_DynamicCallBooleanValuesMatchGoldenFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        assertEq(
            vm.parseJsonBytes(fixture, ".dynamicCallFalseEncoding"),
            abi.encode(_buildCall(FIRST_ADDRESS, 7, hex"12345678", false)),
            "ordinary DynamicCall encoding"
        );
        assertEq(
            vm.parseJsonBytes(fixture, ".dynamicCallTrueEncoding"),
            abi.encode(_buildCall(FIRST_ADDRESS, 7, hex"12345678", true)),
            "callback-enabled DynamicCall encoding"
        );
    }

    function test_EmptyOneAndManyCallEnvelopesMatchGoldenFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        IDefiSimplify7702Account.CallbackEnvelope memory emptyEnvelope;
        emptyEnvelope.maxPremium = 11;
        emptyEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](0);
        assertEq(
            vm.parseJsonBytes(fixture, ".emptyEnvelopeEncoding"), abi.encode(emptyEnvelope), "empty callback envelope"
        );

        IDefiSimplify7702Account.CallbackEnvelope memory oneCallEnvelope;
        oneCallEnvelope.maxPremium = 22;
        oneCallEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        oneCallEnvelope.callbackCalls[0] = _buildCall(FIRST_ADDRESS, 7, hex"12345678", false);
        assertEq(
            vm.parseJsonBytes(fixture, ".oneCallEnvelopeEncoding"),
            abi.encode(oneCallEnvelope),
            "one-call callback envelope"
        );

        IDefiSimplify7702Account.CallbackEnvelope memory manyCallEnvelope;
        manyCallEnvelope.maxPremium = 33;
        manyCallEnvelope.callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        manyCallEnvelope.callbackCalls[0] = _buildCall(FIRST_ADDRESS, 7, hex"12345678", false);
        manyCallEnvelope.callbackCalls[1] = _buildCall(SECOND_ADDRESS, 8, hex"abcdef", true);
        assertEq(
            vm.parseJsonBytes(fixture, ".manyCallEnvelopeEncoding"),
            abi.encode(manyCallEnvelope),
            "many-call callback envelope"
        );
    }

    function test_EveryCallbackCustomErrorMatchesGoldenFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes memory reason = hex"deadbeef";

        _assertGoldenError(
            fixture,
            "MultipleExpectedCallbacks",
            abi.encodeWithSelector(IDefiSimplify7702Account.MultipleExpectedCallbacks.selector, 1, 2)
        );
        _assertGoldenError(
            fixture,
            "CallbackOutsideDynamicExecution",
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackOutsideDynamicExecution.selector)
        );
        _assertGoldenError(
            fixture,
            "CallbackNotAwaiting",
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 1, uint8(2))
        );
        _assertGoldenError(
            fixture,
            "UnexpectedCallbackSender",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.UnexpectedCallbackSender.selector, 1, FIRST_ADDRESS, SECOND_ADDRESS
            )
        );
        _assertGoldenError(
            fixture,
            "UnexpectedCallbackInitiator",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.UnexpectedCallbackInitiator.selector, 1, FIRST_ADDRESS, SECOND_ADDRESS
            )
        );
        _assertGoldenError(
            fixture,
            "CallbackOriginMismatch",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CallbackOriginMismatch.selector, 1, EXPECTED_HASH, ACTUAL_HASH
            )
        );
        _assertGoldenError(
            fixture,
            "CallbackNotConsumed",
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotConsumed.selector, 1, TARGET, uint8(3))
        );
        _assertGoldenError(
            fixture,
            "NestedCallbackNotSupported",
            abi.encodeWithSelector(IDefiSimplify7702Account.NestedCallbackNotSupported.selector, 1, 2)
        );
        _assertGoldenError(
            fixture,
            "FlashLoanPremiumTooHigh",
            abi.encodeWithSelector(IDefiSimplify7702Account.FlashLoanPremiumTooHigh.selector, 1, 100, 99)
        );
        _assertGoldenError(
            fixture,
            "FlashLoanRepaymentBalanceInsufficient",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanRepaymentBalanceInsufficient.selector, 1, FIRST_ADDRESS, 99, 100
            )
        );
        _assertGoldenError(
            fixture,
            "FlashLoanRepaymentBalanceReadFailed",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanRepaymentBalanceReadFailed.selector, 1, FIRST_ADDRESS, reason
            )
        );
        _assertGoldenError(
            fixture,
            "FlashLoanRepaymentApprovalFailed",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanRepaymentApprovalFailed.selector, 1, FIRST_ADDRESS, TARGET, reason
            )
        );
        _assertGoldenError(
            fixture,
            "FlashLoanAllowanceReadFailed",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanAllowanceReadFailed.selector, 1, FIRST_ADDRESS, TARGET, reason
            )
        );
        _assertGoldenError(
            fixture,
            "ResidualFlashLoanAllowance",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.ResidualFlashLoanAllowance.selector, 1, FIRST_ADDRESS, TARGET, 7
            )
        );
        _assertGoldenError(
            fixture,
            "CallbackDynamicCallFailed",
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackDynamicCallFailed.selector, 1, 2, TARGET, reason)
        );
    }

    function _buildCall(address target, uint256 value, bytes memory data, bool expectsCallback)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = target;
        dynamicCall.value = value;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
        dynamicCall.expectsCallback = expectsCallback;
    }

    function _assertGoldenError(string memory fixture, string memory errorName, bytes memory actual) private pure {
        assertEq(vm.parseJsonBytes(fixture, string.concat(".errors.", errorName)), actual, errorName);
    }

    function _parseBytes4(string memory fixture, string memory key) private pure returns (bytes4 value) {
        bytes memory encoded = vm.parseJsonBytes(fixture, key);
        assertEq(encoded.length, 4, key);
        assembly ("memory-safe") {
            value := mload(add(encoded, 32))
        }
    }
}
