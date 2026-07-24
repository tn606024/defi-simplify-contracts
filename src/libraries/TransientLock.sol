// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

library TransientLock {
    // keccak256("DefiSimplify7702Account.transientLock");
    bytes32 internal constant TRANSIENT_LOCK_SLOT = 0x7ca16c0d92222ed0262547ed795c42bf2637dec2cb915372872abc97e34d6db2;

    function unlock() internal {
        assembly ("memory-safe") {
            tstore(TRANSIENT_LOCK_SLOT, false)
        }
    }

    function lock() internal {
        assembly ("memory-safe") {
            tstore(TRANSIENT_LOCK_SLOT, true)
        }
    }

    function isLocked() internal view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(TRANSIENT_LOCK_SLOT)
        }
    }
}
