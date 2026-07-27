// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "./DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "./DynamicCallTestBuilder.sol";

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
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeBatchDynamic(DynamicCallTestBuilder.singleCall(flashLoanCall));
    }

    function _buildFlashLoanCall(
        address asset,
        uint256 principal,
        uint256 maximumPremium,
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls
    ) internal view returns (IDefiSimplify7702Account.DynamicCall memory) {
        bytes memory params = abi.encode(_buildCallbackEnvelope(maximumPremium, callbackCalls));
        return DynamicCallTestBuilder.buildZeroValueCall(
            address(flashLoanPool),
            abi.encodeCall(
                IAaveV3FlashLoanSimplePool.flashLoanSimple,
                (accountUnderTest.delegatedEoa, asset, principal, params, uint16(0))
            ),
            DynamicCallTestBuilder.noCheckpoints(),
            DynamicCallTestBuilder.noPatches(),
            true
        );
    }

    function _buildRecordingCall(uint256 amount, bytes memory payload)
        internal
        view
        returns (IDefiSimplify7702Account.DynamicCall memory)
    {
        return DynamicCallTestBuilder.buildZeroValueOrdinaryCall(
            address(callbackRecordingTarget), abi.encodeCall(DynamicExecutionTarget.record, (amount, payload))
        );
    }

    function _buildCallbackEnvelope(uint256 maximumPremium, IDefiSimplify7702Account.DynamicCall[] memory callbackCalls)
        internal
        pure
        returns (IDefiSimplify7702Account.CallbackEnvelope memory envelope)
    {
        envelope.maxPremium = maximumPremium;
        envelope.callbackCalls = callbackCalls;
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
