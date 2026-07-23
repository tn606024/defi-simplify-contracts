// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

contract StaticCallUint256AssertionsTest is Test {
    uint32 private constant NO_ACCOUNT_BINDING = type(uint32).max;
    uint32 private constant ACCOUNT_ARGUMENT_OFFSET = 36;
    uint32 private constant ACCOUNT_VALUE_RETURN_OFFSET = 32;
    uint32 private constant GLOBAL_VALUE_RETURN_OFFSET = 32;
    address private constant PLACEHOLDER_ACCOUNT = 0x1111111111111111111111111111111111111111;
    address private constant PADDING_ONLY_ACCOUNT = 0x2222222222222222222222222222222222222222;
    uint256 private constant PLACEHOLDER_ACCOUNT_VALUE = 307;
    uint256 private constant LEADING_SENTINEL = 601;
    uint256 private constant CALLER_ACCOUNT_VALUE = 701;
    uint256 private constant GLOBAL_RETURN_VALUE = 701;
    uint256 private constant TRAILING_SENTINEL = 801;

    StaticCallUint256Assertions private genericAssertions;
    StaticCallUint256TargetMock private tupleReadTarget;

    function setUp() external {
        genericAssertions = new StaticCallUint256Assertions();
        tupleReadTarget = new StaticCallUint256TargetMock();
        tupleReadTarget.setAccountValue(PLACEHOLDER_ACCOUNT, PLACEHOLDER_ACCOUNT_VALUE);
        tupleReadTarget.setAccountValue(address(this), CALLER_ACCOUNT_VALUE);
    }

    function test_AtLeastBindsAccountArgumentToCallerAndAcceptsSatisfiedMinimum() external view {
        bytes memory callData = _encodeAccountValueRead(PLACEHOLDER_ACCOUNT);

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE - 1
        );
    }

    function test_AtMostBindsAccountArgumentToCallerAndAcceptsSatisfiedMaximum() external view {
        bytes memory callData = _encodeAccountValueRead(PLACEHOLDER_ACCOUNT);

        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE + 1
        );
    }

    function test_AccountBoundFailuresReportOffsetsActualValueAndBound() external {
        bytes memory callData = _encodeAccountValueRead(PLACEHOLDER_ACCOUNT);
        bytes4 selector = StaticCallUint256TargetMock.accountValueWithSentinels.selector;

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                address(tupleReadTarget),
                selector,
                uint256(ACCOUNT_ARGUMENT_OFFSET),
                uint256(ACCOUNT_VALUE_RETURN_OFFSET),
                CALLER_ACCOUNT_VALUE,
                CALLER_ACCOUNT_VALUE + 1
            )
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                address(tupleReadTarget),
                selector,
                uint256(ACCOUNT_ARGUMENT_OFFSET),
                uint256(ACCOUNT_VALUE_RETURN_OFFSET),
                CALLER_ACCOUNT_VALUE,
                CALLER_ACCOUNT_VALUE - 1
            )
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE - 1
        );
    }

    function test_AccountBindingReadsCallerValueInsteadOfPlaceholderAccountValue() external view {
        (uint256 leadingValue, uint256 placeholderAccountValue, uint256 trailingValue) =
            tupleReadTarget.accountValueWithSentinels(LEADING_SENTINEL, PLACEHOLDER_ACCOUNT, TRAILING_SENTINEL);
        assertEq(leadingValue, LEADING_SENTINEL, "leading sentinel");
        assertEq(placeholderAccountValue, PLACEHOLDER_ACCOUNT_VALUE, "placeholder account value");
        assertEq(trailingValue, TRAILING_SENTINEL, "trailing sentinel");

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget),
            _encodeAccountValueRead(PLACEHOLDER_ACCOUNT),
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE
        );
    }

    function test_AccountBindingChangesOnlyTheConfiguredCalldataWord() external view {
        bytes memory original = abi.encodeCall(
            StaticCallUint256TargetMock.calldataHash, (LEADING_SENTINEL, PLACEHOLDER_ACCOUNT, TRAILING_SENTINEL)
        );
        bytes memory expected = abi.encodeCall(
            StaticCallUint256TargetMock.calldataHash, (LEADING_SENTINEL, address(this), TRAILING_SENTINEL)
        );
        uint256 expectedHash = uint256(keccak256(expected));

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), original, ACCOUNT_ARGUMENT_OFFSET, 0, expectedHash
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), original, ACCOUNT_ARGUMENT_OFFSET, 0, expectedHash
        );
    }

    function test_ReturnOffsetsSelectLeadingAccountAndTrailingWordsIndependently() external view {
        bytes memory callData = _encodeAccountValueRead(PLACEHOLDER_ACCOUNT);

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), callData, ACCOUNT_ARGUMENT_OFFSET, 0, LEADING_SENTINEL
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), callData, ACCOUNT_ARGUMENT_OFFSET, 0, LEADING_SENTINEL
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget),
            callData,
            ACCOUNT_ARGUMENT_OFFSET,
            ACCOUNT_VALUE_RETURN_OFFSET,
            CALLER_ACCOUNT_VALUE
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), callData, ACCOUNT_ARGUMENT_OFFSET, 64, TRAILING_SENTINEL
        );
    }

    function test_GlobalReadLeavesCalldataUnmodifiedForBothDirections() external view {
        bytes memory callData = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE
        );
    }

    function test_GlobalReadThresholdFailuresUseExplicitSentinel() external {
        bytes memory callData = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );
        bytes4 selector = StaticCallUint256TargetMock.globalTuple.selector;

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                address(tupleReadTarget),
                selector,
                uint256(NO_ACCOUNT_BINDING),
                uint256(GLOBAL_VALUE_RETURN_OFFSET),
                GLOBAL_RETURN_VALUE,
                GLOBAL_RETURN_VALUE + 1
            )
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                address(tupleReadTarget),
                selector,
                uint256(NO_ACCOUNT_BINDING),
                uint256(GLOBAL_VALUE_RETURN_OFFSET),
                GLOBAL_RETURN_VALUE,
                GLOBAL_RETURN_VALUE - 1
            )
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE - 1
        );
    }

    function test_TrailingPaddingCanBePatchedWithoutBindingTheRealAccountArgument() external view {
        bytes memory accountValueCall = abi.encodeCall(StaticCallUint256TargetMock.accountValue, (PLACEHOLDER_ACCOUNT));
        bytes memory paddedCallData = bytes.concat(accountValueCall, abi.encode(PADDING_ONLY_ACCOUNT));

        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), paddedCallData, ACCOUNT_ARGUMENT_OFFSET, 0, PLACEHOLDER_ACCOUNT_VALUE
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), paddedCallData, ACCOUNT_ARGUMENT_OFFSET, 0, PLACEHOLDER_ACCOUNT_VALUE
        );
    }

    function test_ZeroAndSelfTargetsAreRejectedBeforeCalldataValidation() external {
        bytes memory tooShort = hex"12";

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionTarget.selector, address(0))
        );
        genericAssertions.assertStaticCallUint256AtLeast(address(0), tooShort, NO_ACCOUNT_BINDING, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.InvalidAssertionTarget.selector, address(genericAssertions)
            )
        );
        genericAssertions.assertStaticCallUint256AtMost(address(genericAssertions), tooShort, NO_ACCOUNT_BINDING, 0, 0);
    }

    function test_CalldataMustContainCompleteSelector() external {
        for (uint256 length = 0; length < 4; ++length) {
            bytes memory incompleteCallData = new bytes(length);
            vm.expectRevert(
                abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionCallData.selector, length)
            );
            genericAssertions.assertStaticCallUint256AtLeast(
                address(tupleReadTarget), incompleteCallData, NO_ACCOUNT_BINDING, 0, 0
            );
        }
    }

    function test_AccountOffsetRejectsLowerBoundAlignmentAndUpperBoundViolations() external {
        bytes memory accountValueCall = _encodeAccountValueRead(PLACEHOLDER_ACCOUNT);
        uint32[3] memory invalidOffsets = [uint32(3), uint32(5), uint32(100)];

        for (uint256 i; i < invalidOffsets.length; ++i) {
            uint256 offset = uint256(invalidOffsets[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, offset, accountValueCall.length
                )
            );
            genericAssertions.assertStaticCallUint256AtLeast(
                address(tupleReadTarget), accountValueCall, invalidOffsets[i], 0, 0
            );
        }
    }

    function test_ReturnOffsetRejectsUnalignedAndOutOfBoundsWords() external {
        bytes memory threeWordReturnCall = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 1, 96)
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), threeWordReturnCall, NO_ACCOUNT_BINDING, 1, 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 96, 96)
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), threeWordReturnCall, NO_ACCOUNT_BINDING, 96, 0
        );
    }

    function test_EmptyShortExactAndLongerReturnDataAreDistinguished() external {
        bytes memory emptyData = abi.encodeCall(StaticCallUint256TargetMock.emptyReturn, ());
        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 0)
        );
        genericAssertions.assertStaticCallUint256AtLeast(address(tupleReadTarget), emptyData, NO_ACCOUNT_BINDING, 0, 0);

        bytes memory shortData = abi.encodeCall(StaticCallUint256TargetMock.shortReturn, ());
        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 3)
        );
        genericAssertions.assertStaticCallUint256AtLeast(address(tupleReadTarget), shortData, NO_ACCOUNT_BINDING, 0, 0);

        bytes memory exactData = abi.encodeCall(StaticCallUint256TargetMock.exactReturn, (GLOBAL_RETURN_VALUE));
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), exactData, NO_ACCOUNT_BINDING, 0, GLOBAL_RETURN_VALUE
        );

        bytes memory longerData = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), longerData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE
        );
    }

    function test_NoCodeTargetSucceedsCallButFailsReturnBounds() external {
        address noCode = address(0xBEEF);
        bytes memory readCall = abi.encodeWithSelector(bytes4(keccak256("read()")));

        vm.expectRevert(
            abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, 0, 0)
        );
        genericAssertions.assertStaticCallUint256AtLeast(noCode, readCall, NO_ACCOUNT_BINDING, 0, 0);
    }

    function test_StaticCallFailurePreservesSelectorModeAndCompleteReasonBeforeReturnValidation() external {
        bytes memory payload = hex"0102030405060708090a0b0c";
        bytes memory revertingReadCall = abi.encodeCall(StaticCallUint256TargetMock.revertRead, (907, payload));
        bytes memory reason =
            abi.encodeWithSelector(StaticCallUint256TargetMock.StaticReadFailure.selector, 907, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticCallUint256Assertions.AssertionStaticCallFailed.selector,
                address(tupleReadTarget),
                StaticCallUint256TargetMock.revertRead.selector,
                uint256(NO_ACCOUNT_BINDING),
                reason
            )
        );
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), revertingReadCall, NO_ACCOUNT_BINDING, 1, type(uint256).max
        );
    }

    function test_ChecksEmitNoCustomEvents() external {
        bytes memory callData = abi.encodeCall(
            StaticCallUint256TargetMock.globalTuple, (LEADING_SENTINEL, GLOBAL_RETURN_VALUE, TRAILING_SENTINEL)
        );

        vm.recordLogs();
        genericAssertions.assertStaticCallUint256AtLeast(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE
        );
        genericAssertions.assertStaticCallUint256AtMost(
            address(tupleReadTarget), callData, NO_ACCOUNT_BINDING, GLOBAL_VALUE_RETURN_OFFSET, GLOBAL_RETURN_VALUE
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "unexpected checker event");
    }

    function test_DirectDeploymentRuntimeMatchesIndependentImmutableArtifact() external view {
        assertEq(
            address(genericAssertions).code, type(StaticCallUint256Assertions).runtimeCode, "runtime artifact mismatch"
        );
        assertEq(address(genericAssertions).codehash, keccak256(type(StaticCallUint256Assertions).runtimeCode));
    }

    function _encodeAccountValueRead(address account) private pure returns (bytes memory) {
        return abi.encodeCall(
            StaticCallUint256TargetMock.accountValueWithSentinels, (LEADING_SENTINEL, account, TRAILING_SENTINEL)
        );
    }
}
