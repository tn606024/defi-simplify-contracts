// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DynamicPatchTarget, PatchBalanceToken} from "../mocks/CheckpointBalanceToken.sol";
import {DynamicExecutionTarget} from "../mocks/DynamicExecutionTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract DynamicCalldataPatchingFuzzTest is DelegatedAccountFixture {
    bytes4 private constant CAPTURE_SELECTOR = bytes4(keccak256("capture(uint256,uint256,uint256)"));

    DelegatedPair private pair;
    PatchBalanceToken private token;
    DynamicExecutionTarget private target;
    DynamicPatchTarget private patchTarget;

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        token = new PatchBalanceToken();
        target = new DynamicExecutionTarget();
        patchTarget = new DynamicPatchTarget();
    }

    function testFuzz_FullPrecisionCurrentBalanceMathMatchesMulDiv(uint256 balance, uint16 rawBps) external {
        uint16 bps = uint16(bound(rawBps, 1, 10_000));
        token.setBalance(pair.customAccount, balance);
        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(
            address(target),
            abi.encodeCall(DynamicExecutionTarget.record, (uint256(0), bytes("muldiv"))),
            _patch(4, bps)
        );

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(target.total(), Math.mulDiv(balance, uint256(bps), 10_000), "full-precision result");
    }

    function testFuzz_PatchChangesExactlyOneSelectedWord(
        bytes32 first,
        bytes32 second,
        bytes32 third,
        uint256 balance,
        uint16 rawBps,
        uint8 rawWordIndex
    ) external {
        uint16 bps = uint16(bound(rawBps, 1, 10_000));
        uint32 offset = 4 + uint32(rawWordIndex % 3) * 32;
        token.setBalance(pair.customAccount, balance);

        bytes memory original = abi.encodeWithSelector(CAPTURE_SELECTOR, first, second, third);
        bytes memory expected = abi.encodeWithSelector(CAPTURE_SELECTOR, first, second, third);
        uint256 amount = Math.mulDiv(balance, uint256(bps), 10_000);
        assembly ("memory-safe") {
            mstore(add(add(expected, 32), offset), amount)
        }

        IDefiSimplify7702Account.DynamicCall[] memory calls = new IDefiSimplify7702Account.DynamicCall[](1);
        calls[0] = _dynamicCall(address(patchTarget), original, _patch(offset, bps));

        IDefiSimplify7702Account(pair.customAccount).executeBatchDynamic(calls);

        assertEq(patchTarget.observedData(), expected, "bytes outside selected word changed");
    }

    function _dynamicCall(
        address callTarget,
        bytes memory data,
        IDefiSimplify7702Account.BalancePatch memory balancePatch
    ) private pure returns (IDefiSimplify7702Account.DynamicCall memory dynamicCall) {
        dynamicCall.target = callTarget;
        dynamicCall.data = data;
        dynamicCall.checkpointsBefore = new IDefiSimplify7702Account.BalanceCheckpoint[](0);
        dynamicCall.patches = new IDefiSimplify7702Account.BalancePatch[](1);
        dynamicCall.patches[0] = balancePatch;
    }

    function _patch(uint32 offset, uint16 bps) private view returns (IDefiSimplify7702Account.BalancePatch memory) {
        return IDefiSimplify7702Account.BalancePatch({
            token: address(token),
            checkpointId: bytes32(0),
            offset: offset,
            bps: bps,
            source: IDefiSimplify7702Account.BalanceSource.CurrentBalance
        });
    }
}
