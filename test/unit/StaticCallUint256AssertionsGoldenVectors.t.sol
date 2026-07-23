// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

/// @dev Verifies language-neutral generic assertion fixtures against Solidity ABI encoding.
contract StaticCallUint256AssertionsGoldenVectorsTest is Test {
    string private constant FIXTURE_PATH = "abi/StaticCallUint256Assertions.golden.json";
    address private constant READ_TARGET = 0x4444444444444444444444444444444444444444;
    address private constant PLACEHOLDER_ACCOUNT = 0x1111111111111111111111111111111111111111;
    address private constant BOUND_ACCOUNT = 0x2222222222222222222222222222222222222222;
    uint32 private constant ACCOUNT_ARGUMENT_OFFSET = 36;
    uint32 private constant ACCOUNT_VALUE_RETURN_OFFSET = 32;
    uint32 private constant GLOBAL_VALUE_RETURN_OFFSET = 32;
    uint32 private constant NO_ACCOUNT_BINDING = type(uint32).max;
    uint256 private constant LEADING_SENTINEL = 601;
    uint256 private constant GLOBAL_RETURN_VALUE = 701;
    uint256 private constant TRAILING_SENTINEL = 801;

    function test_GoldenAccountBoundAndGlobalCalldataMatchFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes memory placeholderAccountCall = abi.encodeCall(
            StaticCallUint256TargetMock.accountValueWithSentinels,
            (LEADING_SENTINEL, PLACEHOLDER_ACCOUNT, TRAILING_SENTINEL)
        );
        bytes memory boundAccountCall = abi.encodeCall(
            StaticCallUint256TargetMock.accountValueWithSentinels, (LEADING_SENTINEL, BOUND_ACCOUNT, TRAILING_SENTINEL)
        );
        bytes memory globalReadCall = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );

        assertEq(vm.parseJsonUint(fixture, ".version"), 1, "fixture version");
        assertEq(vm.parseJsonAddress(fixture, ".readTarget"), READ_TARGET, "read target");
        assertEq(vm.parseJsonAddress(fixture, ".placeholderAccount"), PLACEHOLDER_ACCOUNT, "placeholder account");
        assertEq(vm.parseJsonAddress(fixture, ".boundAccount"), BOUND_ACCOUNT, "bound account");
        assertEq(
            vm.parseJsonUint(fixture, ".accountArgumentOffset"), ACCOUNT_ARGUMENT_OFFSET, "account argument offset"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".accountValueReturnOffset"),
            ACCOUNT_VALUE_RETURN_OFFSET,
            "account value return offset"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".globalValueReturnOffset"),
            GLOBAL_VALUE_RETURN_OFFSET,
            "global value return offset"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".noAccountBindingSentinel"), NO_ACCOUNT_BINDING, "no-account-binding sentinel"
        );
        assertEq(vm.parseJsonUint(fixture, ".leadingSentinel"), LEADING_SENTINEL, "leading sentinel");
        assertEq(vm.parseJsonUint(fixture, ".globalReturnValue"), GLOBAL_RETURN_VALUE, "global return value");
        assertEq(vm.parseJsonUint(fixture, ".trailingSentinel"), TRAILING_SENTINEL, "trailing sentinel");
        assertEq(
            vm.parseJsonBytes(fixture, ".placeholderAccountTargetCalldata"),
            placeholderAccountCall,
            "placeholder account calldata"
        );
        assertEq(vm.parseJsonBytes(fixture, ".boundAccountTargetCalldata"), boundAccountCall, "bound account calldata");
        assertEq(vm.parseJsonBytes(fixture, ".globalReadTargetCalldata"), globalReadCall, "global read calldata");
        assertEq(
            vm.parseJsonBytes(fixture, ".accountBoundAtLeastCalldata"),
            abi.encodeCall(
                IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
                (
                    READ_TARGET,
                    placeholderAccountCall,
                    ACCOUNT_ARGUMENT_OFFSET,
                    ACCOUNT_VALUE_RETURN_OFFSET,
                    uint256(700)
                )
            ),
            "account-bound checker calldata"
        );
        assertEq(
            vm.parseJsonBytes(fixture, ".globalAtMostCalldata"),
            abi.encodeCall(
                IStaticCallUint256Assertions.assertStaticCallUint256AtMost,
                (READ_TARGET, globalReadCall, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, uint256(702))
            ),
            "global checker calldata"
        );
    }

    function test_GoldenIndexedErrorsMatchFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        _assertGoldenErrorEncoding(
            fixture,
            "InvalidAssertionTarget",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionTarget.selector, READ_TARGET)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidAssertionAccountOffset",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, 5, 100)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidAssertionReturnOffset",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 96, 96)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "StaticCallUint256BelowMinimum",
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                READ_TARGET,
                StaticCallUint256TargetMock.accountValueWithSentinels.selector,
                uint256(ACCOUNT_ARGUMENT_OFFSET),
                uint256(ACCOUNT_VALUE_RETURN_OFFSET),
                uint256(699),
                uint256(700)
            )
        );
        _assertGoldenErrorEncoding(
            fixture,
            "StaticCallUint256AboveMaximum",
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                READ_TARGET,
                StaticCallUint256TargetMock.globalTuple.selector,
                uint256(NO_ACCOUNT_BINDING),
                uint256(GLOBAL_VALUE_RETURN_OFFSET),
                uint256(703),
                uint256(702)
            )
        );
    }

    function _assertGoldenErrorEncoding(string memory fixture, string memory errorName, bytes memory actual)
        private
        pure
    {
        assertEq(vm.parseJsonBytes(fixture, string.concat(".errors.", errorName)), actual, errorName);
    }
}
