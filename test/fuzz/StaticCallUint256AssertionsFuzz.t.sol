// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

contract StaticCallUint256AssertionsFuzzTest is Test {
    uint32 private constant GLOBAL_READ = type(uint32).max;
    uint32 private constant SUBJECT_OFFSET = 36;

    StaticCallUint256Assertions private assertions;
    StaticCallUint256TargetMock private target;

    function setUp() external {
        assertions = new StaticCallUint256Assertions();
        target = new StaticCallUint256TargetMock();
    }

    function testFuzz_AccountReplacementMatchesIndependentByteModel(
        uint256 left,
        address originalSubject,
        uint256 right
    ) external view {
        bytes memory original = abi.encodeCall(StaticCallUint256TargetMock.calldataHash, (left, originalSubject, right));
        bytes memory expected = abi.encodeCall(StaticCallUint256TargetMock.calldataHash, (left, address(this), right));
        uint256 expectedHash = uint256(keccak256(expected));

        assertions.assertStaticCallUint256AtLeast(address(target), original, SUBJECT_OFFSET, 0, expectedHash);
        assertions.assertStaticCallUint256AtMost(address(target), original, SUBJECT_OFFSET, 0, expectedHash);
    }

    function testFuzz_GlobalReadComparisonMatchesUnsignedBounds(uint256 actual, uint256 bound) external {
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.exactReturn, (actual));

        if (actual >= bound) {
            assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 0, bound);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                    address(target),
                    StaticCallUint256TargetMock.exactReturn.selector,
                    uint256(GLOBAL_READ),
                    0,
                    actual,
                    bound
                )
            );
            assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 0, bound);
        }

        if (actual <= bound) {
            assertions.assertStaticCallUint256AtMost(address(target), data, GLOBAL_READ, 0, bound);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                    address(target),
                    StaticCallUint256TargetMock.exactReturn.selector,
                    uint256(GLOBAL_READ),
                    0,
                    actual,
                    bound
                )
            );
            assertions.assertStaticCallUint256AtMost(address(target), data, GLOBAL_READ, 0, bound);
        }
    }

    function testFuzz_AccountOffsetValidationMatchesSelectorRelativeWordModel(uint32 accountOffset) external {
        vm.assume(accountOffset != GLOBAL_READ);
        bytes memory data =
            abi.encodeCall(StaticCallUint256TargetMock.subjectTuple, (uint256(11), address(0x1234), uint256(13)));
        uint256 offset = uint256(accountOffset);
        bool valid = offset >= 4 && (offset - 4) % 32 == 0 && offset + 32 <= data.length;

        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, offset, data.length
                )
            );
        }
        assertions.assertStaticCallUint256AtLeast(address(target), data, accountOffset, 0, 0);
    }

    function testFuzz_ReturnOffsetValidationMatchesFixedWordModel(uint32 returnOffset) external {
        bytes memory data =
            abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (uint256(17), uint256(19), uint256(23)));
        uint256 offset = uint256(returnOffset);
        bool valid = offset % 32 == 0 && offset + 32 <= 96;

        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, offset, 96)
            );
        }
        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, returnOffset, 0);
    }
}
