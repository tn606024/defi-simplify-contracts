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

## Aave V3 static delegated-account lifecycle

`BaseAaveV3StaticFlows.t.sol` and `BaseAaveV3StaticFlowGas.t.sol` pin Base block
`48,961,870`. They verify the following identities before every scenario:

- EntryPoint v0.9.0:
  `0x433709009B8330FDa32311DF1C2AFA402eD8D009`
- Aave V3 Pool proxy:
  `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`
- Aave V3 Pool implementation:
  `0xA4AbC5FcBA6D0d7E3D144d6dbF6cb6128599dFdB`, revision `11`
- Base WETH:
  `0x4200000000000000000000000000000000000006`
- Base USDC:
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Aave Base aWETH:
  `0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7`
- Aave Base variable-debt USDC:
  `0x59dca05b6c26dbd64b5381374aAaC5CD05644C28`

The fixture also freezes the runtime code hashes, Pool implementation slot,
addresses provider, and reserve-token underlyings. The representative flow
supplies `1 WETH`, borrows `500 USDC` at variable rate mode `2`, then repays the
exact visible debt and withdraws all collateral. Because Aave stores scaled
balances, the visible aWETH and variable-debt balances may differ from nominal
transfer amounts by one smallest unit at the pinned block. The close fixture
funds that observed one-unit debt difference before testing exact repayment.

The tests cover inherited one-call execution, approve-plus-supply,
supply-plus-borrow, repay-plus-withdraw, a full multi-call lifecycle, and a
later-call borrow failure. Both the pinned upstream account and
`DefiSimplify7702Account` are exercised through Prague EIP-7702 delegation
cheatcodes. Aave events, balances, allowances, account data, and debt tokens
prove that Aave sees the delegated EOA rather than the implementation or test
contract. The failure case proves earlier token and Aave state rolls back while
preserving upstream `ExecuteError(callIndex, reason)` attribution. The delegated
account emits no custom event.

Run the lifecycle suite and its committed gas baselines with:

```sh
forge test \
  --match-path 'test/fork/BaseAaveV3StaticFlow*.t.sol' \
  --fork-url "$BASE_RPC_URL"
forge snapshot --check \
  --match-path 'test/fork/BaseAaveV3StaticFlowGas.t.sol' \
  --match-test 'test_Gas_' \
  --fork-url "$BASE_RPC_URL"
```

The gas baselines are `182,769` for approve-plus-supply, `381,138` for
supply-plus-borrow, and `69,934` for repay-plus-withdraw. Setup calls are paused
out of the latter two measurements.

An execution revert atomically restores protocol, token, and allowance state,
but still consumes gas and nonce. For a first EIP-7702 transaction, a processed
delegation may remain installed even when the execution portion reverts.

## Guarded Aave V3 dynamic strategy

`BaseAaveV3DynamicStrategy.t.sol` and
`BaseAaveV3DynamicStrategyGas.t.sol` use the same pinned Base block and Aave
identities, plus:

- official Uniswap V3 `SwapRouter02`:
  `0x2626664c2603336E57B271c5C0b26F421741e481`
- direct USDC/WETH 0.05% pool:
  `0xd0b53D9277642d899DF5C87A3966A349A798F224`
- pool fee: `500`

The successful eight-call plan:

1. approves and supplies `1 WETH` to Aave;
2. checkpoints an existing `37 USDC` sentinel immediately before borrowing
   `500 USDC`;
3. patches the Router approval and `exactInputSingle.amountIn` with only that
   `500 USDC` delta;
4. checkpoints an existing `0.25 WETH` sentinel immediately before the swap;
5. enforces `0.26 WETH` minimum output and a nonzero
   `sqrtPriceLimitX96`;
6. patches the second Aave approval and supply with the observed
   `260391696019929066` wei WETH output at the pinned block; and
7. requires a final Aave V3 health factor of at least `2e18`.

The initial WETH balance is `1.25 WETH`, while the final wallet balance is only
the `0.25 WETH` sentinel. A flow-start delta would therefore be negative even
though the pool emitted a positive WETH output; the immediately-before-swap
checkpoint is required. Swap events, Aave balances, debt tokens, exact
allowances, and account data prove the producer and consumers use the delegated
EOA context.

The Base `SwapRouter02.exactInputSingle` ABI exposes `amountOutMinimum` and
`sqrtPriceLimitX96` but no deadline. The proof calls it directly and does not
weaken account patch alignment or use nested `multicall` calldata to add a
deadline. Fresh simulation, short-lived/private submission, and nonce
replacement are operational mitigations, not on-chain expiry guarantees.
Base USDC and WETH are treated as conventional ERC20s at the pinned block; this
proof does not claim fee-on-transfer or rebasing-token compatibility. All
approvals begin at zero, approve exact observed amounts, and are fully consumed.

Forced failures cover Router slippage, an excessive final health factor,
unaligned patch metadata, token/checkpoint mismatch, and a downstream Aave
failure. Each compares native, WETH, USDC, aWETH, variable debt, allowance, and
Aave account data against an execution-time snapshot to prove full rollback.
Gas, nonce, and a newly processed EIP-7702 delegation remain outside that
rollback guarantee.

The language-neutral
`abi/BaseAaveV3DynamicStrategy.golden.json` fixture freezes all four dynamic ABI
words: Router approval amount, swap input amount, Aave approval amount, and
Aave supply amount.

Run this proof and all Base Aave gas baselines with:

```sh
forge test \
  --match-path 'test/fork/BaseAaveV3DynamicStrategy*.t.sol' \
  --fork-url "$BASE_RPC_URL"
forge snapshot --check \
  --match-path 'test/fork/BaseAaveV3*Gas.t.sol' \
  --match-test 'test_Gas_' \
  --fork-url "$BASE_RPC_URL"
```

The guarded dynamic strategy baseline is `617,084` gas; setup and fork identity
checks are outside the measured test body.
