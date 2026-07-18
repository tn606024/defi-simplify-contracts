// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IDefiSimplify7702Account
/// @notice Frozen v1 ABI for checkpoint-based dynamic account execution.
interface IDefiSimplify7702Account {
    enum BalanceSource {
        CurrentBalance,
        CheckpointDelta
    }

    struct BalanceCheckpoint {
        address token;
        bytes32 id;
    }

    struct BalancePatch {
        address token;
        bytes32 checkpointId;
        uint32 offset;
        uint16 bps;
        BalanceSource source;
    }

    struct DynamicCall {
        address target;
        uint256 value;
        bytes data;
        BalanceCheckpoint[] checkpointsBefore;
        BalancePatch[] patches;
    }

    error EmptyDynamicBatch();
    error DynamicExecutionReentered();
    error InvalidTarget(uint256 callIndex, address target);
    error InvalidCheckpointToken(uint256 callIndex, uint256 checkpointIndex);
    error InvalidCheckpointId(uint256 callIndex, uint256 checkpointIndex);
    error CheckpointAlreadyExists(uint256 callIndex, uint256 checkpointIndex, bytes32 id);
    error CheckpointNotFound(uint256 callIndex, uint256 patchIndex, bytes32 id);
    error CheckpointTokenMismatch(uint256 callIndex, uint256 patchIndex, bytes32 id, address expected, address actual);
    error InvalidPatchToken(uint256 callIndex, uint256 patchIndex);
    error InvalidPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 offset, uint256 dataLength);
    error UnsortedPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 previous, uint256 current);
    error InvalidBps(uint256 callIndex, uint256 patchIndex, uint256 bps);
    error UnexpectedCheckpointId(uint256 callIndex, uint256 patchIndex, bytes32 id);
    error CheckpointBalanceReadFailed(uint256 callIndex, uint256 checkpointIndex, address token, bytes reason);
    error PatchBalanceReadFailed(uint256 callIndex, uint256 patchIndex, address token, bytes reason);
    error BalanceBelowCheckpoint(
        uint256 callIndex, uint256 patchIndex, address token, bytes32 checkpointId, uint256 current, uint256 checkpoint
    );
    error DynamicCallFailed(uint256 index, address target, bytes reason);

    function executeBatchDynamic(DynamicCall[] calldata calls) external payable;
}
