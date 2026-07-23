// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

contract StaticCallUint256AssertionsTest is Test {
    uint32 private constant GLOBAL_READ = type(uint32).max;
    uint32 private constant SUBJECT_OFFSET = 36;
    uint32 private constant SELECTED_RETURN_OFFSET = 32;
    address private constant ORIGINAL_SUBJECT = 0x1111111111111111111111111111111111111111;
    address private constant PADDING_SUBJECT = 0x2222222222222222222222222222222222222222;
    uint256 private constant LEFT = 601;
    uint256 private constant SELECTED = 701;
    uint256 private constant RIGHT = 801;

    StaticCallUint256Assertions private assertions;
    StaticCallUint256TargetMock private target;

    function setUp() external {
        assertions = new StaticCallUint256Assertions();
        target = new StaticCallUint256TargetMock();
        target.setSubjectValue(ORIGINAL_SUBJECT, 307);
        target.setSubjectValue(address(this), SELECTED);
    }

    function test_AccountBoundAtLeastUsesReplacedCallerAndPassesAtEqualityAndAbove() external view {
        bytes memory data = _subjectTupleData(ORIGINAL_SUBJECT);

        assertions.assertStaticCallUint256AtLeast(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED
        );
        assertions.assertStaticCallUint256AtLeast(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED - 1
        );
    }

    function test_AccountBoundAtMostUsesReplacedCallerAndPassesAtEqualityAndBelow() external view {
        bytes memory data = _subjectTupleData(ORIGINAL_SUBJECT);

        assertions.assertStaticCallUint256AtMost(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED
        );
        assertions.assertStaticCallUint256AtMost(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED + 1
        );
    }

    function test_AccountBoundThresholdFailuresCarryCompleteContext() external {
        bytes memory data = _subjectTupleData(ORIGINAL_SUBJECT);
        bytes4 selector = StaticCallUint256TargetMock.subjectTuple.selector;

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                address(target),
                selector,
                uint256(SUBJECT_OFFSET),
                uint256(SELECTED_RETURN_OFFSET),
                SELECTED,
                SELECTED + 1
            )
        );
        assertions.assertStaticCallUint256AtLeast(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                address(target),
                selector,
                uint256(SUBJECT_OFFSET),
                uint256(SELECTED_RETURN_OFFSET),
                SELECTED,
                SELECTED - 1
            )
        );
        assertions.assertStaticCallUint256AtMost(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED - 1
        );
    }

    function test_SubjectChangeProofFailsWithoutReplacementButPassesThroughChecker() external view {
        (uint256 directLeft, uint256 directSelected, uint256 directRight) =
            target.subjectTuple(LEFT, ORIGINAL_SUBJECT, RIGHT);
        assertEq(directLeft, LEFT, "direct left");
        assertEq(directSelected, 307, "direct original subject");
        assertEq(directRight, RIGHT, "direct right");

        assertions.assertStaticCallUint256AtLeast(
            address(target), _subjectTupleData(ORIGINAL_SUBJECT), SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED
        );
    }

    function test_AccountWordReplacementChangesExactlyTheExpectedCalldataBytes() external view {
        bytes memory original =
            abi.encodeCall(StaticCallUint256TargetMock.calldataHash, (LEFT, ORIGINAL_SUBJECT, RIGHT));
        bytes memory expected = abi.encodeCall(StaticCallUint256TargetMock.calldataHash, (LEFT, address(this), RIGHT));
        uint256 expectedHash = uint256(keccak256(expected));

        assertions.assertStaticCallUint256AtLeast(address(target), original, SUBJECT_OFFSET, 0, expectedHash);
        assertions.assertStaticCallUint256AtMost(address(target), original, SUBJECT_OFFSET, 0, expectedHash);
    }

    function test_AdjacentReturnWordsRemainDistinctAndSelectable() external view {
        bytes memory data = _subjectTupleData(ORIGINAL_SUBJECT);

        assertions.assertStaticCallUint256AtLeast(address(target), data, SUBJECT_OFFSET, 0, LEFT);
        assertions.assertStaticCallUint256AtMost(address(target), data, SUBJECT_OFFSET, 0, LEFT);
        assertions.assertStaticCallUint256AtLeast(
            address(target), data, SUBJECT_OFFSET, SELECTED_RETURN_OFFSET, SELECTED
        );
        assertions.assertStaticCallUint256AtMost(address(target), data, SUBJECT_OFFSET, 64, RIGHT);
    }

    function test_GlobalReadLeavesCalldataUnmodifiedForBothDirections() external view {
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));

        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED);
        assertions.assertStaticCallUint256AtMost(address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED);
    }

    function test_GlobalReadThresholdFailuresUseExplicitSentinel() external {
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));
        bytes4 selector = StaticCallUint256TargetMock.globalTuple.selector;

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                address(target),
                selector,
                uint256(GLOBAL_READ),
                uint256(SELECTED_RETURN_OFFSET),
                SELECTED,
                SELECTED + 1
            )
        );
        assertions.assertStaticCallUint256AtLeast(
            address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                address(target),
                selector,
                uint256(GLOBAL_READ),
                uint256(SELECTED_RETURN_OFFSET),
                SELECTED,
                SELECTED - 1
            )
        );
        assertions.assertStaticCallUint256AtMost(
            address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED - 1
        );
    }

    function test_TrailingPaddingCanPatchUnusedWordWithoutBindingRealSubject() external view {
        bytes memory realCall = abi.encodeCall(StaticCallUint256TargetMock.subjectValue, (ORIGINAL_SUBJECT));
        bytes memory padded = bytes.concat(realCall, abi.encode(PADDING_SUBJECT));

        assertions.assertStaticCallUint256AtLeast(address(target), padded, SUBJECT_OFFSET, 0, 307);
        assertions.assertStaticCallUint256AtMost(address(target), padded, SUBJECT_OFFSET, 0, 307);
    }

    function test_ZeroAndSelfTargetsAreRejectedBeforeCalldataValidation() external {
        bytes memory tooShort = hex"12";

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionTarget.selector, address(0))
        );
        assertions.assertStaticCallUint256AtLeast(address(0), tooShort, GLOBAL_READ, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionTarget.selector, address(assertions))
        );
        assertions.assertStaticCallUint256AtMost(address(assertions), tooShort, GLOBAL_READ, 0, 0);
    }

    function test_CalldataMustContainCompleteSelector() external {
        for (uint256 length = 0; length < 4; ++length) {
            bytes memory data = new bytes(length);
            vm.expectRevert(
                abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionCallData.selector, length)
            );
            assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 0, 0);
        }
    }

    function test_AccountOffsetRejectsLowerBoundAlignmentAndUpperBoundViolations() external {
        bytes memory data = _subjectTupleData(ORIGINAL_SUBJECT);
        uint32[3] memory invalidOffsets = [uint32(3), uint32(5), uint32(100)];

        for (uint256 i; i < invalidOffsets.length; ++i) {
            uint256 offset = uint256(invalidOffsets[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, offset, data.length
                )
            );
            assertions.assertStaticCallUint256AtLeast(address(target), data, invalidOffsets[i], 0, 0);
        }
    }

    function test_ReturnOffsetRejectsUnalignedAndOutOfBoundsWords() external {
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 1, 96)
        );
        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 96, 96)
        );
        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 96, 0);
    }

    function test_EmptyShortExactAndLongerReturnDataAreDistinguished() external {
        bytes memory emptyData = abi.encodeCall(StaticCallUint256TargetMock.emptyReturn, ());
        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 0)
        );
        assertions.assertStaticCallUint256AtLeast(address(target), emptyData, GLOBAL_READ, 0, 0);

        bytes memory shortData = abi.encodeCall(StaticCallUint256TargetMock.shortReturn, ());
        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 3)
        );
        assertions.assertStaticCallUint256AtLeast(address(target), shortData, GLOBAL_READ, 0, 0);

        bytes memory exactData = abi.encodeCall(StaticCallUint256TargetMock.exactReturn, (SELECTED));
        assertions.assertStaticCallUint256AtLeast(address(target), exactData, GLOBAL_READ, 0, SELECTED);

        bytes memory longerData = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));
        assertions.assertStaticCallUint256AtMost(
            address(target), longerData, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED
        );
    }

    function test_NoCodeTargetSucceedsCallButFailsReturnBounds() external {
        address noCode = address(0xBEEF);
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("read()")));

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 0)
        );
        assertions.assertStaticCallUint256AtLeast(noCode, data, GLOBAL_READ, 0, 0);
    }

    function test_StaticCallFailurePreservesSelectorModeAndCompleteReasonBeforeReturnValidation() external {
        bytes memory payload = hex"0102030405060708090a0b0c";
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.revertRead, (907, payload));
        bytes memory reason =
            abi.encodeWithSelector(StaticCallUint256TargetMock.StaticReadFailure.selector, 907, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.AssertionStaticCallFailed.selector,
                address(target),
                StaticCallUint256TargetMock.revertRead.selector,
                uint256(GLOBAL_READ),
                reason
            )
        );
        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, 1, type(uint256).max);
    }

    function test_ChecksEmitNoCustomEvents() external {
        bytes memory data = abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (LEFT, SELECTED, RIGHT));

        vm.recordLogs();
        assertions.assertStaticCallUint256AtLeast(address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED);
        assertions.assertStaticCallUint256AtMost(address(target), data, GLOBAL_READ, SELECTED_RETURN_OFFSET, SELECTED);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected checker event");
    }

    function test_DirectDeploymentRuntimeMatchesIndependentImmutableArtifact() external view {
        assertEq(address(assertions).code, type(StaticCallUint256Assertions).runtimeCode, "runtime artifact mismatch");
        assertEq(address(assertions).codehash, keccak256(type(StaticCallUint256Assertions).runtimeCode));
    }

    function _subjectTupleData(address subject) private pure returns (bytes memory) {
        return abi.encodeCall(StaticCallUint256TargetMock.subjectTuple, (LEFT, subject, RIGHT));
    }
}
