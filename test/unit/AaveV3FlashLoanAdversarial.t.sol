// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    AaveV3FlashLoanPoolMock,
    FlashLoanAssetMock,
    FlashLoanCallbackForwarder,
    FlashLoanWrapper
} from "../mocks/AaveV3FlashLoanMocks.sol";
import {PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionAdversary} from "../mocks/DynamicExecutionAdversary.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {AaveV3FlashLoanFixture} from "../utils/AaveV3FlashLoanFixture.sol";

contract AaveV3FlashLoanAdversarialTest is AaveV3FlashLoanFixture {
    bytes32 private constant OUTER_CHECKPOINT_ID = keccak256("outer-only-callback-adversarial");
    bytes32 private constant CALLBACK_CHECKPOINT_ID = keccak256("callback-only-callback-adversarial");

    function setUp() external {
        _setUpAaveV3FlashLoanFixture(IEntryPoint(address(this)));
    }

    function test_ExecuteOperationBeforeDynamicExecutionIsRejectedBeforeReadingParams() external {
        vm.expectRevert(IDefiSimplify7702Account.CallbackOutsideDynamicExecution.selector);
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeOperation(
                address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, accountUnderTest.delegatedEoa, hex"deadbeef"
            );
    }

    function test_ExecuteOperationAfterCompletedOuterFrameIsRejectedAsOutsideDynamicExecution() external {
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        vm.expectRevert(IDefiSimplify7702Account.CallbackOutsideDynamicExecution.selector);
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeOperation(
                address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, accountUnderTest.delegatedEoa, bytes("")
            );
    }

    function test_OrdinaryDynamicCallCannotInvokeCallbackWithoutOpeningWindow() external {
        FlashLoanCallbackForwarder ordinaryCallbackCaller = new FlashLoanCallbackForwarder();
        bytes memory callbackFailure =
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 0, uint8(0));
        IDefiSimplify7702Account.DynamicCall memory ordinaryCall = _buildDynamicCall(
            address(ordinaryCallbackCaller),
            abi.encodeCall(
                FlashLoanCallbackForwarder.forward,
                (
                    accountUnderTest.delegatedEoa,
                    address(flashAsset),
                    FLASH_PRINCIPAL,
                    FLASH_PREMIUM,
                    accountUnderTest.delegatedEoa,
                    bytes("")
                )
            ),
            _noCheckpoints(),
            _noPatches(),
            false
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(ordinaryCallbackCaller), callbackFailure
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleDynamicCall(ordinaryCall));
    }

    function test_WrapperTargetCannotDelegateCallbackAuthorityToDownstreamPool() external {
        FlashLoanWrapper wrapper = new FlashLoanWrapper();
        bytes memory params = abi.encode(_buildCallbackEnvelope(FLASH_PREMIUM, _emptyCallbackPlan()));
        IDefiSimplify7702Account.DynamicCall memory wrapperCall = _buildDynamicCall(
            address(wrapper),
            abi.encodeCall(
                FlashLoanWrapper.requestFlashLoan,
                (flashLoanPool, accountUnderTest.delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, params)
            ),
            _noCheckpoints(),
            _noPatches(),
            true
        );
        bytes memory senderFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.UnexpectedCallbackSender.selector, 0, address(wrapper), address(flashLoanPool)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.DynamicCallFailed.selector, 0, address(wrapper), senderFailure
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleDynamicCall(wrapperCall));
    }

    function test_SamePoolDifferentReplayIsRejectedAfterFirstCallbackConsumesWindow() external {
        flashLoanPool.setReplayCallback(true);
        flashLoanPool.setReplayWithDifferentParams(true);
        bytes memory replayFailure =
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 0, uint8(3));

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, replayFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashLoanPool.callbackCount(), 0, "replayed Pool call rolls back first callback");
    }

    function test_TruncatedCallbackCalldataCannotReachCallbackPlan() external {
        flashLoanPool.setCallbackMutation(AaveV3FlashLoanPoolMock.CallbackMutation.WrongCalldataLength);
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildRecordingCall(7, "must-not-run-after-truncated-callback");

        vm.expectRevert();
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 0, "malformed callback calldata never executes plan");
    }

    function test_CallbackPlanCannotTargetDelegatedAccountItself() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] =
            _buildDynamicCall(accountUnderTest.delegatedEoa, bytes(""), _noCheckpoints(), _noPatches(), false);
        bytes memory invalidSelfTarget =
            abi.encodeWithSelector(IDefiSimplify7702Account.InvalidTarget.selector, 0, accountUnderTest.delegatedEoa);

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, invalidSelfTarget));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);
    }

    function test_CallbackTargetCannotEnterInheritedExecute() external {
        DynamicExecutionAdversary staticExecutionCaller = new DynamicExecutionAdversary();
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildDynamicCall(
            address(staticExecutionCaller),
            abi.encodeCall(DynamicExecutionAdversary.callAccountExecute, (accountUnderTest.delegatedEoa)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
        bytes memory authorizationFailure = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector,
            address(staticExecutionCaller),
            accountUnderTest.delegatedEoa,
            address(this)
        );
        bytes memory callbackCallFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            0,
            0,
            address(staticExecutionCaller),
            authorizationFailure
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, callbackCallFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);
    }

    function test_CallbackTargetCannotEnterInheritedExecuteBatch() external {
        DynamicExecutionAdversary staticExecutionCaller = new DynamicExecutionAdversary();
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildDynamicCall(
            address(staticExecutionCaller),
            abi.encodeCall(DynamicExecutionAdversary.callAccountExecuteBatch, (accountUnderTest.delegatedEoa)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
        bytes memory authorizationFailure = abi.encodeWithSelector(
            BaseAccount.NotFromEntryPoint.selector,
            address(staticExecutionCaller),
            accountUnderTest.delegatedEoa,
            address(this)
        );
        bytes memory callbackCallFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            0,
            0,
            address(staticExecutionCaller),
            authorizationFailure
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, callbackCallFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);
    }

    function test_CallbackCannotConsumeCheckpointCreatedByOuterInvocation() external {
        PatchBalanceToken checkpointToken = new PatchBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildRecordingCall(0, "must-not-consume-outer-checkpoint");
        callbackCalls[0].patches = _onePatch(_checkpointDeltaPatch(address(checkpointToken), OUTER_CHECKPOINT_ID, 4));

        IDefiSimplify7702Account.DynamicCall[] memory outerCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        outerCalls[0] = _buildDynamicCall(
            address(checkpointToken),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(100))),
            _oneCheckpoint(address(checkpointToken), OUTER_CHECKPOINT_ID),
            _noPatches(),
            false
        );
        outerCalls[1] = _buildFlashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, callbackCalls);
        bytes memory missingCheckpoint =
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 0, 0, OUTER_CHECKPOINT_ID);

        vm.expectRevert(_wrappedFlashLoanTargetFailure(1, missingCheckpoint));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(outerCalls);

        assertEq(checkpointToken.balanceOf(accountUnderTest.delegatedEoa), 0, "outer producer rolls back");
    }

    function test_OuterInvocationCannotConsumeCheckpointCreatedOnlyByCallback() external {
        PatchBalanceToken checkpointToken = new PatchBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildDynamicCall(
            address(checkpointToken),
            abi.encodeCall(PatchBalanceToken.produce, (uint256(40))),
            _oneCheckpoint(address(checkpointToken), CALLBACK_CHECKPOINT_ID),
            _noPatches(),
            false
        );

        IDefiSimplify7702Account.DynamicCall[] memory outerCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        outerCalls[0] = _buildFlashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, callbackCalls);
        outerCalls[1] = _buildRecordingCall(0, "must-not-consume-callback-checkpoint");
        outerCalls[1].patches = _onePatch(_checkpointDeltaPatch(address(checkpointToken), CALLBACK_CHECKPOINT_ID, 4));

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CheckpointNotFound.selector, 1, 0, CALLBACK_CHECKPOINT_ID)
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(outerCalls);

        assertEq(checkpointToken.balanceOf(accountUnderTest.delegatedEoa), 0, "callback producer rolls back");
    }

    function test_OuterTargetRevertBeforeCallbackLeavesAssetAndCallbackStateUnchanged() external {
        flashLoanPool.setFailurePoint(AaveV3FlashLoanPoolMock.FailurePoint.BeforePrincipalTransfer);
        bytes memory targetFailure = abi.encodeWithSelector(
            AaveV3FlashLoanPoolMock.OuterTargetFailure.selector,
            uint8(AaveV3FlashLoanPoolMock.FailurePoint.BeforePrincipalTransfer)
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, targetFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.balanceOf(address(flashLoanPool)), FLASH_PRINCIPAL, "Pool balance unchanged");
        assertEq(
            flashAsset.balanceOf(accountUnderTest.delegatedEoa), FLASH_PREMIUM, "account premium balance unchanged"
        );
    }

    function test_OuterTargetRevertAfterCallbackRollsBackPlanAndRepaymentApproval() external {
        flashLoanPool.setFailurePoint(AaveV3FlashLoanPoolMock.FailurePoint.AfterCallback);
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildRecordingCall(9, "rolled-back-after-callback");
        bytes memory targetFailure = abi.encodeWithSelector(
            AaveV3FlashLoanPoolMock.OuterTargetFailure.selector,
            uint8(AaveV3FlashLoanPoolMock.FailurePoint.AfterCallback)
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, targetFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 0, "callback plan state rolled back");
        assertEq(flashAsset.approvalCount(), 0, "repayment approvals rolled back");
    }

    function test_OuterTargetRevertAfterRepaymentPullRollsBackEveryAssetChange() external {
        flashLoanPool.setFailurePoint(AaveV3FlashLoanPoolMock.FailurePoint.AfterRepayment);
        bytes memory targetFailure = abi.encodeWithSelector(
            AaveV3FlashLoanPoolMock.OuterTargetFailure.selector,
            uint8(AaveV3FlashLoanPoolMock.FailurePoint.AfterRepayment)
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, targetFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.balanceOf(address(flashLoanPool)), FLASH_PRINCIPAL, "Pool pull rolled back");
        assertEq(flashAsset.balanceOf(accountUnderTest.delegatedEoa), FLASH_PREMIUM, "account repayment rolled back");
        assertEq(flashAsset.allowance(accountUnderTest.delegatedEoa, address(flashLoanPool)), 0, "approval rolled back");
    }

    function test_PoolThatDoesNotPullRepaymentIsRejectedForResidualAllowance() external {
        flashLoanPool.setPullRepayment(false);
        bytes memory residualAllowance = abi.encodeWithSelector(
            IDefiSimplify7702Account.ResidualFlashLoanAllowance.selector,
            0,
            address(flashAsset),
            address(flashLoanPool),
            FLASH_PRINCIPAL + FLASH_PREMIUM
        );

        vm.expectRevert(residualAllowance);
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_PoolCannotPullMoreThanExactApprovedRepayment() external {
        uint256 exactRepayment = FLASH_PRINCIPAL + FLASH_PREMIUM;
        flashLoanPool.setCustomPullAmount(exactRepayment + 1);
        bytes memory excessivePullFailure = abi.encodeWithSelector(
            FlashLoanAssetMock.InsufficientAllowance.selector,
            accountUnderTest.delegatedEoa,
            address(flashLoanPool),
            exactRepayment,
            exactRepayment + 1
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, excessivePullFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_FeeOnTransferAssetFailsRepaymentCoverageAndRollsBackPrincipalTransfer() external {
        flashAsset.setTransferFeeBps(100);
        uint256 principalAfterFee = FLASH_PRINCIPAL - (FLASH_PRINCIPAL / 100);
        bytes memory insufficientRepayment = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentBalanceInsufficient.selector,
            0,
            address(flashAsset),
            principalAfterFee + FLASH_PREMIUM,
            FLASH_PRINCIPAL + FLASH_PREMIUM
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, insufficientRepayment));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.balanceOf(address(flashLoanPool)), FLASH_PRINCIPAL, "fee transfer rolled back");
    }

    function test_ReentrantApprovalTokenCannotReplayCallbackWhileStateIsExecuting() external {
        bytes memory replayCalldata = abi.encodeCall(
            IDefiSimplify7702Account.executeOperation,
            (address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, accountUnderTest.delegatedEoa, bytes(""))
        );
        flashAsset.setApprovalReentry(accountUnderTest.delegatedEoa, replayCalldata, true);

        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.approvalReentryCount(), 1, "only exact nonzero approval attempts reentry");
        assertFalse(flashAsset.lastApprovalReentrySucceeded(), "reentrant callback must fail");
        assertEq(
            flashAsset.lastApprovalReentryReturnData(),
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 0, uint8(2)),
            "reentry observes ExecutingCallback"
        );
        _assertFlashLoanRepaidExactly(flashAsset, FLASH_PRINCIPAL, FLASH_PREMIUM);
    }

    function test_CallbackTargetBoundedHugeRevertDataIsPreservedByteForByte() external {
        DynamicExecutionAdversary revertDataTarget = new DynamicExecutionAdversary();
        uint256 revertDataSize = 4_096;
        bytes memory completeRevertData = new bytes(revertDataSize);
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildDynamicCall(
            address(revertDataTarget),
            abi.encodeCall(DynamicExecutionAdversary.failWithReturnDataSize, (revertDataSize)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
        bytes memory callbackCallFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            0,
            0,
            address(revertDataTarget),
            completeRevertData
        );

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, callbackCallFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);
    }

    function test_SuccessfulCallbackExecutionWritesNoPermanentDelegatedAccountStorage() external {
        vm.record();
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
        (, bytes32[] memory permanentWrites) = vm.accesses(accountUnderTest.delegatedEoa);

        assertEq(permanentWrites.length, 0, "callback path wrote permanent delegated-account storage");
    }
}
