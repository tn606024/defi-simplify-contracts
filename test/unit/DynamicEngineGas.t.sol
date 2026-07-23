// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DynamicPatchTarget, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

/// @dev Integrated dynamic-engine gas scenarios complement the 1/4/8/16/32
///      checkpoint matrices in CheckpointEngineTest and DynamicCalldataPatchingTest.
contract DynamicEngineGasTest is DelegatedAccountFixture {
    bytes32 private constant CHECKPOINT_ID = keccak256("dynamic-engine-gas-checkpoint");
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));

    DelegatedDefiSimplifyAccount private accountUnderTest;
    PatchBalanceToken private balanceToken;
    DynamicExecutionTarget private recordingTarget;
    DynamicPatchTarget private calldataCaptureTarget;

    /// @dev Installs the delegated account and target fixtures for each gas scenario.
    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        balanceToken = new PatchBalanceToken();
        recordingTarget = new DynamicExecutionTarget();
        calldataCaptureTarget = new DynamicPatchTarget();
    }

    /// @dev Snapshots one CurrentBalance patch and one target call.
    function test_Gas_IntegratedOneCallCurrentBalancePatch() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(_onePatch(_currentBalancePatch(4, 10_000)));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(recordingTarget.total(), 1_000, "current-balance amount");
    }

    /// @dev Snapshots checkpoint creation followed by one CheckpointDelta patch.
    function test_Gas_IntegratedTwoCallCheckpointDeltaPatch() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = _buildDynamicCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(250))),
            _oneCheckpoint(),
            _noPatches()
        );
        calls[1] = _buildRecordingCall(_onePatch(_checkpointDeltaPatch(4, 10_000)));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(recordingTarget.total(), 250, "checkpoint-delta amount");
    }

    /// @dev Snapshots three same-token patches sharing one balance read.
    function test_Gas_IntegratedThreeSameTokenCachedPatches() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 2_000);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](3);
        patches[0] = _currentBalancePatch(4, 2_500);
        patches[1] = _currentBalancePatch(36, 5_000);
        patches[2] = _currentBalancePatch(68, 10_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildDynamicCall(
            address(calldataCaptureTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0), uint256(0), uint256(0)),
            _noCheckpoints(),
            patches
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(
            calldataCaptureTarget.observedData(),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(500), uint256(1_000), uint256(2_000)),
            "cached patch amounts"
        );
    }

    /// @dev Snapshots two sequential invocation scopes on one delegated account.
    function test_Gas_IntegratedSameAccountSequentialInvocations() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 3_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _buildRecordingCall(_onePatch(_currentBalancePatch(4, 5_000)));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        balanceToken.setBalance(accountUnderTest.delegatedEoa, 4_000);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 2, "sequential invocation count");
        assertEq(recordingTarget.total(), 3_500, "sequential invocation total");
    }

    function _buildRecordingCall(IDefiSimplify7702Account.BalancePatch[] memory patches)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _buildDynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("gas"))),
            _noCheckpoints(),
            patches
        );
    }

    function _buildDynamicCall(
        address callTarget,
        bytes memory callData,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints,
        IDefiSimplify7702Account.BalancePatch[] memory patches
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = callData;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = patches;
    }

    function _oneCheckpoint() private view returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = IDefiSimplify7702Account.BalanceCheckpoint({token: address(balanceToken), id: CHECKPOINT_ID});
    }

    function _noCheckpoints() private pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _onePatch(IDefiSimplify7702Account.BalancePatch memory patch)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch[] memory patches)
    {
        patches = new IDefiSimplify7702Account.BalancePatch[](1);
        patches[0] = patch;
    }

    function _noPatches() private pure returns (IDefiSimplify7702Account.BalancePatch[] memory patches) {
        patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _currentBalancePatch(uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(balanceToken),
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    function _checkpointDeltaPatch(uint32 offset, uint16 bps)
        private
        view
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(balanceToken),
            checkpointId: CHECKPOINT_ID,
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
    }
}
