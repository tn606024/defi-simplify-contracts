// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IGoldenBaseSwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IGoldenBaseAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @dev Proves every DSC-57 strategy patch offset against language-neutral ABI calldata.
contract BaseAaveV3DynamicStrategyGoldenVectorsTest is Test {
    string private constant FIXTURE_PATH = "abi/BaseAaveV3DynamicStrategy.golden.json";

    address private constant FIXTURE_DELEGATED_EOA = 0x1111111111111111111111111111111111111111;
    address private constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    bytes32 private constant BASE_SWAP_ROUTER_02_RUNTIME_CODE_HASH =
        0x38bd640f47df62b2fd5a6755a63f4976ad847dc9b946ae0d145d21d16bb124e4;
    address private constant BASE_USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    bytes32 private constant BASE_USDC_WETH_POOL_RUNTIME_CODE_HASH =
        0xcd06f61c6db6a1d8317548aaaa0aa83254624aec741534c51815810e977587ae;

    uint256 private constant BORROWED_USDC_DELTA = 500e6;
    uint256 private constant OBSERVED_WETH_DELTA = 260_391_696_019_929_066;
    uint256 private constant MINIMUM_WETH_OUTPUT = 0.26 ether;
    uint160 private constant SQRT_PRICE_LIMIT_X96 = 3_600_000_000_000_000_000_000_000;
    uint24 private constant POOL_FEE = 500;

    function test_GoldenEveryStrategyPatchedWordMatchesStructuredAbiEncoding() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        _assertCallFixture(
            fixture,
            ".calls.routerApproval",
            abi.encodeCall(IERC20.approve, (BASE_SWAP_ROUTER_02, 0)),
            abi.encodeCall(IERC20.approve, (BASE_SWAP_ROUTER_02, BORROWED_USDC_DELTA)),
            ".offsets.routerApprovalAmount",
            BORROWED_USDC_DELTA
        );

        IGoldenBaseSwapRouter02.ExactInputSingleParams memory originalSwapParams = _swapParams(0);
        IGoldenBaseSwapRouter02.ExactInputSingleParams memory patchedSwapParams = _swapParams(BORROWED_USDC_DELTA);
        _assertCallFixture(
            fixture,
            ".calls.swap",
            abi.encodeCall(IGoldenBaseSwapRouter02.exactInputSingle, (originalSwapParams)),
            abi.encodeCall(IGoldenBaseSwapRouter02.exactInputSingle, (patchedSwapParams)),
            ".offsets.swapAmountIn",
            BORROWED_USDC_DELTA
        );

        _assertCallFixture(
            fixture,
            ".calls.aaveApproval",
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, 0)),
            abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, OBSERVED_WETH_DELTA)),
            ".offsets.aaveApprovalAmount",
            OBSERVED_WETH_DELTA
        );
        _assertCallFixture(
            fixture,
            ".calls.aaveSupply",
            abi.encodeCall(IGoldenBaseAaveV3Pool.supply, (BASE_WETH, 0, FIXTURE_DELEGATED_EOA, 0)),
            abi.encodeCall(IGoldenBaseAaveV3Pool.supply, (BASE_WETH, OBSERVED_WETH_DELTA, FIXTURE_DELEGATED_EOA, 0)),
            ".offsets.aaveSupplyAmount",
            OBSERVED_WETH_DELTA
        );
    }

    function test_GoldenStrategyIdentitiesCheckpointsAndTemporalLimitationAreExplicit() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        assertEq(vm.parseJsonUint(fixture, ".version"), 1, "fixture version");
        assertEq(vm.parseJsonUint(fixture, ".chainId"), 8453, "Base chain ID");
        assertEq(vm.parseJsonUint(fixture, ".forkBlock"), 48_961_870, "pinned Base block");
        assertEq(vm.parseJsonAddress(fixture, ".delegatedEoa"), FIXTURE_DELEGATED_EOA, "fixture EOA");
        assertEq(vm.parseJsonAddress(fixture, ".aavePool"), AAVE_V3_POOL, "Aave Pool");
        assertEq(vm.parseJsonAddress(fixture, ".weth"), BASE_WETH, "Base WETH");
        assertEq(vm.parseJsonAddress(fixture, ".usdc"), BASE_USDC, "Base USDC");
        assertEq(vm.parseJsonAddress(fixture, ".swapRouter02"), BASE_SWAP_ROUTER_02, "SwapRouter02");
        assertEq(
            vm.parseJsonBytes32(fixture, ".swapRouter02RuntimeCodeHash"),
            BASE_SWAP_ROUTER_02_RUNTIME_CODE_HASH,
            "SwapRouter02 runtime identity"
        );
        assertEq(vm.parseJsonAddress(fixture, ".usdcWethPool"), BASE_USDC_WETH_POOL, "USDC/WETH pool");
        assertEq(
            vm.parseJsonBytes32(fixture, ".usdcWethPoolRuntimeCodeHash"),
            BASE_USDC_WETH_POOL_RUNTIME_CODE_HASH,
            "USDC/WETH pool runtime identity"
        );
        assertEq(vm.parseJsonUint(fixture, ".poolFee"), POOL_FEE, "Uniswap pool fee");
        assertEq(
            vm.parseJsonBytes32(fixture, ".borrowCheckpointId"),
            keccak256("dsc-57.borrowed-usdc"),
            "borrow checkpoint ID"
        );
        assertEq(
            vm.parseJsonBytes32(fixture, ".swapOutputCheckpointId"),
            keccak256("dsc-57.swapped-weth"),
            "swap-output checkpoint ID"
        );
        assertEq(vm.parseJsonUint(fixture, ".borrowedUsdcDelta"), BORROWED_USDC_DELTA, "borrowed USDC delta");
        assertEq(vm.parseJsonUint(fixture, ".observedWethDelta"), OBSERVED_WETH_DELTA, "observed WETH delta");
        assertEq(vm.parseJsonUint(fixture, ".minimumWethOutput"), MINIMUM_WETH_OUTPUT, "minimum WETH output");
        assertEq(vm.parseJsonUint(fixture, ".sqrtPriceLimitX96"), SQRT_PRICE_LIMIT_X96, "sqrt price limit");
        assertFalse(
            vm.parseJsonBool(fixture, ".limitations.directSwapHasDeadline"),
            "Base direct SwapRouter02 call has no deadline"
        );
    }

    function test_GoldenMalformedRouterApprovalOffsetMatchesIndexedAccountError() external view {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        uint256 callIndex = vm.parseJsonUint(fixture, ".malformed.routerApprovalUnalignedOffset.callIndex");
        uint256 patchIndex = vm.parseJsonUint(fixture, ".malformed.routerApprovalUnalignedOffset.patchIndex");
        uint256 offset = vm.parseJsonUint(fixture, ".malformed.routerApprovalUnalignedOffset.offset");
        uint256 dataLength = vm.parseJsonUint(fixture, ".malformed.routerApprovalUnalignedOffset.dataLength");

        assertEq(callIndex, 3, "Router approval call index");
        assertEq(patchIndex, 0, "Router approval patch index");
        assertEq(offset, 37, "unaligned Router approval amount offset");
        assertEq(dataLength, 68, "Router approval calldata length");
        assertEq(
            vm.parseJsonBytes(fixture, ".malformed.routerApprovalUnalignedOffset.encodedError"),
            abi.encodeWithSelector(
                IDefiSimplify7702Account.InvalidPatchOffset.selector, callIndex, patchIndex, offset, dataLength
            ),
            "malformed offset indexed error"
        );
    }

    function _swapParams(uint256 amountIn)
        private
        pure
        returns (IGoldenBaseSwapRouter02.ExactInputSingleParams memory params)
    {
        params = IGoldenBaseSwapRouter02.ExactInputSingleParams({
            tokenIn: BASE_USDC,
            tokenOut: BASE_WETH,
            fee: POOL_FEE,
            recipient: FIXTURE_DELEGATED_EOA,
            amountIn: amountIn,
            amountOutMinimum: MINIMUM_WETH_OUTPUT,
            sqrtPriceLimitX96: SQRT_PRICE_LIMIT_X96
        });
    }

    function _assertCallFixture(
        string memory fixture,
        string memory callPath,
        bytes memory expectedOriginal,
        bytes memory expectedPatched,
        string memory offsetPath,
        uint256 patchedAmount
    ) private pure {
        bytes memory fixtureOriginal = vm.parseJsonBytes(fixture, string.concat(callPath, ".originalCalldata"));
        bytes memory fixturePatched = vm.parseJsonBytes(fixture, string.concat(callPath, ".patchedCalldata"));
        bytes memory fixtureSelector = vm.parseJsonBytes(fixture, string.concat(callPath, ".selector"));
        uint256 patchOffset = vm.parseJsonUint(fixture, offsetPath);

        assertEq(fixtureOriginal, expectedOriginal, string.concat(callPath, " original calldata"));
        assertEq(fixturePatched, expectedPatched, string.concat(callPath, " patched calldata"));
        assertEq(fixtureSelector, _slice(expectedOriginal, 0, 4), string.concat(callPath, " selector"));
        assertEq(_wordAt(fixtureOriginal, patchOffset), 0, string.concat(callPath, " original amount word"));
        assertEq(_wordAt(fixturePatched, patchOffset), patchedAmount, string.concat(callPath, " patched amount word"));
        assertEq(
            _hashOutsidePatchedWord(fixtureOriginal, patchOffset),
            _hashOutsidePatchedWord(fixturePatched, patchOffset),
            string.concat(callPath, " changes only selected word")
        );
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
