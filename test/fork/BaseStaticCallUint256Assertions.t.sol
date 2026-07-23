// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {StaticCallUint256Assertions} from "../../src/StaticCallUint256Assertions.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IStaticCallUint256Assertions} from "../../src/interfaces/IStaticCallUint256Assertions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract BaseStaticCallUint256AssertionsForkTest is DelegatedAccountFixture {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_FORK_BLOCK = 48_961_870;
    uint256 private constant BASE_GENERIC_UPSTREAM_AUTHORITY_KEY =
        0x0f9be418f26495095633001cdf2f537edb74bb7c7634a681558521f0b85b8c46;
    uint256 private constant BASE_GENERIC_CUSTOM_AUTHORITY_KEY =
        0x103e3a64ac46b56b6678ff2c49b6a4ed949015751f64a0cbc43f28dd628bef18;
    uint32 private constant GLOBAL_READ = type(uint32).max;
    uint32 private constant AAVE_ACCOUNT_OFFSET = 4;
    uint32 private constant AAVE_HEALTH_FACTOR_RETURN_OFFSET = 5 * 32;
    address private constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address private constant PLACEHOLDER_ACCOUNT = 0x1111111111111111111111111111111111111111;

    DelegatedPair private pair;
    StaticCallUint256Assertions private assertions;

    function setUp() external {
        require(block.chainid == BASE_CHAIN_ID, "fork is not Base mainnet");
        vm.rollFork(BASE_FORK_BLOCK);
        require(AAVE_V3_POOL.code.length != 0, "Aave V3 Pool has no code");
        require(BASE_WETH.code.length != 0, "Base WETH has no code");
        pair = _deployDelegatedPair(
            IEntryPoint(address(this)), BASE_GENERIC_UPSTREAM_AUTHORITY_KEY, BASE_GENERIC_CUSTOM_AUTHORITY_KEY
        );
        assertions = new StaticCallUint256Assertions();
    }

    function test_IndependentCheckerBindsDelegatedAccountForBaseAaveAndSupportsGlobalBaseRead() external {
        (,,,,, uint256 healthFactor) = IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(pair.customAccount);
        assertEq(healthFactor, type(uint256).max, "unexpected no-position health factor");

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({target: address(assertions), value: 0, data: _aaveAssertionData()});
        calls[1] = BaseAccount.Call({target: address(assertions), value: 0, data: _globalWethAssertionData()});

        vm.prank(pair.customAccount, pair.customAccount);
        DefiSimplify7702Account(pair.customAccount).executeBatch(calls);
    }

    function test_IndependentCheckerWorksAsFinalDynamicStepAgainstBaseAave() external {
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0].target = address(assertions);
        calls[0].data = _aaveAssertionData();
        calls[0].checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        calls[0].patches = new IDefiSimplify7702Account.BalancePatch[](0);

        vm.prank(pair.customAccount, pair.customAccount);
        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);
    }

    function _aaveAssertionData() private pure returns (bytes memory) {
        bytes memory poolData = abi.encodeCall(IAaveV3Pool.getUserAccountData, (PLACEHOLDER_ACCOUNT));
        return abi.encodeCall(
            IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
            (AAVE_V3_POOL, poolData, AAVE_ACCOUNT_OFFSET, AAVE_HEALTH_FACTOR_RETURN_OFFSET, type(uint256).max)
        );
    }

    function _globalWethAssertionData() private pure returns (bytes memory) {
        bytes memory wethData = abi.encodeCall(IERC20.totalSupply, ());
        return abi.encodeCall(
            IStaticCallUint256Assertions.assertStaticCallUint256AtLeast,
            (BASE_WETH, wethData, GLOBAL_READ, uint32(0), uint256(1))
        );
    }
}
