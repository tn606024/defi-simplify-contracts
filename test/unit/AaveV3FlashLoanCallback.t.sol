// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract AaveV3FlashLoanCallbackTest is DelegatedAccountFixture {
    bytes32 private constant SHARED_CHECKPOINT_ID = keccak256("shared-outer-and-callback-checkpoint");
    uint256 private constant FLASH_PRINCIPAL = 1_000 ether;
    uint256 private constant FLASH_PREMIUM = 1 ether;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    AaveV3FlashLoanPoolMock private pool;
    FlashLoanAssetMock private flashAsset;
    DynamicExecutionTarget private recordingTarget;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        pool = new AaveV3FlashLoanPoolMock();
        flashAsset = new FlashLoanAssetMock();
        recordingTarget = new DynamicExecutionTarget();

        pool.setPremium(FLASH_PREMIUM);
        flashAsset.mint(address(pool), FLASH_PRINCIPAL);
        flashAsset.mint(accountUnderTest.delegatedEoa, FLASH_PREMIUM);
    }

    function test_FlashLoanAtFirstOuterIndexCompletesBeforeLaterOrdinaryCalls() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _buildOuterCallsWithFlashLoanAtIndex(0, _emptyCallbackPlan());

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 2, "two later ordinary calls");
        assertEq(recordingTarget.total(), 50, "later ordinary call amounts");
        _assertFlashLoanWasRepaidExactly();
    }

    function test_FlashLoanAtMiddleOuterIndexPreservesCallsBeforeAndAfterIt() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _buildOuterCallsWithFlashLoanAtIndex(1, _emptyCallbackPlan());

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 2, "ordinary calls around flash loan");
        assertEq(recordingTarget.total(), 40, "ordinary call amounts around flash loan");
        _assertFlashLoanWasRepaidExactly();
    }

    function test_FlashLoanAtLastOuterIndexRunsAfterEarlierOrdinaryCalls() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _buildOuterCallsWithFlashLoanAtIndex(2, _emptyCallbackPlan());

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(recordingTarget.count(), 2, "two earlier ordinary calls");
        assertEq(recordingTarget.total(), 30, "earlier ordinary call amounts");
        _assertFlashLoanWasRepaidExactly();
    }

    function test_CallbackPlanExecutesOneOrdinaryCall() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _recordingCall(11, "callback-one");

        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 1, "one callback target");
        assertEq(recordingTarget.total(), 11, "one callback amount");
        _assertFlashLoanWasRepaidExactly();
    }

    function test_CallbackPlanExecutesManyOrdinaryCallsInOrder() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](3);
        callbackCalls[0] = _recordingCall(11, "callback-first");
        callbackCalls[1] = _recordingCall(22, "callback-second");
        callbackCalls[2] = _recordingCall(33, "callback-third");

        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 3, "three callback targets");
        assertEq(recordingTarget.total(), 66, "callback amounts preserve order");
        assertEq(recordingTarget.lastPayloadHash(), keccak256("callback-third"), "last callback payload");
        _assertFlashLoanWasRepaidExactly();
    }

    function test_CommitmentUsesFlashLoanCalldataAfterAmountPatch() external {
        PatchBalanceToken amountSource = new PatchBalanceToken();
        uint256 patchedPrincipal = 25 ether;
        amountSource.setBalance(accountUnderTest.delegatedEoa, patchedPrincipal);

        FlashLoanAssetMock patchedFlashAsset = new FlashLoanAssetMock();
        patchedFlashAsset.mint(address(pool), patchedPrincipal);
        pool.setPremium(0);

        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _flashLoanCall(address(patchedFlashAsset), 999 ether, 0, _emptyCallbackPlan());
        flashLoanCall.patches = new IDefiSimplify7702Account.BalancePatch[](1);
        flashLoanCall.patches[0] = IDefiSimplify7702Account.BalancePatch({
            token: address(amountSource),
            checkpointId: bytes32(0),
            offset: 68,
            bps: 10_000,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = flashLoanCall;

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        bytes memory expectedPatchedCalldata = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (
                accountUnderTest.delegatedEoa,
                address(patchedFlashAsset),
                patchedPrincipal,
                abi.encode(_envelope(0, _emptyCallbackPlan())),
                uint16(0)
            )
        );
        assertEq(pool.lastReceivedCalldataHash(), keccak256(expectedPatchedCalldata), "patched origin calldata");
        assertEq(patchedFlashAsset.balanceOf(address(pool)), patchedPrincipal, "patched principal returned to Pool");
    }

    function test_CallbackCheckpointsUseASeparateInvocationAndOuterInvocationResumesAfterward() external {
        PatchBalanceToken balanceSource = new PatchBalanceToken();
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        callbackCalls[0] = _dynamicCall(
            address(balanceSource),
            abi.encodeCall(PatchBalanceToken.produce, (30)),
            _oneCheckpoint(address(balanceSource), SHARED_CHECKPOINT_ID),
            _noPatches(),
            false
        );
        callbackCalls[1] = _recordingCall(0, "callback-delta");
        callbackCalls[1].patches = _onePatch(_checkpointDeltaPatch(address(balanceSource), SHARED_CHECKPOINT_ID, 4));

        IDefiSimplify7702Account.DynamicCall[] memory outerCalls = new IDefiSimplify7702Account.DynamicCall[](3);
        outerCalls[0] = _dynamicCall(
            address(balanceSource),
            abi.encodeCall(PatchBalanceToken.produce, (100)),
            _oneCheckpoint(address(balanceSource), SHARED_CHECKPOINT_ID),
            _noPatches(),
            false
        );
        outerCalls[1] = _flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, callbackCalls);
        outerCalls[2] = _recordingCall(0, "outer-delta-after-callback");
        outerCalls[2].patches = _onePatch(_checkpointDeltaPatch(address(balanceSource), SHARED_CHECKPOINT_ID, 4));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(outerCalls);

        assertEq(recordingTarget.count(), 2, "one callback and one later outer consumer");
        assertEq(recordingTarget.total(), 160, "callback delta 30 plus retained outer delta 130");
    }

    function test_CallbackEnabledTargetReturningWithoutCallbackIsRejected() external {
        pool.setSkipCallback(true);
        pool.setPullRepayment(false);
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(_flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, _emptyCallbackPlan()));

        vm.expectRevert(
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotConsumed.selector, 0, address(pool), uint8(1))
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(flashAsset.balanceOf(accountUnderTest.delegatedEoa), FLASH_PREMIUM, "principal transfer rolled back");
    }

    function test_ReplayedCallbackIsRejectedAfterFirstCallbackWasConsumed() external {
        pool.setReplayCallback(true);
        bytes memory replayFailure =
            abi.encodeWithSelector(IDefiSimplify7702Account.CallbackNotAwaiting.selector, 0, uint8(3));

        vm.expectRevert(_wrappedPoolFailure(0, replayFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(pool.callbackCount(), 0, "first callback state change rolled back with replay");
        assertEq(flashAsset.approvalCount(), 0, "repayment approvals rolled back with replay");
    }

    function test_SuccessfulCallbackClearsCommitmentForAnotherBatchInSameTransaction() external {
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
        flashAsset.mint(accountUnderTest.delegatedEoa, FLASH_PREMIUM);

        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(pool.callbackCount(), 2, "two independently consumed callbacks");
        assertEq(flashAsset.approvalCount(), 4, "zero-first and exact approval per callback");
        assertEq(
            flashAsset.allowance(accountUnderTest.delegatedEoa, address(pool)),
            0,
            "second callback also leaves no allowance"
        );
    }

    function test_CallbackCannotReenterPublicDynamicExecution() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _dynamicCall(
            address(this),
            abi.encodeCall(this.reenterDynamicExecution, (accountUnderTest.delegatedEoa)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
        bytes memory callbackFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector,
            0,
            0,
            address(this),
            abi.encodeWithSelector(IDefiSimplify7702Account.DynamicExecutionReentered.selector)
        );

        vm.expectRevert(_wrappedPoolFailure(0, callbackFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);
    }

    function test_WrongCallbackSenderIsRejectedBeforePlanExecution() external {
        pool.setCallbackMutation(AaveV3FlashLoanPoolMock.CallbackMutation.WrongSender);
        bytes memory senderFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.UnexpectedCallbackSender.selector, 0, address(pool), _callbackForwarderAddress()
        );

        vm.expectRevert(_wrappedPoolFailure(0, senderFailure));
        _executeFlashLoan(_oneRecordingCallbackCall(), FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 0, "unauthenticated callback plan");
    }

    function test_WrongInitiatorIsRejectedBeforeOriginReconstruction() external {
        pool.setCallbackMutation(AaveV3FlashLoanPoolMock.CallbackMutation.WrongInitiator);
        bytes memory initiatorFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.UnexpectedCallbackInitiator.selector,
            0,
            accountUnderTest.delegatedEoa,
            address(0xBAD)
        );

        vm.expectRevert(_wrappedPoolFailure(0, initiatorFailure));
        _executeFlashLoan(_oneRecordingCallbackCall(), FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 0, "wrong-initiator callback plan");
    }

    function test_ChangedAssetAmountOrParamsFailsOriginCommitment() external {
        _expectOriginMismatch(AaveV3FlashLoanPoolMock.CallbackMutation.WrongAsset);
        _expectOriginMismatch(AaveV3FlashLoanPoolMock.CallbackMutation.WrongAmount);
        _expectOriginMismatch(AaveV3FlashLoanPoolMock.CallbackMutation.WrongParams);
    }

    function test_ChangedReceiverFailsOriginCommitment() external {
        bytes memory params = abi.encode(_envelope(FLASH_PREMIUM, _oneRecordingCallbackCall()));
        pool.setForcedCallbackReceiver(accountUnderTest.delegatedEoa);
        bytes memory committedCalldata = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (address(0xBAD), address(flashAsset), FLASH_PRINCIPAL, params, uint16(0))
        );

        _expectCommittedOuterCalldataRejected(committedCalldata, params);
    }

    function test_NonzeroReferralCodeFailsOriginCommitment() external {
        bytes memory params = abi.encode(_envelope(FLASH_PREMIUM, _oneRecordingCallbackCall()));
        bytes memory committedCalldata = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (accountUnderTest.delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, params, uint16(7))
        );

        _expectCommittedOuterCalldataRejected(committedCalldata, params);
    }

    function test_DifferentOriginatingSelectorFailsOriginCommitment() external {
        bytes memory params = abi.encode(_envelope(FLASH_PREMIUM, _oneRecordingCallbackCall()));
        bytes memory committedCalldata = abi.encodeCall(
            AaveV3FlashLoanPoolMock.flashLoanFromDifferentSelector,
            (accountUnderTest.delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, params)
        );

        _expectCommittedOuterCalldataRejected(committedCalldata, params);
    }

    function test_MalformedEnvelopeCannotExecuteCallbackPlan() external {
        bytes memory malformedParams = hex"deadbeef";
        bytes memory committedCalldata = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (accountUnderTest.delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, malformedParams, uint16(0))
        );
        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _dynamicCall(address(pool), committedCalldata, _noCheckpoints(), _noPatches(), true);

        vm.expectRevert(_wrappedPoolFailure(0, bytes("")));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleCall(flashLoanCall));

        assertEq(recordingTarget.count(), 0, "malformed envelope plan");
    }

    function test_PremiumEqualToSignedMaximumIsAccepted() external {
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        _assertFlashLoanWasRepaidExactly();
    }

    function test_PremiumAboveSignedMaximumIsRejected() external {
        uint256 maximumPremium = FLASH_PREMIUM - 1;
        bytes memory premiumFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanPremiumTooHigh.selector, 0, FLASH_PREMIUM, maximumPremium
        );

        vm.expectRevert(_wrappedPoolFailure(0, premiumFailure));
        _executeFlashLoan(_emptyCallbackPlan(), maximumPremium);
    }

    function test_PrincipalPlusPremiumOverflowUsesCheckedArithmetic() external {
        FlashLoanAssetMock maximumSupplyAsset = new FlashLoanAssetMock();
        maximumSupplyAsset.mint(address(pool), type(uint256).max);
        pool.setPremium(1);
        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _flashLoanCall(address(maximumSupplyAsset), type(uint256).max, 1, _emptyCallbackPlan());
        bytes memory arithmeticPanic = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));

        vm.expectRevert(_wrappedPoolFailure(0, arithmeticPanic));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleCall(flashLoanCall));
    }

    function test_NestedCallbackFlagIsRejectedBeforeFirstCallbackTarget() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        callbackCalls[0] = _recordingCall(10, "must-not-run");
        callbackCalls[1] = _recordingCall(20, "nested");
        callbackCalls[1].expectsCallback = true;
        bytes memory nestedFailure =
            abi.encodeWithSelector(IDefiSimplify7702Account.NestedCallbackNotSupported.selector, 0, 1);

        vm.expectRevert(_wrappedPoolFailure(0, nestedFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 0, "nested flags are prevalidated");
    }

    function test_CallbackTargetFailureReportsOuterAndCallbackIndices() external {
        bytes memory targetReason =
            abi.encodeWithSelector(DynamicExecutionTarget.TargetFailure.selector, 77, bytes("callback-failure"));
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        callbackCalls[0] = _recordingCall(1, "runs-before-revert");
        callbackCalls[1] = _dynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.fail, (77, bytes("callback-failure"))),
            _noCheckpoints(),
            _noPatches(),
            false
        );
        bytes memory callbackFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackDynamicCallFailed.selector, 0, 1, address(recordingTarget), targetReason
        );

        vm.expectRevert(_wrappedPoolFailure(0, callbackFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(recordingTarget.count(), 0, "earlier callback target state rolled back");
    }

    function test_ExistingAllowanceIsClearedBeforeExactRepaymentApproval() external {
        flashAsset.setRequireZeroFirstApproval(true);
        flashAsset.setAllowance(accountUnderTest.delegatedEoa, address(pool), 123);

        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.approvalCount(), 2, "zero-first and exact approvals");
        assertEq(flashAsset.approvalAmount(0), 0, "first approval clears old allowance");
        assertEq(flashAsset.approvalAmount(1), FLASH_PRINCIPAL + FLASH_PREMIUM, "second approval is exact repayment");
        assertEq(flashAsset.allowance(accountUnderTest.delegatedEoa, address(pool)), 0, "Pool consumed exact allowance");
    }

    function test_EmptyApprovalReturnDataIsAccepted() external {
        flashAsset.setReturnEmptyApprovalData(true);

        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        _assertFlashLoanWasRepaidExactly();
        assertEq(flashAsset.approvalCount(), 2, "both empty-return approvals accepted");
    }

    function test_InsufficientRepaymentBalanceIsRejectedBeforeApproval() external {
        FlashLoanAssetMock underfundedAsset = new FlashLoanAssetMock();
        underfundedAsset.mint(address(pool), FLASH_PRINCIPAL);
        bytes memory balanceFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentBalanceInsufficient.selector,
            0,
            address(underfundedAsset),
            FLASH_PRINCIPAL,
            FLASH_PRINCIPAL + FLASH_PREMIUM
        );

        vm.expectRevert(_wrappedPoolFailure(0, balanceFailure));
        _executeFlashLoanWithAsset(underfundedAsset, _emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(underfundedAsset.approvalCount(), 0, "no repayment approval on insufficient balance");
    }

    function test_FailedRepaymentBalanceReadPreservesIndexedAssetAndReason() external {
        flashAsset.setBalanceReadBehavior(true, false);
        bytes memory tokenReason = abi.encodeWithSelector(FlashLoanAssetMock.BalanceReadReverted.selector);
        bytes memory balanceFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentBalanceReadFailed.selector, 0, address(flashAsset), tokenReason
        );

        vm.expectRevert(_wrappedPoolFailure(0, balanceFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_ShortRepaymentBalanceReadIsRejectedAsMalformed() external {
        flashAsset.setBalanceReadBehavior(false, true);
        bytes memory balanceFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentBalanceReadFailed.selector, 0, address(flashAsset), hex"1234"
        );

        vm.expectRevert(_wrappedPoolFailure(0, balanceFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_FalseRepaymentApprovalIsRejectedWithRawReturnData() external {
        flashAsset.setApprovalBehavior(true, false, false);
        bytes memory approvalFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentApprovalFailed.selector,
            0,
            address(flashAsset),
            address(pool),
            abi.encode(false)
        );

        vm.expectRevert(_wrappedPoolFailure(0, approvalFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_RevertedRepaymentApprovalPreservesTokenReason() external {
        flashAsset.setApprovalBehavior(false, true, false);
        bytes memory tokenReason = abi.encodeWithSelector(FlashLoanAssetMock.ApprovalReverted.selector, uint256(0));
        bytes memory approvalFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentApprovalFailed.selector,
            0,
            address(flashAsset),
            address(pool),
            tokenReason
        );

        vm.expectRevert(_wrappedPoolFailure(0, approvalFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_ShortRepaymentApprovalReturnDataIsRejected() external {
        flashAsset.setApprovalBehavior(false, false, true);
        bytes memory approvalFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.FlashLoanRepaymentApprovalFailed.selector,
            0,
            address(flashAsset),
            address(pool),
            hex"01"
        );

        vm.expectRevert(_wrappedPoolFailure(0, approvalFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);
    }

    function test_PoolRepaymentPullReturningFalseRevertsEntireBatch() external {
        flashAsset.setTransferFromReturnsFalse(true);
        bytes memory poolFailure = abi.encodeWithSelector(AaveV3FlashLoanPoolMock.RepaymentPullReturnedFalse.selector);

        vm.expectRevert(_wrappedPoolFailure(0, poolFailure));
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.approvalCount(), 0, "failed pull and repayment approval rolled back");
    }

    function test_ResidualAllowanceAfterPartialPoolPullRevertsEntireBatch() external {
        pool.setCustomPullAmount(FLASH_PRINCIPAL);
        uint256 residualPremium = FLASH_PREMIUM;
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(_flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, _emptyCallbackPlan()));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.ResidualFlashLoanAllowance.selector,
                0,
                address(flashAsset),
                address(pool),
                residualPremium
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);

        assertEq(flashAsset.approvalCount(), 0, "partial pull and approvals rolled back");
        assertEq(
            flashAsset.balanceOf(accountUnderTest.delegatedEoa),
            FLASH_PREMIUM,
            "principal and partial repayment rolled back"
        );
    }

    function test_MalformedAllowanceReadAfterRepaymentRevertsEntireBatch() external {
        flashAsset.setAllowanceReadBehavior(false, true);
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(_flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, _emptyCallbackPlan()));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanAllowanceReadFailed.selector,
                0,
                address(flashAsset),
                address(pool),
                hex"1234"
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function test_RevertedAllowanceReadPreservesTokenReason() external {
        flashAsset.setAllowanceReadBehavior(true, false);
        bytes memory allowanceReason = abi.encodeWithSelector(FlashLoanAssetMock.AllowanceReadReverted.selector);
        IDefiSimplify7702Account.DynamicCall[] memory calls =
            _singleCall(_flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, _emptyCallbackPlan()));

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefiSimplify7702Account.FlashLoanAllowanceReadFailed.selector,
                0,
                address(flashAsset),
                address(pool),
                allowanceReason
            )
        );
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(calls);
    }

    function reenterDynamicExecution(address account) external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _recordingCall(999, "must-not-run-reentrant-call");
        IDefiSimplify7702Account(account).executeBatchDynamic(calls);
    }

    function _expectOriginMismatch(AaveV3FlashLoanPoolMock.CallbackMutation mutation) private {
        pool.setCallbackMutation(mutation);
        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, _oneRecordingCallbackCall());
        bytes32 expectedHash = keccak256(flashLoanCall.data);
        bytes32 actualHash = _mutatedOriginHash(mutation, flashLoanCall.data);
        bytes memory originFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackOriginMismatch.selector, 0, expectedHash, actualHash
        );

        vm.expectRevert(_wrappedPoolFailure(0, originFailure));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleCall(flashLoanCall));

        assertEq(recordingTarget.count(), 0, "origin-mismatched callback plan");
        pool.setCallbackMutation(AaveV3FlashLoanPoolMock.CallbackMutation.None);
    }

    function _expectCommittedOuterCalldataRejected(bytes memory committedCalldata, bytes memory callbackParams)
        private
    {
        bytes32 reconstructedOriginHash = keccak256(
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple,
                (accountUnderTest.delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, callbackParams, uint16(0))
            )
        );
        bytes memory originFailure = abi.encodeWithSelector(
            IDefiSimplify7702Account.CallbackOriginMismatch.selector,
            0,
            keccak256(committedCalldata),
            reconstructedOriginHash
        );
        IDefiSimplify7702Account.DynamicCall memory callbackEnabledCall =
            _dynamicCall(address(pool), committedCalldata, _noCheckpoints(), _noPatches(), true);

        vm.expectRevert(_wrappedPoolFailure(0, originFailure));
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleCall(callbackEnabledCall));

        assertEq(recordingTarget.count(), 0, "origin-mismatched callback plan");
    }

    function _mutatedOriginHash(AaveV3FlashLoanPoolMock.CallbackMutation mutation, bytes memory originalCalldata)
        private
        pure
        returns (bytes32)
    {
        (address receiver, address asset, uint256 amount, bytes memory params, uint16 referralCode) =
            abi.decode(_withoutSelector(originalCalldata), (address, address, uint256, bytes, uint16));

        if (mutation == AaveV3FlashLoanPoolMock.CallbackMutation.WrongAsset) {
            asset = address(0xA55E7);
        } else if (mutation == AaveV3FlashLoanPoolMock.CallbackMutation.WrongAmount) {
            amount += 1;
        } else if (mutation == AaveV3FlashLoanPoolMock.CallbackMutation.WrongParams) {
            params = bytes.concat(params, hex"00");
        }

        return keccak256(
            abi.encodeCall(IAaveV3FlashLoanSimplePool.flashLoanSimple, (receiver, asset, amount, params, referralCode))
        );
    }

    function _withoutSelector(bytes memory data) private pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; ++i) {
            arguments[i - 4] = data[i];
        }
    }

    function _executeFlashLoan(IDefiSimplify7702Account.DynamicCall[] memory callbackCalls, uint256 maximumPremium)
        private
    {
        _executeFlashLoanWithAsset(flashAsset, callbackCalls, maximumPremium);
    }

    function _executeFlashLoanWithAsset(
        FlashLoanAssetMock asset,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls,
        uint256 maximumPremium
    ) private {
        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _flashLoanCall(address(asset), FLASH_PRINCIPAL, maximumPremium, callbackCalls);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleCall(flashLoanCall));
    }

    function _buildOuterCallsWithFlashLoanAtIndex(
        uint256 flashLoanIndex,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls
    ) private view returns (IDefiSimplify7702Account.DynamicCall[] memory calls) {
        calls = new IDefiSimplify7702Account.DynamicCall[](3);
        for (uint256 i = 0; i < calls.length; ++i) {
            if (i == flashLoanIndex) {
                calls[i] = _flashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, callbackCalls);
            } else {
                calls[i] = _recordingCall((i + 1) * 10, "outer-ordinary");
            }
        }
    }

    function _flashLoanCall(
        address asset,
        uint256 principal,
        uint256 maximumPremium,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls
    ) private view returns (IDefiSimplify7702Account.DynamicCall memory) {
        bytes memory params = abi.encode(_envelope(maximumPremium, callbackCalls));
        return _dynamicCall(
            address(pool),
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple,
                (accountUnderTest.delegatedEoa, asset, principal, params, uint16(0))
            ),
            _noCheckpoints(),
            _noPatches(),
            true
        );
    }

    function _recordingCall(uint256 amount, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _dynamicCall(
            address(recordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
    }

    function _oneRecordingCallbackCall()
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _recordingCall(1, "authenticated-callback");
    }

    function _dynamicCall(
        address target,
        bytes memory data,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints,
        IDefiSimplify7702Account.BalancePatch[] memory patches,
        bool expectsCallback
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = target;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = patches;
        dynamicCall.expectsCallback = expectsCallback;
    }

    function _envelope(uint256 maximumPremium, IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        private
        pure
        returns (IDefiSimplify7702Account.CallbackEnvelope memory envelope)
    {
        envelope.maxPremium = maximumPremium;
        envelope.callbackCalls = callbackCalls;
    }

    function _checkpointDeltaPatch(address token, bytes32 checkpointId, uint32 offset)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: token,
            checkpointId: checkpointId,
            offset: offset,
            bps: 10_000,
            source: IDefiSimplify7702Account.BalanceSource.CheckpointDelta
        });
    }

    function _oneCheckpoint(address token, bytes32 checkpointId)
        private
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = IDefiSimplify7702Account.BalanceCheckpoint({token: token, id: checkpointId});
    }

    function _onePatch(IDefiSimplify7702Account.BalancePatch memory patch)
        private
        pure
        returns (IDefiSimplify7702Account.BalancePatch[] memory patches)
    {
        patches = new IDefiSimplify7702Account.BalancePatch[](1);
        patches[0] = patch;
    }

    function _emptyCallbackPlan() private pure returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls) {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](0);
    }

    function _noCheckpoints() private pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _noPatches() private pure returns (IDefiSimplify7702Account.BalancePatch[] memory patches) {
        patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _singleCall(IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;
    }

    function _wrappedPoolFailure(uint256 outerCallIndex, bytes memory poolReason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IDefiSimplify7702Account.DynamicCallFailed.selector, outerCallIndex, address(pool), poolReason
        );
    }

    function _assertFlashLoanWasRepaidExactly() private view {
        assertEq(pool.callbackCount(), 1, "exactly one callback");
        assertEq(flashAsset.balanceOf(address(pool)), FLASH_PRINCIPAL + FLASH_PREMIUM, "Pool principal plus premium");
        assertEq(flashAsset.balanceOf(accountUnderTest.delegatedEoa), 0, "account repayment balance");
        assertEq(flashAsset.allowance(accountUnderTest.delegatedEoa, address(pool)), 0, "no residual Pool allowance");
    }

    function _callbackForwarderAddress() private view returns (address forwarder) {
        return pool.callbackForwarder();
    }
}
