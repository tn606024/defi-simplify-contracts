// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Verifies language-neutral dynamic execution fixtures against Solidity ABI encoding.
contract DynamicGoldenVectorsTest is Test {
    string private constant FIXTURE_PATH = "abi/DynamicExecution.golden.json";
    address private constant FIXTURE_TOKEN = 0x1111111111111111111111111111111111111111;
    address private constant FIXTURE_OTHER_TOKEN = 0x2222222222222222222222222222222222222222;
    address private constant FIXTURE_TARGET = 0x3333333333333333333333333333333333333333;
    bytes32 private constant CHECKPOINT_ID = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));
    uint256 private constant INVOCATION_ID = 7;
    uint256 private constant PRODUCER_OUTPUT = 123_456_789;
    uint16 private constant FIXTURE_BPS = 3_750;

    /// @dev Verifies struct/function encoding, patch isolation, and full-precision amount math.
    function test_GoldenPlanEncodingPatchingAndAmountMatchFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes memory original =
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0x1111), uint256(0x2222), uint256(0x3333));
        uint256 resolvedAmount = Math.mulDiv(PRODUCER_OUTPUT, FIXTURE_BPS, 10_000);
        bytes memory patched =
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0x1111), uint256(0x2222), uint256(0x3333));
        assembly ("memory-safe") {
            mstore(add(add(patched, 32), 36), resolvedAmount)
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = _buildGoldenDynamicCalls(original);

        assertEq(vm.parseJsonUint(fixture, ".version"), 2, "fixture version");
        assertEq(vm.parseJsonAddress(fixture, ".token"), FIXTURE_TOKEN, "fixture token");
        assertEq(vm.parseJsonAddress(fixture, ".otherToken"), FIXTURE_OTHER_TOKEN, "fixture other token");
        assertEq(vm.parseJsonAddress(fixture, ".target"), FIXTURE_TARGET, "fixture target");
        assertEq(vm.parseJsonBytes32(fixture, ".checkpointId"), CHECKPOINT_ID, "fixture checkpoint id");
        assertEq(vm.parseJsonUint(fixture, ".invocationId"), INVOCATION_ID, "fixture invocation id");
        assertEq(vm.parseJsonUint(fixture, ".patchOffset"), 36, "fixture patch offset");
        assertEq(vm.parseJsonUint(fixture, ".bps"), FIXTURE_BPS, "fixture bps");
        assertEq(vm.parseJsonUint(fixture, ".producerOutput"), PRODUCER_OUTPUT, "fixture producer output");
        assertEq(vm.parseJsonUint(fixture, ".resolvedAmount"), resolvedAmount, "fixture resolved amount");
        assertEq(vm.parseJsonBytes(fixture, ".originalCalldata"), original, "fixture original calldata");
        assertEq(vm.parseJsonBytes(fixture, ".patchedCalldata"), patched, "fixture patched calldata");
        assertEq(vm.parseJsonBytes(fixture, ".dynamicCallEncoding"), abi.encode(calls[0]), "fixture struct encoding");
        assertEq(
            vm.parseJsonBytes(fixture, ".executeBatchDynamicCalldata"),
            abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (calls)),
            "fixture function calldata"
        );
    }

    /// @dev Verifies every transient namespace and nested checkpoint record slot.
    function test_GoldenNamespaceAndRecordSlotsMatchIndependentDerivation() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes32 lockSlot = keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");
        bytes32 counterSlot = keccak256("DefiSimplify7702Account.dynamicInvocationCounter.v1");
        bytes32 tableNamespace = keccak256("DefiSimplify7702Account.checkpointTable.v1");
        bytes32 invocationRoot = keccak256(abi.encode(INVOCATION_ID, tableNamespace));
        bytes32 recordRoot = keccak256(abi.encode(CHECKPOINT_ID, invocationRoot));

        assertEq(vm.parseJsonBytes32(fixture, ".slots.lock"), lockSlot, "fixture lock slot");
        assertEq(vm.parseJsonBytes32(fixture, ".slots.counter"), counterSlot, "fixture counter slot");
        assertEq(vm.parseJsonBytes32(fixture, ".slots.tableNamespace"), tableNamespace, "fixture table namespace");
        assertEq(vm.parseJsonBytes32(fixture, ".slots.invocationRoot"), invocationRoot, "fixture invocation root");
        assertEq(vm.parseJsonBytes32(fixture, ".slots.presence"), recordRoot, "fixture presence slot");
        assertEq(vm.parseJsonBytes32(fixture, ".slots.token"), bytes32(uint256(recordRoot) + 1), "fixture token slot");
        assertEq(
            vm.parseJsonBytes32(fixture, ".slots.balance"), bytes32(uint256(recordRoot) + 2), "fixture balance slot"
        );
    }

    /// @dev Verifies the complete custom-error ABI against the committed fixture.
    function test_GoldenEveryCustomErrorEncodingMatchesFixture() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        bytes memory reason = hex"deadbeef";

        _assertGoldenErrorEncoding(
            fixture, "EmptyDynamicBatch", abi.encodeWithSelector(IDefiSimplify7702Account.EmptyDynamicBatch.selector)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "DynamicExecutionReentered",
            abi.encodeWithSelector(IDefiSimplify7702Account.DynamicExecutionReentered.selector)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidTarget",
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 1, FIXTURE_TARGET)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidCheckpointToken",
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointToken.selector, 1, 2)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidCheckpointId",
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidCheckpointId.selector, 1, 2)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "CheckpointAlreadyExists",
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointAlreadyExists.selector, 1, 2, CHECKPOINT_ID)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "CheckpointNotFound",
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 1, 2, CHECKPOINT_ID)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "CheckpointTokenMismatch",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointTokenMismatch.selector,
                1,
                2,
                CHECKPOINT_ID,
                FIXTURE_TOKEN,
                FIXTURE_OTHER_TOKEN
            )
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidPatchToken",
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchToken.selector, 1, 2)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "InvalidPatchOffset",
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 2, 5, 100)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "UnsortedPatchOffset",
            abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 1, 2, 68, 36)
        );
        _assertGoldenErrorEncoding(
            fixture, "InvalidBps", abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 1, 2, 10_001)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "UnexpectedCheckpointId",
            abi.encodeWithSelector(IDefiSimplify7702Account.UnexpectedCheckpointId.selector, 1, 2, CHECKPOINT_ID)
        );
        _assertGoldenErrorEncoding(
            fixture,
            "CheckpointBalanceReadFailed",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.CheckpointBalanceReadFailed.selector, 1, 2, FIXTURE_TOKEN, reason
            )
        );
        _assertGoldenErrorEncoding(
            fixture,
            "PatchBalanceReadFailed",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.PatchBalanceReadFailed.selector, 1, 2, FIXTURE_TOKEN, reason
            )
        );
        _assertGoldenErrorEncoding(
            fixture,
            "BalanceBelowCheckpoint",
            abi.encodeWithSelector(
                IDefiSimplify7702Account.BalanceBelowCheckpoint.selector, 1, 2, FIXTURE_TOKEN, CHECKPOINT_ID, 900, 1_000
            )
        );
        _assertGoldenErrorEncoding(
            fixture,
            "DynamicCallFailed",
            abi.encodeWithSelector(IDefiSimplify7702Account.DynamicCallFailed.selector, 1, FIXTURE_TARGET, reason)
        );
    }

    /// @dev Verifies malformed-plan vectors include exact indexed error encodings.
    function test_GoldenMalformedCasesCarryExactExpectedErrors() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        assertEq(vm.parseJsonUint(fixture, ".malformed.unalignedOffset.offset"), 5, "malformed offset");
        assertEq(vm.parseJsonUint(fixture, ".malformed.unalignedOffset.dataLength"), 100, "malformed length");
        assertEq(
            vm.parseJsonBytes(fixture, ".malformed.unalignedOffset.encodedError"),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidPatchOffset.selector, 1, 2, 5, 100),
            "malformed offset error"
        );
        assertEq(vm.parseJsonUint(fixture, ".malformed.descendingOffsets.previous"), 68, "previous offset");
        assertEq(vm.parseJsonUint(fixture, ".malformed.descendingOffsets.current"), 36, "current offset");
        assertEq(
            vm.parseJsonBytes(fixture, ".malformed.descendingOffsets.encodedError"),
            abi.encodeWithSelector(IDefiSimplify7702Account.UnsortedPatchOffset.selector, 1, 2, 68, 36),
            "descending offset error"
        );
        assertEq(vm.parseJsonUint(fixture, ".malformed.bpsAboveMaximum.bps"), 10_001, "malformed bps");
        assertEq(
            vm.parseJsonBytes(fixture, ".malformed.bpsAboveMaximum.encodedError"),
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidBps.selector, 1, 2, 10_001),
            "malformed bps error"
        );
    }

    function _buildGoldenDynamicCalls(bytes memory originalCalldata)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = FIXTURE_TARGET;
        calls[0].value = 12_345;
        calls[0].data = originalCalldata;
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        calls[0].checkpointsBefore[0] =
            IDefiSimplify7702Account.BalanceCheckpoint({token: FIXTURE_TOKEN, id: CHECKPOINT_ID});
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](1);
        calls[0].patches[0] = IDefiSimplify7702Account.BalancePatch({
            token: FIXTURE_TOKEN,
            checkpointId: CHECKPOINT_ID,
            offset: 36,
            bps: FIXTURE_BPS,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
        calls[0].expectsCallback = false;
    }

    function _assertGoldenErrorEncoding(string memory fixture, string memory errorName, bytes memory actual)
        private
        pure
    {
        assertEq(vm.parseJsonBytes(fixture, string.concat(".errors.", errorName)), actual, errorName);
    }
}
