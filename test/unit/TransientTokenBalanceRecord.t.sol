// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Test} from "forge-std/Test.sol";
import {TransientTokenBalanceRecord} from "../../src/libraries/TransientTokenBalanceRecord.sol";

contract TransientTokenBalanceRecordHarness {
    using SlotDerivation for bytes32;
    using TransientSlot for *;
    using TransientTokenBalanceRecord for bytes32;

    function store(bytes32 recordRoot, address token, uint256 balance) external {
        recordRoot.store(token, balance);
    }

    function record(bytes32 recordRoot) external view returns (bool present, address token, uint256 balance) {
        return (recordRoot.isPresent(), recordRoot.token(), recordRoot.balance());
    }

    function rawField(bytes32 recordRoot, uint256 offset) external view returns (bytes32 value) {
        return recordRoot.offset(offset).asBytes32().tload();
    }

    function seedRawField(bytes32 recordRoot, uint256 offset, bytes32 value) external {
        recordRoot.offset(offset).asBytes32().tstore(value);
    }
}

contract TransientTokenBalanceRecordTest is Test {
    bytes32 private constant RECORD_A = keccak256("transient-token-balance-record-a");
    bytes32 private constant RECORD_B = keccak256("transient-token-balance-record-b");
    address private constant TOKEN_A = address(0xA11CE);
    address private constant TOKEN_B = address(0xB0B);

    TransientTokenBalanceRecordHarness private harness;

    function setUp() external {
        harness = new TransientTokenBalanceRecordHarness();
    }

    function test_UnwrittenRecordHasZeroedIndependentFields() external view {
        (bool present, address token, uint256 balance) = harness.record(RECORD_A);

        assertFalse(present, "unwritten presence");
        assertEq(token, address(0), "unwritten token");
        assertEq(balance, 0, "unwritten balance");
    }

    function test_StorePublishesTokenAndBalanceAtCanonicalOffsets() external {
        harness.store(RECORD_A, TOKEN_A, 123_456);

        (bool present, address token, uint256 balance) = harness.record(RECORD_A);
        assertTrue(present, "stored presence");
        assertEq(token, TOKEN_A, "stored token");
        assertEq(balance, 123_456, "stored balance");
        assertEq(harness.rawField(RECORD_A, 0), bytes32(uint256(1)), "presence offset");
        assertEq(harness.rawField(RECORD_A, 1), bytes32(uint256(uint160(TOKEN_A))), "token offset");
        assertEq(harness.rawField(RECORD_A, 2), bytes32(uint256(123_456)), "balance offset");
    }

    function test_ZeroBalanceRemainsPresentAndDistinctFromAbsence() external {
        harness.store(RECORD_A, TOKEN_A, 0);

        (bool present, address token, uint256 balance) = harness.record(RECORD_A);
        assertTrue(present, "zero-balance presence");
        assertEq(token, TOKEN_A, "zero-balance token");
        assertEq(balance, 0, "zero-balance value");
    }

    function test_StoreDoesNotOverwriteAdjacentSlotOrIndependentRoot() external {
        bytes32 sentinel = keccak256("adjacent-field-sentinel");
        harness.seedRawField(RECORD_A, 3, sentinel);
        harness.store(RECORD_B, TOKEN_B, 654_321);
        harness.store(RECORD_A, TOKEN_A, 123_456);

        assertEq(harness.rawField(RECORD_A, 3), sentinel, "adjacent slot changed");
        (bool presentB, address tokenB, uint256 balanceB) = harness.record(RECORD_B);
        assertTrue(presentB, "independent root presence");
        assertEq(tokenB, TOKEN_B, "independent root token");
        assertEq(balanceB, 654_321, "independent root balance");
    }
}
