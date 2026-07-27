// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DynamicPatchTarget, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

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
        calls[0] = _buildRecordingCall(
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(recordingTarget.total(), 1_000, "current-balance amount");
    }

    /// @dev Snapshots checkpoint creation followed by one CheckpointDelta patch.
    function test_Gas_IntegratedTwoCallCheckpointDeltaPatch() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 1_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](2);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(balanceToken),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(250))),
            DynamicCallTestBuilder.singleCheckpoint(address(balanceToken), CHECKPOINT_ID),
            DynamicCallTestBuilder.noPatches()
        );
        calls[1] = _buildRecordingCall(
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.checkpointDeltaPatch(address(balanceToken), CHECKPOINT_ID, 4, 10_000)
            )
        );

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
        assertEq(recordingTarget.total(), 250, "checkpoint-delta amount");
    }

    /// @dev Snapshots three same-token patches sharing one balance read.
    function test_Gas_IntegratedThreeSameTokenCachedPatches() external {
        balanceToken.setBalance(accountUnderTest.delegatedEoa, 2_000);
        IDefiSimplify7702Account.BalancePatch[] memory patches = new IDefiSimplify7702Account.BalancePatch[](3);
        patches[0] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 2_500);
        patches[1] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 36, 5_000);
        patches[2] = DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 68, 10_000);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(calldataCaptureTarget),
            abi.encodeWithSelector(CAPTURE_SELECTOR, uint256(0), uint256(0), uint256(0)),
            DynamicCallTestBuilder.noCheckpoints(),
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
        calls[0] = _buildRecordingCall(
            DynamicCallTestBuilder.singlePatch(
                DynamicCallTestBuilder.currentBalancePatch(address(balanceToken), 4, 5_000)
            )
        );
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
        return DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("gas"))),
            DynamicCallTestBuilder.noCheckpoints(),
            patches
        );
    }
}
