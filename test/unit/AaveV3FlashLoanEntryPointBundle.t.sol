// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {CheckpointTableHarness} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract AaveV3FlashLoanEntryPointBundleTest is DelegatedAccountFixture {
    uint256 private constant ACCOUNT_AUTHORITY_KEY = 0xF1A581;
    uint256 private constant FLASH_PRINCIPAL = 1_000 ether;
    uint256 private constant FLASH_PREMIUM = 1 ether;
    address private constant BUNDLER = address(0xB0D1E);
    address payable private constant BENEFICIARY = payable(address(0xBEEF));

    EntryPoint private entryPoint;
    CheckpointTableHarness private callbackCheckpointHarnessImplementation;
    address payable private delegatedEoa;
    AaveV3FlashLoanPoolMock private flashLoanPool;
    FlashLoanAssetMock private flashAsset;
    DynamicExecutionTarget private callbackRecordingTarget;

    function setUp() external {
        entryPoint = new EntryPoint();
        callbackCheckpointHarnessImplementation = new CheckpointTableHarness(entryPoint);
        delegatedEoa = payable(vm.addr(ACCOUNT_AUTHORITY_KEY));
        require(delegatedEoa.code.length == 0, "flash bundle authority already has code");
        vm.signAndAttachDelegation(address(callbackCheckpointHarnessImplementation), ACCOUNT_AUTHORITY_KEY);
        require(_delegationTarget(delegatedEoa) == address(callbackCheckpointHarnessImplementation), "wrong delegation");

        flashLoanPool = new AaveV3FlashLoanPoolMock();
        flashAsset = new FlashLoanAssetMock();
        callbackRecordingTarget = new DynamicExecutionTarget();
        flashLoanPool.setPremium(FLASH_PREMIUM);
        flashAsset.mint(address(flashLoanPool), FLASH_PRINCIPAL);
        flashAsset.mint(delegatedEoa, FLASH_PREMIUM * 3);
    }

    function test_MultipleFlashLoanUserOperationsAllocateIndependentOuterAndCallbackScopes() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](2);
        operations[0] = _buildSignedUserOperation(0, _oneRecordingCallbackCall(11, "first-flash"));
        operations[1] = _buildSignedUserOperation(1, _oneRecordingCallbackCall(22, "second-flash"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(callbackRecordingTarget.count(), 2, "both callback plans execute");
        assertEq(callbackRecordingTarget.total(), 33, "both callback amounts commit");
        assertEq(flashLoanPool.callbackCount(), 2, "each UserOperation consumes one callback");
        assertEq(_currentInvocationCounter(), 4, "each success allocates one outer and one callback scope");
        assertEq(flashAsset.allowance(delegatedEoa, address(flashLoanPool)), 0, "bundle leaves no Pool allowance");
    }

    function test_RevertedFlashLoanUserOperationBetweenSuccessesDoesNotConsumeTransientScopes() external {
        PackedUserOperation[] memory operations = new PackedUserOperation[](3);
        operations[0] = _buildSignedUserOperation(0, _oneRecordingCallbackCall(13, "before-failure"));
        operations[1] = _buildSignedUserOperation(1, _oneFailingCallbackCall());
        operations[2] = _buildSignedUserOperation(2, _oneRecordingCallbackCall(29, "after-failure"));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(callbackRecordingTarget.count(), 2, "bundle continues after failed callback execution");
        assertEq(callbackRecordingTarget.total(), 42, "failed callback target state rolls back");
        assertEq(flashLoanPool.callbackCount(), 2, "failed Pool callback count rolls back");
        assertEq(_currentInvocationCounter(), 4, "failed operation does not retain two tentative scopes");
        assertEq(flashAsset.allowance(delegatedEoa, address(flashLoanPool)), 0, "bundle leaves no Pool allowance");
    }

    function test_CallbackPlanTargetingActiveEntryPointCannotStartNestedHandleOps() external {
        PackedUserOperation[] memory nestedOperations = new PackedUserOperation[](0);
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0].target = address(entryPoint);
        callbackCalls[0].data = abi.encodeCall(IEntryPoint.handleOps, (nestedOperations, BENEFICIARY));
        callbackCalls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        callbackCalls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);

        PackedUserOperation[] memory operations = new PackedUserOperation[](1);
        operations[0] = _buildSignedUserOperation(0, callbackCalls);

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, BENEFICIARY);

        assertEq(callbackRecordingTarget.count(), 0, "nested EntryPoint plan has no later target state");
        assertEq(flashLoanPool.callbackCount(), 0, "nested EntryPoint failure rolls back callback");
        assertEq(_currentInvocationCounter(), 0, "nested EntryPoint failure rolls back both scopes");
        assertEq(flashAsset.allowance(delegatedEoa, address(flashLoanPool)), 0, "failure leaves no allowance");
    }

    function _buildSignedUserOperation(uint256 nonce, IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        IDefiSimplify7702Account.DynamicCall[] memory outerCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        outerCalls[0] = _flashLoanCall(callbackCalls);

        operation.sender = delegatedEoa;
        operation.nonce = nonce;
        operation.callData = abi.encodeCall(IDefiSimplify7702Account.executeBatchDynamic, (outerCalls));
        operation.accountGasLimits = bytes32((uint256(2_000_000) << 128) | uint256(2_000_000));
        operation.preVerificationGas = 100_000;
        operation.gasFees = bytes32(0);
        operation.signature = _signature(ACCOUNT_AUTHORITY_KEY, entryPoint.getUserOpHash(operation));
    }

    function _flashLoanCall(IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall)
    {
        IDefiSimplify7702Account.CallbackEnvelope memory envelope =
            IDefiSimplify7702Account.CallbackEnvelope({maxPremium: FLASH_PREMIUM, callbackCalls: callbackCalls});
        dynamicCall.target = address(flashLoanPool);
        dynamicCall.data = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (delegatedEoa, address(flashAsset), FLASH_PRINCIPAL, abi.encode(envelope), uint16(0))
        );
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](0);
        dynamicCall.expectsCallback = true;
    }

    function _oneRecordingCallbackCall(uint256 amount, bytes memory payload)
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0].target = address(callbackRecordingTarget);
        callbackCalls[0].data = abi.encodeCall(DynamicExecutionTarget.record, (amount, payload));
        callbackCalls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        callbackCalls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _oneFailingCallbackCall()
        private
        view
        returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
    {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0].target = address(callbackRecordingTarget);
        callbackCalls[0].data =
            abi.encodeCall(DynamicExecutionTarget.fail, (uint256(81), bytes("bundle-callback-failure")));
        callbackCalls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        callbackCalls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _currentInvocationCounter() private returns (uint256 counter) {
        vm.prank(delegatedEoa);
        counter = CheckpointTableHarness(delegatedEoa).invocationCounter();
    }
}
