// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {TransientCallbackCommitment} from "../../src/libraries/TransientCallbackCommitment.sol";
import {TransientDynamicExecutionLock} from "../../src/libraries/TransientDynamicExecutionLock.sol";
import {TransientInvocationCounter} from "../../src/libraries/TransientInvocationCounter.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract CallbackInvariantAccountHarness is DefiSimplify7702Account {
    constructor(IEntryPoint entryPoint) DefiSimplify7702Account(entryPoint) {}

    function callbackCommitment()
        external
        view
        returns (
            TransientCallbackCommitment.CallbackState state,
            address target,
            bytes32 calldataHash,
            uint256 callIndex,
            address repaymentToken
        )
    {
        _requireForExecute();
        return (
            TransientCallbackCommitment.state(),
            TransientCallbackCommitment.target(),
            TransientCallbackCommitment.calldataHash(),
            TransientCallbackCommitment.callIndex(),
            TransientCallbackCommitment.repaymentToken()
        );
    }

    function invocationCounter() external view returns (uint256) {
        _requireForExecute();
        return TransientInvocationCounter.current();
    }

    function dynamicExecutionLocked() external view returns (bool) {
        _requireForExecute();
        return TransientDynamicExecutionLock.isLocked();
    }
}

contract AaveV3FlashLoanCallbackInvariantHandler {
    uint256 private constant PRINCIPAL = 1_000 ether;

    AaveV3FlashLoanPoolMock public immutable flashLoanPool;
    FlashLoanAssetMock public immutable flashAsset;
    DynamicExecutionTarget public immutable callbackRecordingTarget;

    address payable public delegatedEoa;
    uint256 public expectedSuccessfulCallbackCalls;
    uint256 public expectedSuccessfulCallbackAmount;
    uint256 public completedPostconditionChecks;
    bool public allPostconditionsPassed = true;

    constructor() {
        flashLoanPool = new AaveV3FlashLoanPoolMock();
        flashAsset = new FlashLoanAssetMock();
        callbackRecordingTarget = new DynamicExecutionTarget();
        flashAsset.mint(address(flashLoanPool), PRINCIPAL);
    }

    function initialize(address payable newDelegatedEoa) external {
        require(delegatedEoa == address(0), "handler already initialized");
        delegatedEoa = newDelegatedEoa;
    }

    function exerciseSuccessfulFlash(uint96 premiumSeed, uint8 callbackPlanLengthSeed, uint128 allowanceSeed) external {
        uint256 premium = uint256(premiumSeed) % 10 ether;
        uint256 callbackPlanLength = uint256(callbackPlanLengthSeed) % 4;
        flashLoanPool.setPremium(premium);
        flashAsset.mint(delegatedEoa, premium);
        flashAsset.setAllowance(delegatedEoa, address(flashLoanPool), uint256(allowanceSeed));
        flashAsset.setRequireZeroFirstApproval(true);

        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            new IDefiSimplify7702Account.DynamicCall[](callbackPlanLength);
        uint256 callbackAmountTotal;
        for (uint256 i = 0; i < callbackPlanLength; ++i) {
            uint256 callbackAmount = i + 1;
            callbackCalls[i] = _recordingCall(callbackAmount);
            callbackAmountTotal += callbackAmount;
        }

        uint256 counterBefore = _invocationCounter();
        (bool succeeded,) = delegatedEoa.call(
            abi.encodeCall(
                IDefiSimplify7702Account.executeBatchDynamic, (_singleCall(_flashLoanCall(premium, callbackCalls)))
            )
        );
        require(succeeded, "modeled successful flash reverted");
        require(_invocationCounter() == counterBefore + 2, "success did not allocate outer and callback scopes");
        require(flashAsset.allowance(delegatedEoa, address(flashLoanPool)) == 0, "success left repayment allowance");

        expectedSuccessfulCallbackCalls += callbackPlanLength;
        expectedSuccessfulCallbackAmount += callbackAmountTotal;
        _recordCompletedPostconditions();
    }

    function exerciseMissingCallbackRollback(uint96 premiumSeed) external {
        uint256 premium = uint256(premiumSeed) % 10 ether;
        flashLoanPool.setPremium(premium);
        flashLoanPool.setSkipCallback(true);
        flashLoanPool.setPullRepayment(false);
        flashAsset.mint(delegatedEoa, premium);
        uint256 counterBefore = _invocationCounter();
        uint256 poolBalanceBefore = flashAsset.balanceOf(address(flashLoanPool));
        uint256 accountBalanceBefore = flashAsset.balanceOf(delegatedEoa);

        (bool succeeded,) = delegatedEoa.call(
            abi.encodeCall(
                IDefiSimplify7702Account.executeBatchDynamic,
                (_singleCall(_flashLoanCall(premium, _emptyCallbackPlan())))
            )
        );
        require(!succeeded, "missing callback unexpectedly succeeded");
        flashLoanPool.setSkipCallback(false);
        flashLoanPool.setPullRepayment(true);

        require(_invocationCounter() == counterBefore, "failed flash consumed invocation ID");
        require(flashAsset.balanceOf(address(flashLoanPool)) == poolBalanceBefore, "failed flash changed Pool balance");
        require(flashAsset.balanceOf(delegatedEoa) == accountBalanceBefore, "failed flash changed account balance");
        _recordCompletedPostconditions();
    }

    function exerciseCallbackPlanRollback(uint64 recordedAmountSeed) external {
        uint256 recordedAmount = uint256(recordedAmountSeed);
        flashLoanPool.setPremium(0);
        uint256 targetCountBefore = callbackRecordingTarget.count();
        uint256 targetAmountBefore = callbackRecordingTarget.total();
        uint256 counterBefore = _invocationCounter();

        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](2);
        callbackCalls[0] = _recordingCall(recordedAmount);
        callbackCalls[1] = _failingCall();
        (bool succeeded,) = delegatedEoa.call(
            abi.encodeCall(
                IDefiSimplify7702Account.executeBatchDynamic, (_singleCall(_flashLoanCall(0, callbackCalls)))
            )
        );
        require(!succeeded, "failing callback plan unexpectedly succeeded");
        require(_invocationCounter() == counterBefore, "reverted callback consumed invocation ID");
        require(callbackRecordingTarget.count() == targetCountBefore, "reverted callback kept target count");
        require(callbackRecordingTarget.total() == targetAmountBefore, "reverted callback kept target amount");
        _recordCompletedPostconditions();
    }

    function exerciseSuccessFailureSuccessInOneTransaction(uint64 firstAmountSeed, uint64 secondAmountSeed) external {
        uint256 firstAmount = uint256(firstAmountSeed);
        uint256 secondAmount = uint256(secondAmountSeed);
        flashLoanPool.setPremium(0);
        uint256 counterBefore = _invocationCounter();

        _requireFlashSuccess(_oneRecordingCall(firstAmount));
        uint256 counterAfterFirstSuccess = _invocationCounter();
        require(counterAfterFirstSuccess == counterBefore + 2, "first success scope count");

        IDefiSimplify7702Account.DynamicCall[] memory failingPlan = new IDefiSimplify7702Account.DynamicCall[](1);
        failingPlan[0] = _failingCall();
        (bool failedCallSucceeded,) = delegatedEoa.call(
            abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (_singleCall(_flashLoanCall(0, failingPlan))))
        );
        require(!failedCallSucceeded, "middle callback failure unexpectedly succeeded");
        require(_invocationCounter() == counterAfterFirstSuccess, "middle failure consumed scopes");

        _requireFlashSuccess(_oneRecordingCall(secondAmount));
        require(_invocationCounter() == counterBefore + 4, "two successes did not retain four scopes");

        expectedSuccessfulCallbackCalls += 2;
        expectedSuccessfulCallbackAmount += firstAmount + secondAmount;
        _recordCompletedPostconditions();
    }

    function _requireFlashSuccess(IDefiSimplify7702Account.DynamicCall[] memory callbackCalls) private {
        (bool succeeded,) = delegatedEoa.call(
            abi.encodeCall(
                IDefiSimplify7702Account.executeBatchDynamic, (_singleCall(_flashLoanCall(0, callbackCalls)))
            )
        );
        require(succeeded, "sequential flash unexpectedly reverted");
    }

    function _recordCompletedPostconditions() private {
        (
            TransientCallbackCommitment.CallbackState state,
            address target,
            bytes32 calldataHash,
            uint256 callIndex,
            address repaymentToken
        ) = CallbackInvariantAccountHarness(delegatedEoa).callbackCommitment();
        bool postconditionsPassed = state == TransientCallbackCommitment.CallbackState.Idle && target == address(0)
            && calldataHash == bytes32(0) && callIndex == 0 && repaymentToken == address(0)
            && !CallbackInvariantAccountHarness(delegatedEoa).dynamicExecutionLocked()
            && flashAsset.allowance(delegatedEoa, address(flashLoanPool)) == 0;
        allPostconditionsPassed = allPostconditionsPassed && postconditionsPassed;
        completedPostconditionChecks += 1;
    }

    function _invocationCounter() private view returns (uint256) {
        return CallbackInvariantAccountHarness(delegatedEoa).invocationCounter();
    }

    function _flashLoanCall(uint256 maximumPremium, IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        IDefiSimplify7702Account.CallbackEnvelope memory envelope = IDefiSimplify7702Account.CallbackEnvelope({
            maxPremium: maximumPremium, callbackCalls: callbackCalls
        });
        dynamicCall.target = address(flashLoanPool);
        dynamicCall.data = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (delegatedEoa, address(flashAsset), PRINCIPAL, abi.encode(envelope), uint16(0))
        );
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
        dynamicCall.expectsCallback = true;
    }

    function _recordingCall(uint256 amount)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        dynamicCall.target = address(callbackRecordingTarget);
        dynamicCall.data = abi.encodeCall(DynamicExecutionTarget.record, (amount, bytes("invariant-success")));
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _failingCall() private view returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = address(callbackRecordingTarget);
        dynamicCall.data = abi.encodeCall(DynamicExecutionTarget.fail, (uint256(81), bytes("invariant-failure")));
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _oneRecordingCall(uint256 amount)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _recordingCall(amount);
    }

    function _singleCall(IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        private
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;
    }

    function _emptyCallbackPlan() private pure returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls) {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](0);
    }
}

contract AaveV3FlashLoanCallbackInvariantTest is DelegatedAccountFixture {
    uint256 private constant CALLBACK_INVARIANT_AUTHORITY_KEY =
        0x23df36d1f089ac03a05df44d4fb7caacbfb7d94f33c18b1fdd77f99e4f523582;

    AaveV3FlashLoanCallbackInvariantHandler private scenarioHandler;
    CallbackInvariantAccountHarness private callbackHarnessImplementation;
    address payable private delegatedEoa;

    function setUp() external {
        scenarioHandler = new AaveV3FlashLoanCallbackInvariantHandler();
        callbackHarnessImplementation = new CallbackInvariantAccountHarness(IEntryPoint(address(scenarioHandler)));
        delegatedEoa = payable(vm.addr(CALLBACK_INVARIANT_AUTHORITY_KEY));
        require(delegatedEoa.code.length == 0, "callback invariant authority already has code");
        vm.signAndAttachDelegation(address(callbackHarnessImplementation), CALLBACK_INVARIANT_AUTHORITY_KEY);
        require(_delegationTarget(delegatedEoa) == address(callbackHarnessImplementation), "wrong callback delegation");
        scenarioHandler.initialize(delegatedEoa);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = scenarioHandler.exerciseSuccessfulFlash.selector;
        selectors[1] = scenarioHandler.exerciseMissingCallbackRollback.selector;
        selectors[2] = scenarioHandler.exerciseCallbackPlanRollback.selector;
        selectors[3] = scenarioHandler.exerciseSuccessFailureSuccessInOneTransaction.selector;
        targetContract(address(scenarioHandler));
        targetSelector(FuzzSelector({addr: address(scenarioHandler), selectors: selectors}));
    }

    function invariant_CompletedCallbackActionsAlwaysRestoreIdleClearedUnlockedState() external view {
        assertTrue(scenarioHandler.allPostconditionsPassed(), "callback postcondition failed");
    }

    function invariant_CallbackTargetStateMatchesOnlySuccessfulPlans() external view {
        DynamicExecutionTarget recordingTarget = scenarioHandler.callbackRecordingTarget();
        assertEq(
            recordingTarget.count(),
            scenarioHandler.expectedSuccessfulCallbackCalls(),
            "reverted callback changed target count"
        );
        assertEq(
            recordingTarget.total(),
            scenarioHandler.expectedSuccessfulCallbackAmount(),
            "reverted callback changed target amount"
        );
    }

    function invariant_DelegationTargetRemainsCallbackHarness() external view {
        assertEq(delegatedEoa.code.length, 23, "callback delegation indicator length");
        assertEq(_delegationTarget(delegatedEoa), address(callbackHarnessImplementation), "callback delegation changed");
    }
}
