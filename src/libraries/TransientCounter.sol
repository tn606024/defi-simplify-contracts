// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

library TransientCounter {
    // keccak256("DefiSimplify7702Account.transientCounter");
    bytes32 internal constant TRANSIENT_COUNTER_SLOT =
        0x47c74c518e4171e2d281e5b05c7fdac28b07c58b87ae868b7855c37cec8683a0;

    function increment() internal {
        assembly ("memory-safe") {
            let value := tload(TRANSIENT_COUNTER_SLOT)
            value := add(value, 1)
            tstore(TRANSIENT_COUNTER_SLOT, value)
        }
    }

    function counter() internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(TRANSIENT_COUNTER_SLOT)
        }
        return value;
    }
}
