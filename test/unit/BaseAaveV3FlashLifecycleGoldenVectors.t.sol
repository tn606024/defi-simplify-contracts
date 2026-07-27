// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FlowAssertions} from "../../src/FlowAssertions.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {BaseAaveV3FlashLifecycleFixture} from "../fork/BaseAaveV3FlashLifecycleFixture.sol";

/// @dev Freezes every DSC-82 patched word plus the complete full-close callback parameters and origin.
contract BaseAaveV3FlashLifecycleGoldenVectorsTest is BaseAaveV3FlashLifecycleFixture {
    string private constant FIXTURE_PATH = "abi/BaseAaveV3FlashLifecycle.golden.json";

    address private constant FIXTURE_DELEGATED_EOA = 0x1111111111111111111111111111111111111111;
    FlowAssertions private constant FIXTURE_FLOW_ASSERTIONS =
        FlowAssertions(0x2222222222222222222222222222222222222222);
    StaticCallUint256Assertions private constant FIXTURE_STATIC_ASSERTIONS =
        StaticCallUint256Assertions(0x3333333333333333333333333333333333333333);

    uint256 private constant FULL_CLOSE_OBSERVED_DEBT = 200_000_000_000_000_001;
    uint256 private constant FULL_CLOSE_WITHDRAWN_CBETH = 499_999_999_999_999_999;

    function test_GoldenFullCloseOriginBindsPatchedDebtAndCompleteCallbackParameters() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        IDefiSimplify7702Account.DynamicCall[] memory calls = _fullCloseCalls();
        bytes memory originalOrigin = calls[0].data;
        bytes memory patchedOrigin =
            _copyAndReplaceWord(originalOrigin, FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET, FULL_CLOSE_OBSERVED_DEBT);
        bytes memory callbackParams = _callbackParamsFromFlashLoanCalldata(patchedOrigin);

        assertEq(
            vm.parseJsonBytes(fixture, ".fullCloseOriginOriginalCalldata"),
            originalOrigin,
            "unpatched full-close origin calldata"
        );
        assertEq(
            vm.parseJsonBytes(fixture, ".fullCloseOriginPatchedCalldata"),
            patchedOrigin,
            "patched full-close origin calldata"
        );
        assertEq(
            vm.parseJsonBytes(fixture, ".fullCloseCallbackParams"), callbackParams, "complete CallbackEnvelope params"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".fullClosePatchedOriginHash"),
            keccak256(patchedOrigin),
            "actual patched origin hash"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".fullCloseOriginAmountOffset"),
            FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET,
            "flash principal offset"
        );
        assertEq(_wordAt(originalOrigin, FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET), 0, "original flash principal");
        assertEq(
            _wordAt(patchedOrigin, FLASH_LOAN_AMOUNT_ARGUMENT_OFFSET), FULL_CLOSE_OBSERVED_DEBT, "patched visible debt"
        );
    }

    function test_GoldenEveryLifecyclePatchedWordMatchesStructuredAbiEncoding() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        IDefiSimplify7702Account.DynamicCall[] memory leverageCalls = _leverageCalls();
        IDefiSimplify7702Account.CallbackEnvelope memory leverageEnvelope =
            _callbackEnvelopeFromFlashLoanCalldata(leverageCalls[3].data);
        _assertPatchFixture(
            fixture, "leverageAaveApproval", leverageEnvelope.callbackCalls[2], LEVERAGE_OBSERVED_CBETH_OUTPUT
        );
        _assertPatchFixture(
            fixture, "leverageAaveSupply", leverageEnvelope.callbackCalls[3], LEVERAGE_OBSERVED_CBETH_OUTPUT
        );

        IDefiSimplify7702Account.DynamicCall[] memory partialCalls = _partialCalls();
        IDefiSimplify7702Account.CallbackEnvelope memory partialEnvelope =
            _callbackEnvelopeFromFlashLoanCalldata(partialCalls[1].data);
        _assertPatchFixture(
            fixture, "partialRouterApproval", partialEnvelope.callbackCalls[3], PARTIAL_CBETH_WITHDRAWAL
        );
        _assertPatchFixture(fixture, "partialOuterAaveApproval", partialCalls[2], PARTIAL_OBSERVED_CBETH_REMAINDER);
        _assertPatchFixture(fixture, "partialOuterAaveSupply", partialCalls[3], PARTIAL_OBSERVED_CBETH_REMAINDER);

        IDefiSimplify7702Account.DynamicCall[] memory fullCloseCalls = _fullCloseCalls();
        IDefiSimplify7702Account.CallbackEnvelope memory fullCloseEnvelope =
            _callbackEnvelopeFromFlashLoanCalldata(fullCloseCalls[0].data);
        _assertPatchFixture(fixture, "fullCloseOrigin", fullCloseCalls[0], FULL_CLOSE_OBSERVED_DEBT);
        _assertPatchFixture(
            fixture, "fullCloseRepayApproval", fullCloseEnvelope.callbackCalls[0], FULL_CLOSE_OBSERVED_DEBT
        );
        _assertPatchFixture(
            fixture, "fullCloseRouterApproval", fullCloseEnvelope.callbackCalls[3], FULL_CLOSE_WITHDRAWN_CBETH
        );
    }

    function test_GoldenPinnedIdentitiesEconomicsAndCheckpointNamesAreExplicit() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        assertEq(vm.parseJsonUint(fixture, ".version"), 1, "fixture version");
        assertEq(vm.parseJsonUint(fixture, ".chainId"), BASE_CHAIN_ID, "Base chain ID");
        assertEq(vm.parseJsonUint(fixture, ".forkBlock"), BASE_FORK_BLOCK, "pinned Base block");
        assertEq(vm.parseJsonAddress(fixture, ".delegatedEoa"), FIXTURE_DELEGATED_EOA, "fixture EOA");
        assertEq(vm.parseJsonAddress(fixture, ".aavePool"), AAVE_V3_POOL, "Aave Pool");
        assertEq(
            vm.parseJsonBytes32(fixture, ".aavePoolRuntimeCodeHash"),
            AAVE_V3_POOL_RUNTIME_CODE_HASH,
            "Aave Pool runtime identity"
        );
        assertEq(vm.parseJsonAddress(fixture, ".weth"), BASE_WETH, "Base WETH");
        assertEq(
            vm.parseJsonBytes32(fixture, ".wethRuntimeCodeHash"),
            BASE_WETH_RUNTIME_CODE_HASH,
            "Base WETH runtime identity"
        );
        assertEq(vm.parseJsonAddress(fixture, ".cbEth"), BASE_CBETH, "Base cbETH");
        assertEq(
            vm.parseJsonBytes32(fixture, ".cbEthRuntimeCodeHash"),
            BASE_CBETH_RUNTIME_CODE_HASH,
            "Base cbETH runtime identity"
        );
        assertEq(vm.parseJsonAddress(fixture, ".aaveCbEth"), BASE_AAVE_CBETH, "Aave cbETH aToken");
        assertEq(
            vm.parseJsonBytes32(fixture, ".aaveReserveTokenRuntimeCodeHash"),
            BASE_AAVE_RESERVE_TOKEN_RUNTIME_CODE_HASH,
            "Aave reserve-token runtime identity"
        );
        assertEq(
            vm.parseJsonAddress(fixture, ".variableDebtWeth"), BASE_AAVE_VARIABLE_DEBT_WETH, "Aave WETH debt token"
        );
        assertEq(vm.parseJsonAddress(fixture, ".swapRouter02"), BASE_UNISWAP_V3_SWAP_ROUTER_02, "SwapRouter02");
        assertEq(vm.parseJsonAddress(fixture, ".cbEthWethPool"), BASE_UNISWAP_V3_CBETH_WETH_500_POOL, "cbETH/WETH pool");
        assertEq(vm.parseJsonUint(fixture, ".poolFee"), CBETH_WETH_POOL_FEE, "pool fee");
        assertEq(vm.parseJsonUint(fixture, ".premiumBps"), AAVE_FLASH_LOAN_PREMIUM_BPS, "Aave premium bps");
        assertEq(
            vm.parseJsonUint(fixture, ".leverageObservedCbEthOutput"), LEVERAGE_OBSERVED_CBETH_OUTPUT, "leverage quote"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".partialObservedCbEthInput"),
            PARTIAL_OBSERVED_CBETH_INPUT,
            "partial-deleverage quote"
        );
        assertEq(
            vm.parseJsonUint(fixture, ".fullCloseObservedCbEthInput"),
            FULL_CLOSE_OBSERVED_CBETH_INPUT,
            "full-close quote"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".leverageSwapOutputCheckpointId"),
            LEVERAGE_SWAP_OUTPUT_CHECKPOINT_ID,
            "leverage checkpoint"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".partialOuterRemainderCheckpointId"),
            PARTIAL_OUTER_REMAINDER_CHECKPOINT_ID,
            "outer retained checkpoint"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".partialCallbackWithdrawalCheckpointId"),
            PARTIAL_CALLBACK_WITHDRAWAL_CHECKPOINT_ID,
            "callback withdrawal checkpoint"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".fullCloseWithdrawalCheckpointId"),
            FULL_CLOSE_WITHDRAWAL_CHECKPOINT_ID,
            "full-close checkpoint"
        );
        assertFalse(
            vm.parseJsonBool(fixture, ".directSwapHasDeadline"), "Base direct SwapRouter02 calls have no deadline"
        );
    }

    function _leverageCalls() private pure returns (IDefiSimplify7702Account.DynamicCall[] memory) {
        uint256 premium = _aaveFlashPremium(LEVERAGE_FLASH_WETH);
        return _buildFlashAssistedLeverageOpen(
            FIXTURE_DELEGATED_EOA,
            FIXTURE_FLOW_ASSERTIONS,
            premium,
            LEVERAGE_MINIMUM_CBETH_OUTPUT,
            MINIMUM_LEVERAGED_HEALTH_FACTOR,
            LEVERAGE_FLASH_WETH + premium
        );
    }

    function _partialCalls() private pure returns (IDefiSimplify7702Account.DynamicCall[] memory) {
        return _buildFlashAssistedPartialDeleverage(
            FIXTURE_DELEGATED_EOA,
            FIXTURE_FLOW_ASSERTIONS,
            _aaveFlashPremium(PARTIAL_FLASH_WETH),
            PARTIAL_MAXIMUM_CBETH_INPUT,
            MINIMUM_PARTIAL_DELEVERAGE_HEALTH_FACTOR
        );
    }

    function _fullCloseCalls() private pure returns (IDefiSimplify7702Account.DynamicCall[] memory) {
        return _buildFlashAssistedFullClose(
            FIXTURE_DELEGATED_EOA,
            FIXTURE_FLOW_ASSERTIONS,
            FIXTURE_STATIC_ASSERTIONS,
            FULL_CLOSE_OBSERVED_DEBT,
            _aaveFlashPremium(FULL_CLOSE_OBSERVED_DEBT),
            FULL_CLOSE_MAXIMUM_CBETH_INPUT
        );
    }

    function _leverageEnvelope() private pure returns (IDefiSimplify7702Account.CallbackEnvelope memory) {
        return _callbackEnvelopeFromFlashLoanCalldata(_leverageCalls()[3].data);
    }

    function _partialEnvelope() private pure returns (IDefiSimplify7702Account.CallbackEnvelope memory) {
        return _callbackEnvelopeFromFlashLoanCalldata(_partialCalls()[1].data);
    }

    function _fullCloseEnvelope() private pure returns (IDefiSimplify7702Account.CallbackEnvelope memory) {
        return _callbackEnvelopeFromFlashLoanCalldata(_fullCloseCalls()[0].data);
    }

    function _assertPatchFixture(
        string memory fixture,
        string memory name,
        IDefiSimplify7702Account.DynamicCall memory dynamicCall,
        uint256 resolvedAmount
    ) private pure {
        assertEq(dynamicCall.patches.length, 1, string.concat(name, " patch count"));
        uint256 offset = dynamicCall.patches[0].offset;
        bytes memory patchedData = _copyAndReplaceWord(dynamicCall.data, offset, resolvedAmount);

        assertEq(vm.parseJsonUint(fixture, string.concat(".", name, "Offset")), offset, string.concat(name, " offset"));
        assertEq(
            vm.parseJsonUint(fixture, string.concat(".", name, "Value")), resolvedAmount, string.concat(name, " value")
        );
        assertEq(
            vm.parseJsonBytes(fixture, string.concat(".", name, "OriginalCalldata")),
            dynamicCall.data,
            string.concat(name, " original calldata")
        );
        assertEq(
            vm.parseJsonBytes(fixture, string.concat(".", name, "PatchedCalldata")),
            patchedData,
            string.concat(name, " patched calldata")
        );
        assertEq(_wordAt(dynamicCall.data, offset), 0, string.concat(name, " original word"));
        assertEq(_wordAt(patchedData, offset), resolvedAmount, string.concat(name, " patched word"));
        assertEq(
            _hashOutsidePatchedWord(dynamicCall.data, offset),
            _hashOutsidePatchedWord(patchedData, offset),
            string.concat(name, " changes only one word")
        );
    }

    function _callbackEnvelopeFromFlashLoanCalldata(bytes memory flashLoanCalldata)
        private
        pure
        returns (IDefiSimplify7702Account.CallbackEnvelope memory envelope)
    {
        return abi.decode(
            _callbackParamsFromFlashLoanCalldata(flashLoanCalldata), (IDefiSimplify7702Account.CallbackEnvelope)
        );
    }

    function _callbackParamsFromFlashLoanCalldata(bytes memory flashLoanCalldata)
        private
        pure
        returns (bytes memory params)
    {
        uint256 paramsOffsetFromArguments = _wordAt(flashLoanCalldata, 100);
        uint256 paramsLengthOffset = 4 + paramsOffsetFromArguments;
        uint256 paramsLength = _wordAt(flashLoanCalldata, paramsLengthOffset);
        return _slice(flashLoanCalldata, paramsLengthOffset + 32, paramsLength);
    }

    function _copyAndReplaceWord(bytes memory original, uint256 offset, uint256 value)
        private
        pure
        returns (bytes memory patched)
    {
        patched = _slice(original, 0, original.length);
        assembly ("memory-safe") {
            mstore(add(add(patched, 32), offset), value)
        }
    }

    function _wordAt(bytes memory data, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }

    function _hashOutsidePatchedWord(bytes memory data, uint256 offset) private pure returns (bytes32) {
        bytes memory withoutPatchedWord =
            bytes.concat(_slice(data, 0, offset), _slice(data, offset + 32, data.length - offset - 32));
        return keccak256(withoutPatchedWord);
    }

    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            result[i] = data[start + i];
        }
    }
}
