// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanFixture} from "../utils/AaveV3FlashLoanFixture.sol";

contract AaveV3FlashLoanGasTest is AaveV3FlashLoanFixture {
    function setUp() external {
        _setUpAaveV3FlashLoanFixture(IEntryPoint(address(this)));
    }

    function test_Gas_CallbackWindowWithEmptyPlanAndExactRepayment() external {
        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        _assertFlashLoanRepaidExactly(flashAsset, FLASH_PRINCIPAL, FLASH_PREMIUM);
    }

    function test_Gas_CallbackWindowWithOneOrdinaryCallbackCall() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildRecordingCall(1, "one-callback-call");

        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 1, "one callback call");
    }

    function test_Gas_CallbackWindowWithFourOrdinaryCallbackCalls() external {
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](4);
        for (uint256 i = 0; i < callbackCalls.length; ++i) {
            callbackCalls[i] = _buildRecordingCall(i + 1, "four-callback-calls");
        }

        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 4, "four callback calls");
        assertEq(callbackRecordingTarget.total(), 10, "four callback amounts");
    }

    function test_Gas_ExactRepaymentClearsPreexistingAllowance() external {
        flashAsset.setRequireZeroFirstApproval(true);
        flashAsset.setAllowance(accountUnderTest.delegatedEoa, address(flashLoanPool), 123 ether);

        _executeFlashLoan(_emptyCallbackPlan(), FLASH_PREMIUM);

        assertEq(flashAsset.approvalAmount(0), 0, "first approval clears allowance");
        assertEq(flashAsset.approvalAmount(1), FLASH_PRINCIPAL + FLASH_PREMIUM, "second approval is exact");
    }
}
