// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TransientTokenBalanceRecord} from "../../src/libraries/TransientTokenBalanceRecord.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Test} from "forge-std/Test.sol";

contract CheckpointRepresentationBenchmark is Test {
    using SlotDerivation for bytes32;
    using TransientSlot for *;
    using TransientTokenBalanceRecord for bytes32;

    // ERC-7201 root for `DefiSimplify7702Account.transient.checkpointTable.benchmark.v1`.
    bytes32 private constant _CHECKPOINT_TABLE_ROOT =
        0xf61c81e7c0047fe80627c2b363091b6868293d10545db99bbc3c0976fa275e00;
    // ERC-7201 slot for `DefiSimplify7702Account.transient.invocationCounter.benchmark`.
    bytes32 private constant _INVOCATION_COUNTER_SLOT =
        0x388d59266cd1f2e2bff411ce873eacf87a6f903b569da2bfab1e4ec4e8b8a300;
    address private constant _TOKEN = address(0xBEEF);

    struct MemoryRecord {
        bytes32 id;
        address token;
        uint256 balance;
    }

    function test_BenchmarkOneCheckpoint() external {
        _benchmark(1);
    }

    function test_BenchmarkFourCheckpoints() external {
        _benchmark(4);
    }

    function test_BenchmarkEightCheckpoints() external {
        _benchmark(8);
    }

    function test_BenchmarkSixteenCheckpoints() external {
        _benchmark(16);
    }

    function test_BenchmarkThirtyTwoCheckpoints() external {
        _benchmark(32);
    }

    function test_BenchmarkSixtyFourCheckpoints() external {
        _benchmark(64);
    }

    function _benchmark(uint256 count) private {
        uint256 gasBefore = gasleft();
        uint256 memorySum = _memoryCreateAndLookup(count);
        uint256 memoryGas = gasBefore - gasleft();

        gasBefore = gasleft();
        uint256 transientSum = _transientCreateAndLookup(count);
        uint256 transientGas = gasBefore - gasleft();

        assertEq(memorySum, transientSum, "representations disagree");
        emit log_named_uint("checkpoint count", count);
        emit log_named_uint("memory gas", memoryGas);
        emit log_named_uint("transient gas", transientGas);
    }

    function _memoryCreateAndLookup(uint256 count) private pure returns (uint256 sum) {
        MemoryRecord[] memory records = new MemoryRecord[](count);
        uint256 populatedLength = 0;

        for (uint256 i = 0; i < count; ++i) {
            bytes32 id = bytes32(i + 1);
            for (uint256 recordIndex = 0; recordIndex < populatedLength; ++recordIndex) {
                require(records[recordIndex].id != id, "duplicate memory checkpoint");
            }

            records[populatedLength] = MemoryRecord({id: id, token: _TOKEN, balance: i + 101});
            ++populatedLength;
        }

        for (uint256 i = 0; i < count; ++i) {
            bytes32 id = bytes32(i + 1);
            bool found = false;
            for (uint256 recordIndex = 0; recordIndex < populatedLength; ++recordIndex) {
                MemoryRecord memory record = records[recordIndex];
                if (record.id == id) {
                    require(record.token == _TOKEN, "memory token mismatch");
                    sum += record.balance;
                    found = true;
                    break;
                }
            }
            require(found, "memory checkpoint missing");
        }
    }

    function _transientCreateAndLookup(uint256 count) private returns (uint256 sum) {
        TransientSlot.Uint256Slot counterSlot = _INVOCATION_COUNTER_SLOT.asUint256();
        uint256 invocationId = counterSlot.tload() + 1;
        counterSlot.tstore(invocationId);

        for (uint256 i = 0; i < count; ++i) {
            bytes32 recordRoot = _recordRoot(invocationId, bytes32(i + 1));
            require(!recordRoot.isPresent(), "duplicate transient checkpoint");

            recordRoot.store(_TOKEN, i + 101);
        }

        for (uint256 i = 0; i < count; ++i) {
            bytes32 recordRoot = _recordRoot(invocationId, bytes32(i + 1));
            require(recordRoot.isPresent(), "transient checkpoint missing");
            require(recordRoot.token() == _TOKEN, "transient token mismatch");
            sum += recordRoot.balance();
        }
    }

    function _recordRoot(uint256 invocationId, bytes32 checkpointId) private pure returns (bytes32) {
        return _CHECKPOINT_TABLE_ROOT.deriveMapping(invocationId).deriveMapping(checkpointId);
    }
}
