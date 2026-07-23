// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface ISubjectBalance {
    function balanceOf(address subject) external view returns (uint256);
}

contract StaticCallUint256TargetMock {
    error StaticReadFailure(uint256 code, bytes payload);

    mapping(address subject => uint256 value) private _subjectValues;

    function setSubjectValue(address subject, uint256 value) external {
        _subjectValues[subject] = value;
    }

    function subjectValue(address subject) external view returns (uint256) {
        return _subjectValues[subject];
    }

    function subjectTuple(uint256 left, address subject, uint256 right)
        external
        view
        returns (uint256 leftResult, uint256 selected, uint256 rightResult)
    {
        return (left, _subjectValues[subject], right);
    }

    function tokenBalance(address token, address subject) external view returns (uint256) {
        return ISubjectBalance(token).balanceOf(subject);
    }

    function calldataHash(uint256, address, uint256) external pure returns (uint256) {
        return uint256(keccak256(msg.data));
    }

    function globalTuple(uint256 left, uint256 selected, uint256 right)
        external
        pure
        returns (uint256 leftResult, uint256 selectedResult, uint256 rightResult)
    {
        return (left, selected, right);
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
