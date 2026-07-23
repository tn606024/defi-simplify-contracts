# Base fork tests

RPC-dependent Base tests live here and run separately from the default CI suite.
Use a pinned or explicitly documented Base block whenever reproducibility matters.

The workflow requires the `BASE_RPC_URL` GitHub Actions secret and never stores
RPC credentials in the repository.

`BaseAaveV3FlowAssertions.t.sol` pins Base block `48,961,870` and the Aave V3
Base Pool `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`. The Pool address is sourced
from the official
[Aave address book](https://github.com/aave-dao/aave-address-book/blob/main/src/AaveV3Base.sol).
The no-position delegated EOA at that block reports Aave V3's canonical maximum
health factor and is checked through an inherited static account batch.

`BaseStaticCallUint256Assertions.t.sol` pins the same block and independently
checks both generic modes. Account-binding mode replaces an Aave V3
`getUserAccountData` account argument with the delegated EOA and selects the health-factor
word; global-read mode checks Base WETH `totalSupply()` without modifying its
calldata. The suite covers inherited static and custom dynamic batch paths.
