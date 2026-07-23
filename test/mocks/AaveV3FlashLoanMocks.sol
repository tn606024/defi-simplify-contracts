// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";

contract FlashLoanAssetMock {
    error BalanceReadReverted();
    error AllowanceReadReverted();
    error ApprovalReverted(uint256 amount);
    error ZeroFirstApprovalRequired(uint256 currentAllowance, uint256 requestedAllowance);
    error InsufficientBalance(address account, uint256 actual, uint256 required);
    error InsufficientAllowance(address owner, address spender, uint256 actual, uint256 required);

    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 allowanceAmount)) private _allowances;

    bool public requireZeroFirstApproval;
    bool public returnFalseFromApproval;
    bool public revertApproval;
    bool public returnShortApprovalData;
    bool public returnEmptyApprovalData;
    bool public revertBalanceRead;
    bool public returnShortBalanceData;
    bool public revertAllowanceRead;
    bool public returnShortAllowanceData;
    bool public returnFalseFromTransferFrom;

    uint256[] private _approvalAmounts;

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function setAllowance(address owner, address spender, uint256 amount) external {
        _allowances[owner][spender] = amount;
    }

    function setRequireZeroFirstApproval(bool enabled) external {
        requireZeroFirstApproval = enabled;
    }

    function setApprovalBehavior(bool returnsFalse, bool reverts, bool returnsShortData) external {
        returnFalseFromApproval = returnsFalse;
        revertApproval = reverts;
        returnShortApprovalData = returnsShortData;
    }

    function setReturnEmptyApprovalData(bool enabled) external {
        returnEmptyApprovalData = enabled;
    }

    function setBalanceReadBehavior(bool reverts, bool returnsShortData) external {
        revertBalanceRead = reverts;
        returnShortBalanceData = returnsShortData;
    }

    function setAllowanceReadBehavior(bool reverts, bool returnsShortData) external {
        revertAllowanceRead = reverts;
        returnShortAllowanceData = returnsShortData;
    }

    function setTransferFromReturnsFalse(bool enabled) external {
        returnFalseFromTransferFrom = enabled;
    }

    function approvalCount() external view returns (uint256) {
        return _approvalAmounts.length;
    }

    function approvalAmount(uint256 approvalIndex) external view returns (uint256) {
        return _approvalAmounts[approvalIndex];
    }

    function balanceOf(address account) external view returns (uint256 tokenBalance) {
        if (revertBalanceRead) {
            revert BalanceReadReverted();
        }
        tokenBalance = _balances[account];
        if (returnShortBalanceData) {
            assembly ("memory-safe") {
                mstore(0, 0x1234)
                return(30, 2)
            }
        }
    }

    function allowance(address owner, address spender) external view returns (uint256 allowanceAmount) {
        if (revertAllowanceRead) {
            revert AllowanceReadReverted();
        }
        allowanceAmount = _allowances[owner][spender];
        if (returnShortAllowanceData) {
            assembly ("memory-safe") {
                mstore(0, 0x1234)
                return(30, 2)
            }
        }
    }

    function approve(address spender, uint256 amount) external returns (bool approved) {
        if (revertApproval) {
            revert ApprovalReverted(amount);
        }

        uint256 currentAllowance = _allowances[msg.sender][spender];
        if (requireZeroFirstApproval && currentAllowance != 0 && amount != 0) {
            revert ZeroFirstApprovalRequired(currentAllowance, amount);
        }

        _allowances[msg.sender][spender] = amount;
        _approvalAmounts.push(amount);

        if (returnShortApprovalData) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (returnEmptyApprovalData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return !returnFalseFromApproval;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        if (returnFalseFromTransferFrom) {
            return false;
        }

        uint256 currentAllowance = _allowances[owner][msg.sender];
        if (currentAllowance < amount) {
            revert InsufficientAllowance(owner, msg.sender, currentAllowance, amount);
        }
        _allowances[owner][msg.sender] = currentAllowance - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        uint256 senderBalance = _balances[sender];
        if (senderBalance < amount) {
            revert InsufficientBalance(sender, senderBalance, amount);
        }
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;
    }
}

contract FlashLoanCallbackForwarder {
    function forward(
        address receiver,
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        return IDefiSimplify7702Account(receiver).executeOperation(asset, amount, premium, initiator, params);
    }
}

contract AaveV3FlashLoanPoolMock is IAaveV3FlashLoanSimplePool {
    error CallbackReturnedFalse();
    error RepaymentPullReturnedFalse();

    enum CallbackMutation {
        None,
        WrongSender,
        WrongInitiator,
        WrongAsset,
        WrongAmount,
        WrongParams
    }

    FlashLoanCallbackForwarder private immutable _callbackForwarder;

    uint256 public premium;
    CallbackMutation public callbackMutation;
    bool public skipCallback;
    bool public replayCallback;
    bool public pullRepayment = true;
    bool public useCustomPullAmount;
    uint256 public customPullAmount;
    bool public useForcedCallbackReceiver;
    address public forcedCallbackReceiver;
    uint256 public callbackCount;
    bytes32 public lastReceivedCalldataHash;

    constructor() {
        _callbackForwarder = new FlashLoanCallbackForwarder();
    }

    function callbackForwarder() external view returns (address) {
        return address(_callbackForwarder);
    }

    function setPremium(uint256 newPremium) external {
        premium = newPremium;
    }

    function setCallbackMutation(CallbackMutation mutation) external {
        callbackMutation = mutation;
    }

    function setSkipCallback(bool enabled) external {
        skipCallback = enabled;
    }

    function setReplayCallback(bool enabled) external {
        replayCallback = enabled;
    }

    function setPullRepayment(bool enabled) external {
        pullRepayment = enabled;
    }

    function setCustomPullAmount(uint256 amount) external {
        useCustomPullAmount = true;
        customPullAmount = amount;
    }

    function setForcedCallbackReceiver(address receiver) external {
        useForcedCallbackReceiver = true;
        forcedCallbackReceiver = receiver;
    }

    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
        override
    {
        lastReceivedCalldataHash = keccak256(msg.data);
        _runFlashLoan(receiverAddress, asset, amount, params);
    }

    function flashLoanFromDifferentSelector(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params
    ) external {
        lastReceivedCalldataHash = keccak256(msg.data);
        _runFlashLoan(receiverAddress, asset, amount, params);
    }

    function _runFlashLoan(address receiverAddress, address asset, uint256 amount, bytes calldata params) private {
        address callbackReceiver = useForcedCallbackReceiver ? forcedCallbackReceiver : receiverAddress;
        require(FlashLoanAssetMock(asset).transfer(callbackReceiver, amount), "principal transfer failed");

        if (!skipCallback) {
            _invokeCallback(callbackReceiver, asset, amount, params);
            if (replayCallback) {
                _invokeCallback(callbackReceiver, asset, amount, params);
            }
        }

        if (pullRepayment) {
            uint256 repaymentAmount = useCustomPullAmount ? customPullAmount : amount + premium;
            if (!FlashLoanAssetMock(asset).transferFrom(callbackReceiver, address(this), repaymentAmount)) {
                revert RepaymentPullReturnedFalse();
            }
        }
    }

    function _invokeCallback(address receiverAddress, address asset, uint256 amount, bytes calldata params) private {
        address callbackAsset = asset;
        uint256 callbackAmount = amount;
        address callbackInitiator = msg.sender;
        bytes memory callbackParams = params;

        if (callbackMutation == CallbackMutation.WrongAsset) {
            callbackAsset = address(0xA55E7);
        } else if (callbackMutation == CallbackMutation.WrongAmount) {
            callbackAmount = amount + 1;
        } else if (callbackMutation == CallbackMutation.WrongInitiator) {
            callbackInitiator = address(0xBAD);
        } else if (callbackMutation == CallbackMutation.WrongParams) {
            callbackParams = bytes.concat(params, hex"00");
        }

        bool callbackAccepted;
        if (callbackMutation == CallbackMutation.WrongSender) {
            callbackAccepted = _callbackForwarder.forward(
                receiverAddress, callbackAsset, callbackAmount, premium, callbackInitiator, callbackParams
            );
        } else {
            callbackAccepted = IDefiSimplify7702Account(receiverAddress)
                .executeOperation(callbackAsset, callbackAmount, premium, callbackInitiator, callbackParams);
        }

        if (!callbackAccepted) {
            revert CallbackReturnedFalse();
        }
        callbackCount += 1;
    }
}
