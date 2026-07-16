// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Exec} from "@account-abstraction/contracts/utils/Exec.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IDefiSimplify7702Account} from "./interfaces/IDefiSimplify7702Account.sol";

/// @title DefiSimplify7702Account
/// @notice EIP-7702 delegated account with inherited static execution and dynamic batch execution.
/// @dev This implementation is deployed directly and used as an EIP-7702 delegation target.
///      During delegated execution, `address(this)` is the delegated EOA, not this implementation's
///      deployment address. The immutable EntryPoint and all account behavior are inherited from
///      the pinned upstream Simple7702Account v0.9.0 implementation.
contract DefiSimplify7702Account is Simple7702Account, IDefiSimplify7702Account {
    using TransientSlot for *;

    bytes32 private constant _DYNAMIC_EXECUTION_LOCK_SLOT =
        keccak256("DefiSimplify7702Account.dynamicExecutionLock.v1");

    constructor(IEntryPoint anEntryPoint) Simple7702Account(anEntryPoint) {}

    /// @inheritdoc IDefiSimplify7702Account
    function executeBatchDynamic(DynamicCall[] calldata calls) external payable override {
        _requireForExecute();

        TransientSlot.BooleanSlot lockSlot = _DYNAMIC_EXECUTION_LOCK_SLOT.asBoolean();
        if (lockSlot.tload()) {
            revert DynamicExecutionReentered();
        }
        lockSlot.tstore(true);

        uint256 callsLength = calls.length;
        if (callsLength == 0) {
            revert EmptyDynamicBatch();
        }

        for (uint256 i = 0; i < callsLength; ++i) {
            DynamicCall calldata dynamicCall = calls[i];
            address target = dynamicCall.target;
            if (target == address(0) || target == address(this)) {
                revert InvalidTarget(i, target);
            }

            // IAN-48 and IAN-49 fill in checkpoint creation and calldata patching
            // between target validation and this CALL without changing the frozen ABI.
            bytes memory data = dynamicCall.data;
            bool success = Exec.call(target, dynamicCall.value, data, gasleft());
            if (!success) {
                revert DynamicCallFailed(i, target, Exec.getReturnData(0));
            }
        }

        lockSlot.tstore(false);
    }

    /// @inheritdoc Simple7702Account
    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return id == type(IDefiSimplify7702Account).interfaceId || super.supportsInterface(id);
    }
}
