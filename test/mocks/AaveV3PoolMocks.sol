// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IFlowAssertions} from "../../src/interfaces/IFlowAssertions.sol";

contract AaveV3PoolMock is IAaveV3Pool {
    mapping(address user => uint256 healthFactor) private _healthFactors;

    function setHealthFactor(address user, uint256 healthFactor) external {
        _healthFactors[user] = healthFactor;
    }

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return (11, 22, 33, 44, 55, _healthFactors[user]);
    }
}

contract RevertingAaveV3Pool is IAaveV3Pool {
    error AccountDataFailure(uint256 code, bytes payload);

    uint256 private immutable _code;
    bytes private _payload;

    constructor(uint256 code, bytes memory payload) {
        _code = code;
        _payload = payload;
    }

    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        revert AccountDataFailure(_code, _payload);
    }
}

contract ShortReturnAaveV3Pool is IAaveV3Pool {
    function getUserAccountData(address) external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        assembly ("memory-safe") {
            mstore(0, 0x123456)
            return(29, 3)
        }
    }
}

contract FakeAaveV3Pool is IAaveV3Pool {
    function getUserAccountData(address) external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, type(uint256).max);
    }
}

contract AaveV3AssertionCaller {
    function assertHealthFactorAtLeast(IFlowAssertions assertions, address pool, uint256 minimumHealthFactor)
        external
        view
    {
        assertions.assertAaveV3HealthFactorAtLeast(pool, minimumHealthFactor);
    }
}
