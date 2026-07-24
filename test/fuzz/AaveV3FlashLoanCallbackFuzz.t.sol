// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {AaveV3FlashLoanPoolMock, FlashLoanAssetMock} from "../mocks/AaveV3FlashLoanMocks.sol";
import {PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {AaveV3FlashLoanFixture} from "../utils/AaveV3FlashLoanFixture.sol";

contract AaveV3FlashLoanCallbackFuzzTest is AaveV3FlashLoanFixture {
    function setUp() external {
        _setUpAaveV3FlashLoanFixture(IEntryPoint(address(this)));
    }

    function testFuzz_PatchedPrincipalCommitmentAlwaysMatchesBytesSentToPool(
        uint128 balanceSeed,
        uint16 basisPointsSeed
    ) external {
        uint256 amountSourceBalance = bound(uint256(balanceSeed), 1, type(uint120).max);
        uint16 basisPoints = uint16(bound(uint256(basisPointsSeed), 1, 10_000));
        uint256 patchedPrincipal = amountSourceBalance * basisPoints / 10_000;

        PatchBalanceToken amountSource = new PatchBalanceToken();
        FlashLoanAssetMock patchedFlashAsset = new FlashLoanAssetMock();
        amountSource.setBalance(accountUnderTest.delegatedEoa, amountSourceBalance);
        patchedFlashAsset.mint(address(flashLoanPool), patchedPrincipal);
        flashLoanPool.setPremium(0);

        IDefiSimplify7702Account.DynamicCall memory flashLoanCall =
            _buildFlashLoanCall(address(patchedFlashAsset), 777, 0, _emptyCallbackPlan());
        flashLoanCall.patches = _onePatch(_currentBalancePatch(address(amountSource), 68, basisPoints));

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(_singleDynamicCall(flashLoanCall));

        bytes memory expectedPatchedCalldata = abi.encodeCall(
            IAaveV3FlashLoanSimplePool.flashLoanSimple,
            (
                accountUnderTest.delegatedEoa,
                address(patchedFlashAsset),
                patchedPrincipal,
                abi.encode(_buildCallbackEnvelope(0, _emptyCallbackPlan())),
                uint16(0)
            )
        );
        assertEq(
            flashLoanPool.lastReceivedCalldataHash(),
            keccak256(expectedPatchedCalldata),
            "commitment must bind exact patched bytes"
        );
        assertEq(
            patchedFlashAsset.balanceOf(address(flashLoanPool)),
            patchedPrincipal,
            "fuzzed principal is returned exactly"
        );
    }

    function testFuzz_CallbackEnabledCallAtAnyOuterIndexPreservesEveryOrdinaryCall(
        uint8 outerLengthSeed,
        uint8 callbackIndexSeed,
        uint8 callbackPlanLengthSeed
    ) external {
        uint256 outerLength = bound(uint256(outerLengthSeed), 1, 8);
        uint256 callbackIndex = bound(uint256(callbackIndexSeed), 0, outerLength - 1);
        uint256 callbackPlanLength = bound(uint256(callbackPlanLengthSeed), 0, 6);

        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            new IDefiSimplify7702Account.DynamicCall[](callbackPlanLength);
        uint256 expectedAmountTotal;
        for (uint256 i = 0; i < callbackPlanLength; ++i) {
            uint256 callbackAmount = i + 1;
            callbackCalls[i] = _buildRecordingCall(callbackAmount, "fuzz-callback");
            expectedAmountTotal += callbackAmount;
        }

        IDefiSimplify7702Account.DynamicCall[] memory outerCalls =
            new IDefiSimplify7702Account.DynamicCall[](outerLength);
        for (uint256 i = 0; i < outerLength; ++i) {
            if (i == callbackIndex) {
                outerCalls[i] = _buildFlashLoanCall(address(flashAsset), FLASH_PRINCIPAL, FLASH_PREMIUM, callbackCalls);
            } else {
                uint256 ordinaryAmount = 10 + i;
                outerCalls[i] = _buildRecordingCall(ordinaryAmount, "fuzz-outer");
                expectedAmountTotal += ordinaryAmount;
            }
        }

        _dynamicExecutionInterfaceView(accountUnderTest).executeBatchDynamic(outerCalls);

        assertEq(
            callbackRecordingTarget.count(),
            outerLength - 1 + callbackPlanLength,
            "every ordinary outer and callback call executes once"
        );
        assertEq(callbackRecordingTarget.total(), expectedAmountTotal, "outer and callback ordering preserves amounts");
        _assertFlashLoanRepaidExactly(flashAsset, FLASH_PRINCIPAL, FLASH_PREMIUM);
    }

    function testFuzz_NestedCallbackFlagAtAnyPlanIndexRejectsEntirePlanBeforeFirstTarget(
        uint8 callbackPlanLengthSeed,
        uint8 nestedIndexSeed
    ) external {
        uint256 callbackPlanLength = bound(uint256(callbackPlanLengthSeed), 1, 8);
        uint256 nestedIndex = bound(uint256(nestedIndexSeed), 0, callbackPlanLength - 1);
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls =
            new IDefiSimplify7702Account.DynamicCall[](callbackPlanLength);
        for (uint256 i = 0; i < callbackPlanLength; ++i) {
            callbackCalls[i] = _buildRecordingCall(i + 1, "must-not-run-before-nested-validation");
        }
        callbackCalls[nestedIndex].expectsCallback = true;
        bytes memory nestedCallbackFailure =
            abi.encodeWithSelector(IDefiSimplify7702Account.NestedCallbackNotSupported.selector, 0, nestedIndex);

        vm.expectRevert(_wrappedFlashLoanTargetFailure(0, nestedCallbackFailure));
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 0, "nested flags are prevalidated for every index");
    }

    function testFuzz_ExactRepaymentClearsAnyStartingAllowance(
        uint128 principalSeed,
        uint96 premiumSeed,
        uint128 startingAllowanceSeed
    ) external {
        uint256 principal = bound(uint256(principalSeed), 1, type(uint120).max);
        uint256 premium = bound(uint256(premiumSeed), 0, type(uint88).max);
        uint256 startingAllowance = uint256(startingAllowanceSeed);
        FlashLoanAssetMock fuzzedAsset = new FlashLoanAssetMock();
        fuzzedAsset.mint(address(flashLoanPool), principal);
        fuzzedAsset.mint(accountUnderTest.delegatedEoa, premium);
        fuzzedAsset.setAllowance(accountUnderTest.delegatedEoa, address(flashLoanPool), startingAllowance);
        fuzzedAsset.setRequireZeroFirstApproval(true);
        flashLoanPool.setPremium(premium);

        _executeFlashLoanWithAsset(fuzzedAsset, principal, _emptyCallbackPlan(), premium);

        assertEq(fuzzedAsset.approvalAmount(0), 0, "zero-first approval clears arbitrary preexisting allowance");
        assertEq(fuzzedAsset.approvalAmount(1), principal + premium, "second approval is exact repayment");
        assertEq(
            fuzzedAsset.allowance(accountUnderTest.delegatedEoa, address(flashLoanPool)),
            0,
            "Pool consumes exact repayment allowance"
        );
    }

    function testFuzz_OriginFieldMutationNeverExecutesCallbackPlan(uint8 mutationSeed) external {
        uint256 mutationOrdinal = bound(
            uint256(mutationSeed),
            uint256(AaveV3FlashLoanPoolMock.CallbackMutation.WrongAsset),
            uint256(AaveV3FlashLoanPoolMock.CallbackMutation.WrongParams)
        );
        flashLoanPool.setCallbackMutation(AaveV3FlashLoanPoolMock.CallbackMutation(mutationOrdinal));
        IDefiSimplify7702Account.DynamicCall[] memory callbackCalls = new IDefiSimplify7702Account.DynamicCall[](1);
        callbackCalls[0] = _buildRecordingCall(1, "origin-mutation-must-not-run");

        vm.expectRevert();
        _executeFlashLoan(callbackCalls, FLASH_PREMIUM);

        assertEq(callbackRecordingTarget.count(), 0, "origin mutation cannot authorize callback plan");
    }
}
