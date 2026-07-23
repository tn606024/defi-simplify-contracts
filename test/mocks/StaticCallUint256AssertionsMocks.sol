// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

contract StaticCallUint256TargetMock {
    error StaticReadFailure(uint256 code, bytes payload);

    mapping(address account => uint256 value) private _accountValues;

    function setAccountValue(address account, uint256 value) external {
        _accountValues[account] = value;
    }

    function accountValue(address account) external view returns (uint256) {
        return _accountValues[account];
    }

    function accountValueWithSentinels(uint256 leadingSentinel, address account, uint256 trailingSentinel)
        external
        view
        returns (uint256 leadingResult, uint256 accountValueResult, uint256 trailingResult)
    {
        return (leadingSentinel, _accountValues[account], trailingSentinel);
    }

    function tokenBalance(address token, address account) external view returns (uint256) {
        return IBalanceOf(token).balanceOf(account);
    }

    function calldataHash(uint256, address, uint256) external pure returns (uint256) {
        return uint256(keccak256(msg.data));
    }

    function globalTuple(uint256 leadingSentinel, uint256 value, uint256 trailingSentinel)
        external
        pure
        returns (uint256 leadingResult, uint256 valueResult, uint256 trailingResult)
    {
        return (leadingSentinel, value, trailingSentinel);
    }

    function exactReturn(uint256 value) external pure returns (uint256) {
        return value;
    }

    function emptyReturn() external pure returns (uint256) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }

    function shortReturn() external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 0x123456)
            return(29, 3)
        }
    }

    function revertRead(uint256 code, bytes calldata payload) external pure returns (uint256) {
        revert StaticReadFailure(code, payload);
    }
}
