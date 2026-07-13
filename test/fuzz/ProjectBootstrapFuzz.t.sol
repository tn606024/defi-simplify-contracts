// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract ProjectBootstrapFuzzTest {
    function testFuzz_Uint128AdditionDoesNotOverflow(uint128 lhs, uint128 rhs) external pure {
        uint256 sum = uint256(lhs) + uint256(rhs);
        require(sum >= lhs && sum >= rhs, "unexpected addition result");
    }
}
