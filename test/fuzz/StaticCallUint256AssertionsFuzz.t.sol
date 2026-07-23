// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {Test} from "forge-std/Test.sol";
import {StaticCallUint256TargetMock} from "../mocks/StaticCallUint256AssertionsMocks.sol";

contract StaticCallUint256AssertionsFuzzTest is Test {
    uint32 private constant NO_ACCOUNT_BINDING = type(uint32).max;
    uint32 private constant ACCOUNT_ARGUMENT_OFFSET = 36;

    StaticCallUint256Assertions private uint256Assertions;
    StaticCallUint256TargetMock private readTarget;

    function setUp() external {
        uint256Assertions = new StaticCallUint256Assertions();
        readTarget = new StaticCallUint256TargetMock();
    }

    function testFuzz_AccountBindingChangesOnlyConfiguredCalldataWord(
        uint256 leadingSentinel,
        address placeholderAccount,
        uint256 trailingSentinel
    ) external view {
        bytes memory original = abi.encodeCall(
            StaticCallUint256TargetMock.calldataHash, (leadingSentinel, placeholderAccount, trailingSentinel)
        );
        bytes memory expected = abi.encodeCall(
            StaticCallUint256TargetMock.calldataHash, (leadingSentinel, address(this), trailingSentinel)
        );
        uint256 expectedHash = uint256(keccak256(expected));

        uint256Assertions.assertStaticCallUint256AtLeast(
            address(readTarget), original, ACCOUNT_ARGUMENT_OFFSET, 0, expectedHash
        );
        uint256Assertions.assertStaticCallUint256AtMost(
            address(readTarget), original, ACCOUNT_ARGUMENT_OFFSET, 0, expectedHash
        );
    }

    function testFuzz_GlobalReadComparisonMatchesUnsignedBounds(uint256 actual, uint256 bound) external {
        bytes memory globalReadCall = abi.encodeCall(StaticCallUint256TargetMock.exactReturn, (actual));

        if (actual >= bound) {
            uint256Assertions.assertStaticCallUint256AtLeast(
                address(readTarget), globalReadCall, NO_ACCOUNT_BINDING, 0, bound
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.StaticCallUint256BelowMinimum.selector,
                    address(readTarget),
                    StaticCallUint256TargetMock.exactReturn.selector,
                    uint256(NO_ACCOUNT_BINDING),
                    0,
                    actual,
                    bound
                )
            );
            uint256Assertions.assertStaticCallUint256AtLeast(
                address(readTarget), globalReadCall, NO_ACCOUNT_BINDING, 0, bound
            );
        }

        if (actual <= bound) {
            uint256Assertions.assertStaticCallUint256AtMost(
                address(readTarget), globalReadCall, NO_ACCOUNT_BINDING, 0, bound
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.StaticCallUint256AboveMaximum.selector,
                    address(readTarget),
                    StaticCallUint256TargetMock.exactReturn.selector,
                    uint256(NO_ACCOUNT_BINDING),
                    0,
                    actual,
                    bound
                )
            );
            uint256Assertions.assertStaticCallUint256AtMost(
                address(readTarget), globalReadCall, NO_ACCOUNT_BINDING, 0, bound
            );
        }
    }

    function testFuzz_AccountOffsetValidationMatchesSelectorRelativeWordModel(uint32 accountOffset) external {
        vm.assume(accountOffset != NO_ACCOUNT_BINDING);
        bytes memory accountValueCall = abi.encodeCall(
            StaticCallUint256TargetMock.accountValueWithSentinels, (uint256(11), address(0x1234), uint256(13))
        );
        uint256 offset = uint256(accountOffset);
        bool valid = offset >= 4 && (offset - 4) % 32 == 0 && offset + 32 <= accountValueCall.length;

        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStaticCallUint256Assertions.InvalidAssertionAccountOffset.selector, offset, accountValueCall.length
                )
            );
        }
        uint256Assertions.assertStaticCallUint256AtLeast(address(readTarget), accountValueCall, accountOffset, 0, 0);
    }

    function testFuzz_ReturnOffsetValidationMatchesFixedWordModel(uint32 returnOffset) external {
        bytes memory threeWordReturnCall =
            abi.encodeCall(StaticCallUint256TargetMock.globalTuple, (uint256(17), uint256(19), uint256(23)));
        uint256 offset = uint256(returnOffset);
        bool valid = offset % 32 == 0 && offset + 32 <= 96;

        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(IStaticCallUint256Assertions.InvalidAssertionReturnOffset.selector, offset, 96)
            );
        }
        uint256Assertions.assertStaticCallUint256AtLeast(
            address(readTarget), threeWordReturnCall, NO_ACCOUNT_BINDING, returnOffset, 0
        );
    }
}
