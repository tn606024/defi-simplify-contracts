// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "./DelegatedAccountFixture.sol";

/// @dev Shared reviewer-readable fixture for callback adversarial, fuzz, invariant-adjacent,
///      and gas tests. The production account is always exercised through a real delegated EOA.
abstract contract AaveV3FlashLoanFixture is DelegatedAccountFixture {
    uint256 internal constant FLASH_PRINCIPAL = 1_000 ether;
    uint256 internal constant FLASH_PREMIUM = 1 ether;

    DelegatedDefiSimplifyAccount internal accountUnderTest;
    AaveV3FlashLoanPoolMock internal flashLoanPool;
    FlashLoanAssetMock internal flashAsset;
    DynamicExecutionTarget internal callbackRecordingTarget;

    function _setUpAaveV3FlashLoanFixture(IEntryPoint entryPoint) internal {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(entryPoint);
        flashLoanPool = new AaveV3FlashLoanPoolMock();
        flashAsset = new FlashLoanAssetMock();
        callbackRecordingTarget = new DynamicExecutionTarget();

        flashLoanPool.setPremium(FLASH_PREMIUM);
        flashAsset.mint(address(flashLoanPool), FLASH_PRINCIPAL);
        flashAsset.mint(accountUnderTest.delegatedEoa, FLASH_PREMIUM);
    }

    function _executeFlashLoan(IDefiSimplify7702Account.DynamicCall[] memory callbackCalls, uint256 maximumPremium)
        internal
    {
        _executeFlashLoanWithAsset(flashAsset, FLASH_PRINCIPAL, callbackCalls, maximumPremium);
    }

    function _executeFlashLoanWithAsset(
        FlashLoanAssetMock asset,
        uint256 principal,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls,
        uint256 maximumPremium
    ) internal {
        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _buildFlashLoanCall(address(asset), principal, maximumPremium, callbackCalls);
        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleDynamicCall(flashLoanCall));
    }

    function _buildFlashLoanCall(
        address asset,
        uint256 principal,
        uint256 maximumPremium,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls
    ) internal view returns (IDefiSimplify7702Account.DynamicCall memory) {
        bytes memory params = abi.encode(_buildCallbackEnvelope(maximumPremium, callbackCalls));
        return _buildDynamicCall(
            address(flashLoanPool),
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple,
                (accountUnderTest.delegatedEoa, asset, principal, params, uint16(0))
            ),
            _noCheckpoints(),
            _noPatches(),
            true
        );
    }

    function _buildRecordingCall(uint256 amount, bytes memory payload)
        internal
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return _buildDynamicCall(
            address(callbackRecordingTarget),
            abi.encodeCall(DynamicExecutionTarget.record, (amount, payload)),
            _noCheckpoints(),
            _noPatches(),
            false
        );
    }

    function _buildDynamicCall(
        address target,
        bytes memory data,
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints,
        IDefiSimplify7702Account.BalancePatch[] memory patches,
        bool expectsCallback
    ) internal pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = target;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = checkpoints;
        dynamicCall.patches = patches;
        dynamicCall.expectsCallback = expectsCallback;
    }

    function _buildCallbackEnvelope(uint256 maximumPremium, IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        internal
        pure
        returns (IDefiSimplify7702Account.CallbackEnvelope memory envelope)
    {
        envelope.maxPremium = maximumPremium;
        envelope.callbackCalls = callbackCalls;
    }

    function _oneCheckpoint(address token, bytes32 checkpointId)
        internal
        pure
        returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints)
    {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](1);
        checkpoints[0] = IDefiSimplify7702Account.BalanceCheckpoint({token: token, id: checkpointId});
    }

    function _onePatch(IDefiSimplify7702Account.BalancePatch memory patch)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch[] memory patches)
    {
        patches = new IDefiSimplify7702Account.BalancePatch[](1);
        patches[0] = patch;
    }

    function _checkpointDeltaPatch(address token, bytes32 checkpointId, uint32 offset)
        internal
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

    function _currentBalancePatch(address token, uint32 offset, uint16 bps)
        internal
        pure
        returns (IDefiSimplify7702Account.BalancePatch memory)
    {
        return IDefiSimplify7702Account.BalancePatch({
            token: token,
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }

    function _emptyCallbackPlan() internal pure returns (IDefiSimplify7702Account.DynamicCall[] memory callbackCalls) {
        callbackCalls = new IDefiSimplify7702Account.DynamicCall[](0);
    }

    function _noCheckpoints() internal pure returns (IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints) {
        checkpoints = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
    }

    function _noPatches() internal pure returns (IDefiSimplify7702Account.BalancePatch[] memory patches) {
        patches = new IDefiSimplify7702Account.BalancePatch[](0);
    }

    function _singleDynamicCall(IDefiSimplify7702Account.DynamicCall memory dynamicCall)
        internal
        pure
        returns (IDefiSimplify7702Account.DynamicCall[] memory calls)
    {
        calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = dynamicCall;
    }

    function _wrappedFlashLoanTargetFailure(uint256 outerCallIndex, bytes memory targetReason)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IDefiSimplify7702Account.DynamicCallFailed.selector, outerCallIndex, address(flashLoanPool), targetReason
        );
    }

    function _assertFlashLoanRepaidExactly(FlashLoanAssetMock asset, uint256 principal, uint256 premium) internal view {
        assertEq(flashLoanPool.callbackCount(), 1, "exactly one authenticated callback");
        assertEq(asset.balanceOf(address(flashLoanPool)), principal + premium, "Pool receives principal plus premium");
        assertEq(asset.balanceOf(accountUnderTest.delegatedEoa), 0, "account spends repayment balance");
        assertEq(
            asset.allowance(accountUnderTest.delegatedEoa, address(flashLoanPool)),
            0,
            "successful flash loan leaves no Pool allowance"
        );
    }
}
