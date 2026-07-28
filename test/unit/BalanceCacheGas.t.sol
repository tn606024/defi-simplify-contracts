// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";
import {DynamicCallTestBuilder} from "../utils/DynamicCallTestBuilder.sol";

contract BalanceCacheNoopTarget {
    fallback() external {}
}

/// @dev Characterizes the per-call linear balance cache with distinct tokens.
///      Each patch inserts one token and each checkpoint reuses that token before
///      the target call, so only one external balance read occurs per token.
contract BalanceCacheGasTest is DelegatedAccountFixture {
    uint256 private constant MAX_DISTINCT_TOKEN_COUNT = 32;

    DelegatedDefiSimplifyAccount private accountUnderTest;
    BalanceCacheNoopTarget private noopTarget;
    PatchBalanceToken[32] private distinctBalanceTokens;

    function setUp() external {
        accountUnderTest = _deployDelegatedDefiSimplifyAccount(IEntryPoint(address(this)));
        noopTarget = new BalanceCacheNoopTarget();

        for (uint256 i = 0; i < MAX_DISTINCT_TOKEN_COUNT; ++i) {
            PatchBalanceToken token = new PatchBalanceToken();
            token.setBalance(accountUnderTest.delegatedEoa, i + 1);
            distinctBalanceTokens[i] = token;
        }
    }

    function test_DistinctTokenCacheReadsEachTokenOnceAcrossPatchesAndCheckpoints() external {
        uint256 distinctTokenCount = 4;
        for (uint256 i = 0; i < distinctTokenCount; ++i) {
            PatchBalanceToken token = distinctBalanceTokens[i];
            vm.expectCall(
                address(token), abi.encodeCall(PatchBalanceToken.balanceOf, (accountUnderTest.delegatedEoa)), uint64(1)
            );
        }

        _executeDistinctTokenCacheScenario(distinctTokenCount);
    }

    function test_Gas_BalanceCacheOneDistinctToken() external {
        _executeDistinctTokenCacheScenario(1);
    }

    function test_Gas_BalanceCacheFourDistinctTokens() external {
        _executeDistinctTokenCacheScenario(4);
    }

    function test_Gas_BalanceCacheEightDistinctTokens() external {
        _executeDistinctTokenCacheScenario(8);
    }

    function test_Gas_BalanceCacheSixteenDistinctTokens() external {
        _executeDistinctTokenCacheScenario(16);
    }

    function test_Gas_BalanceCacheThirtyTwoDistinctTokens() external {
        _executeDistinctTokenCacheScenario(32);
    }

    function _executeDistinctTokenCacheScenario(uint256 distinctTokenCount) private {
        IDefiSimplify7702Account.BalancePatch[] memory patches =
            new IDefiSimplify7702Account.BalancePatch[](distinctTokenCount);
        IDefiSimplify7702Account.BalanceCheckpoint[] memory checkpoints =
            new IDefiSimplify7702Account.BalanceCheckpoint[](distinctTokenCount);
        bytes memory patchData = new bytes(4 + distinctTokenCount * 32);
        uint32 patchOffset = 4;

        for (uint256 i = 0; i < distinctTokenCount; ++i) {
            address token = address(distinctBalanceTokens[i]);
            patches[i] = DynamicCallTestBuilder.currentBalancePatch(token, patchOffset, 10_000);
            checkpoints[i] = DynamicCallTestBuilder.checkpoint(token, bytes32(i + 1));
            patchOffset += 32;
        }

        IDefiSimplify7702Account.DynamicCall memory balanceAwareCall =
            DynamicCallTestBuilder.buildZeroValueBalanceAwareCall(address(noopTarget), patchData, checkpoints, patches);
        _dynamicExecutionInterfaceView(accountUnderTest)
            .executeBatchDynamic(DynamicCallTestBuilder.singleCall(balanceAwareCall));
    }
}
