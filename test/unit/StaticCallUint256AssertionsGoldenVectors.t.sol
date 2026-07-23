// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

/// @dev Verifies language-neutral generic assertion fixtures against Solidity ABI encoding.
contract StaticCallUint256AssertionsGoldenVectorsTest is Test {
    string private constant FIXTURE_PATH = "abi/StaticCallUint256Assertions.golden.json";
    address private constant TARGET = 0x4444444444444444444444444444444444444444;
    address private constant ORIGINAL_SUBJECT = 0x1111111111111111111111111111111111111111;
    address private constant BOUND_SUBJECT = 0x2222222222222222222222222222222222222222;
    uint32 private constant ACCOUNT_OFFSET = 36;
    uint32 private constant RETURN_OFFSET = 32;
    uint32 private constant GLOBAL_READ = type(uint32).max;
    uint256 private constant LEFT = 601;
    uint256 private constant SELECTED = 701;
    uint256 private constant RIGHT = 801;

    function test_GoldenAccountBoundAndGlobalCalldataMatchFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes memory original =
            abi.encodeCall(StaticCallUint256TargetMock.subjectTuple, (LEFT, ORIGINAL_SUBJECT, RIGHT));
        bytes memory patched = abi.encodeCall(StaticCallUint256TargetMock.subjectTuple, (LEFT, BOUND_SUBJECT, RIGHT));
        bytes memory global = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));

        assertEq(vm.parseJsonUint(fixture, ".version"), 1, "fixture version");
        assertEq(vm.parseJsonAddress(fixture, ".target"), TARGET, "fixture target");
        assertEq(vm.parseJsonAddress(fixture, ".originalSubject"), ORIGINAL_SUBJECT, "original subject");
        assertEq(vm.parseJsonAddress(fixture, ".boundSubject"), BOUND_SUBJECT, "bound subject");
        assertEq(vm.parseJsonUint(fixture, ".accountOffset"), ACCOUNT_OFFSET, "account offset");
        assertEq(vm.parseJsonUint(fixture, ".returnOffset"), RETURN_OFFSET, "return offset");
        assertEq(vm.parseJsonUint(fixture, ".globalReadSentinel"), GLOBAL_READ, "global sentinel");
        assertEq(vm.parseJsonUint(fixture, ".leftReturnWord"), LEFT, "left word");
        assertEq(vm.parseJsonUint(fixture, ".selectedReturnWord"), SELECTED, "selected word");
        assertEq(vm.parseJsonUint(fixture, ".rightReturnWord"), RIGHT, "right word");
        assertEq(vm.parseJsonBytes(fixture, ".accountBoundTargetCalldata"), original, "original calldata");
        assertEq(vm.parseJsonBytes(fixture, ".patchedTargetCalldata"), patched, "patched calldata");
        assertEq(vm.parseJsonBytes(fixture, ".globalTargetCalldata"), global, "global calldata");
        assertEq(
            vm.parseJsonBytes(fixture, ".accountBoundAtLeastCalldata"),
            abi.encodeCall(
                IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
                (TARGET, original, ACCOUNT_OFFSET, RETURN_OFFSET, uint256(700))
            ),
            "account-bound checker calldata"
        );
        assertEq(
            vm.parseJsonBytes(fixture, ".globalAtMostCalldata"),
            abi.encodeCall(
                IStaticCallUint256Assertions.assertStaticCallUint256AtMost,
                (TARGET, global, GLOBAL_READ, RETURN_OFFSET, uint256(702))
            ),
            "global checker calldata"
        );
    }

    function test_GoldenIndexedErrorsMatchFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        _assertError(
            fixture,
            "InvalidAssertionTarget",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionTarget.selector, TARGET)
        );
        _assertError(
            fixture,
            "InvalidAssertionAccountOffset",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, 5, 100)
        );
        _assertError(
            fixture,
            "InvalidAssertionReturnOffset",
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 96, 96)
        );
        _assertError(
            fixture,
            "StaticCallUint256BelowMinimum",
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                TARGET,
                StaticCallUint256TargetMock.subjectTuple.selector,
                uint256(ACCOUNT_OFFSET),
                uint256(RETURN_OFFSET),
                uint256(699),
                uint256(700)
            )
        );
        _assertError(
            fixture,
            "StaticCallUint256AboveMaximum",
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                TARGET,
                StaticCallUint256TargetMock.globalTuple.selector,
                uint256(GLOBAL_READ),
                uint256(RETURN_OFFSET),
                uint256(703),
                uint256(702)
            )
        );
    }

    function _assertError(string memory fixture, string memory errorName, bytes memory actual) private pure {
        assertEq(vm.parseJsonBytes(fixture, string.concat(".errors.", errorName)), actual, errorName);
    }
}
