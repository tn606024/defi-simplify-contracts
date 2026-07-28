// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3FlashLoanSimplePool} from "../../src/interfaces/IAaveV3FlashLoanSimplePool.sol";
import {IDefiSimplify7702Account} from "../../src/interfaces/IDefiSimplify7702Account.sol";

/// @dev ERC-20-shaped flash-loan asset with independently configurable faults.
///
/// The read toggles exercise reverted and short `balanceOf`/`allowance` data.
/// Approval toggles cover revert, false, empty, short, zero-first, and approval
/// reentry behavior. Transfer toggles cover false `transferFrom` results and
/// fee-on-transfer repayment. These controls persist until a test resets them;
/// normal Foundry isolation provides a fresh deployment for the next test.
contract FlashLoanAssetMock {
    error BalanceReadReverted();
    error AllowanceReadReverted();
    error ApprovalReverted(uint256 amount);
    error ZeroFirstApprovalRequired(uint256 currentAllowance, uint256 requestedAllowance);
    error InsufficientBalance(address account, uint256 actual, uint256 required);
    error InsufficientAllowance(address owner, address spender, uint256 actual, uint256 required);

    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 allowanceAmount)) private _allowances;

    // Approval and checked-read response faults.
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
    uint16 public transferFeeBps;

    // Reentry observation while the account installs the exact Pool approval.
    bool public approvalReentryEnabled;
    address public approvalReentryTarget;
    bytes public approvalReentryData;
    uint256 public approvalReentryCount;
    bool public lastApprovalReentrySucceeded;
    bytes public lastApprovalReentryReturnData;

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

    function setTransferFeeBps(uint16 newTransferFeeBps) external {
        require(newTransferFeeBps <= 10_000, "fee exceeds transfer");
        transferFeeBps = newTransferFeeBps;
    }

    function setApprovalReentry(address reentryTarget, bytes calldata reentryData, bool enabled) external {
        approvalReentryTarget = reentryTarget;
        approvalReentryData = reentryData;
        approvalReentryEnabled = enabled;
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
            // `mstore` right-aligns 0x1234; returning bytes [30, 32) yields
            // exactly two bytes instead of the ABI-required 32-byte word.
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
            // Return the same deliberately truncated two-byte word as balanceOf.
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

        if (approvalReentryEnabled && amount != 0) {
            approvalReentryCount += 1;
            (lastApprovalReentrySucceeded, lastApprovalReentryReturnData) =
                approvalReentryTarget.call(approvalReentryData);
        }

        if (returnShortApprovalData) {
            // Return the final byte of the stored word: 0x01 without ABI padding.
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
        uint256 fee = amount * transferFeeBps / 10_000;
        _balances[recipient] += amount - fee;
    }
}

/// @dev Changes only `msg.sender` at the callback boundary to model a wrapper
///      or forwarded callback from an address other than the committed Pool.
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

/// @dev Direct Aave V3 `flashLoanSimple` fault model used by callback tests.
///
/// Fault categories are intentionally orthogonal:
/// - origin mutations change sender, initiator, asset, amount, params, selector,
///   or ABI length at callback authentication;
/// - lifecycle faults skip or replay callback consumption;
/// - repayment faults skip, under-pull, over-pull, return false, charge a token
///   fee, or leave residual allowance through the cooperating asset mock;
/// - outer-call failures occur before principal transfer, after callback, or
///   after repayment to prove whole-call rollback;
/// - a forced receiver separates the principal/callback recipient from the
///   receiver committed in the originating calldata.
///
/// Nested callback-plan faults are encoded in `CallbackEnvelope.callbackCalls`
/// by the owning fixture rather than hidden in this Pool. Configuration remains
/// active for repeated calls in one test and must be explicitly restored when a
/// test runs another scenario; Foundry creates a fresh mock for each test setup.
contract AaveV3FlashLoanPoolMock is IAaveV3FlashLoanSimplePool {
    error CallbackReturnedFalse();
    error RepaymentPullReturnedFalse();
    error OuterTargetFailure(uint8 failurePoint);

    enum CallbackMutation {
        None,
        WrongSender,
        WrongInitiator,
        WrongAsset,
        WrongAmount,
        WrongParams,
        WrongCalldataLength
    }

    enum FailurePoint {
        None,
        BeforePrincipalTransfer,
        AfterCallback,
        AfterRepayment
    }

    FlashLoanCallbackForwarder private immutable _callbackForwarder;

    // Callback origin and lifecycle controls.
    uint256 public premium;
    CallbackMutation public callbackMutation;
    bool public skipCallback;
    bool public replayCallback;
    bool public replayWithDifferentParams;

    // Repayment and receiver controls.
    bool public pullRepayment = true;
    bool public useCustomPullAmount;
    uint256 public customPullAmount;
    bool public useForcedCallbackReceiver;
    address public forcedCallbackReceiver;

    // Observable callback telemetry and outer failure injection.
    uint256 public callbackCount;
    bytes32 public lastReceivedCalldataHash;
    FailurePoint public failurePoint;

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

    function setReplayWithDifferentParams(bool enabled) external {
        replayWithDifferentParams = enabled;
    }

    function setFailurePoint(FailurePoint newFailurePoint) external {
        failurePoint = newFailurePoint;
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
        // Failure points bracket the three externally observable phases:
        // principal delivery, authenticated callback, and repayment pull.
        _revertAt(FailurePoint.BeforePrincipalTransfer);
        address callbackReceiver = useForcedCallbackReceiver ? forcedCallbackReceiver : receiverAddress;
        require(FlashLoanAssetMock(asset).transfer(callbackReceiver, amount), "principal transfer failed");

        if (!skipCallback) {
            _invokeCallback(callbackReceiver, asset, amount, params);
            if (replayCallback) {
                bytes memory replayParams = replayWithDifferentParams ? bytes.concat(params, hex"00") : params;
                _invokeCallback(callbackReceiver, asset, amount, replayParams);
            }
        }
        _revertAt(FailurePoint.AfterCallback);

        if (pullRepayment) {
            uint256 repaymentAmount = useCustomPullAmount ? customPullAmount : amount + premium;
            if (!FlashLoanAssetMock(asset).transferFrom(callbackReceiver, address(this), repaymentAmount)) {
                revert RepaymentPullReturnedFalse();
            }
        }
        _revertAt(FailurePoint.AfterRepayment);
    }

    function _invokeCallback(address receiverAddress, address asset, uint256 amount, bytes memory params) private {
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
        if (callbackMutation == CallbackMutation.WrongCalldataLength) {
            callbackAccepted = _invokeTruncatedCallback(
                receiverAddress, callbackAsset, callbackAmount, callbackInitiator, callbackParams
            );
        } else if (callbackMutation == CallbackMutation.WrongSender) {
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

    function _invokeTruncatedCallback(
        address receiverAddress,
        address callbackAsset,
        uint256 callbackAmount,
        address callbackInitiator,
        bytes memory callbackParams
    ) private returns (bool callbackAccepted) {
        bytes memory callbackCalldata = abi.encodeCall(
            IDefiSimplify7702Account.executeOperation,
            (callbackAsset, callbackAmount, premium, callbackInitiator, callbackParams)
        );
        // `bytes memory` stores its length in the first word and payload at +32.
        // Reducing only the length by one removes the final byte from the
        // dynamically encoded params tail while leaving all payload bytes in
        // memory, so CALL observes canonical calldata truncated by one byte.
        assembly ("memory-safe") {
            mstore(callbackCalldata, sub(mload(callbackCalldata), 1))
        }
        (bool callbackSucceeded, bytes memory callbackReturnData) = receiverAddress.call(callbackCalldata);
        if (!callbackSucceeded) {
            // Bubble the receiver's complete revert bytes without ABI decoding.
            // `callbackReturnData + 32` skips the in-memory length word.
            assembly ("memory-safe") {
                revert(add(callbackReturnData, 32), mload(callbackReturnData))
            }
        }
        callbackAccepted = abi.decode(callbackReturnData, (bool));
    }

    function _revertAt(FailurePoint expectedFailurePoint) private view {
        if (failurePoint == expectedFailurePoint) {
            revert OuterTargetFailure(uint8(expectedFailurePoint));
        }
    }
}

/// @dev Commits the wrapper as the direct target while the downstream Pool remains
///      the actual callback sender. The production account must reject this topology.
contract FlashLoanWrapper {
    function requestFlashLoan(
        AaveV3FlashLoanPoolMock pool,
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params
    ) external {
        pool.flashLoanSimple(receiver, asset, amount, params, 0);
    }
}
