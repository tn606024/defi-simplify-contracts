# Base fork tests

RPC-dependent Base tests live here and run separately from the default CI suite.
Use a pinned or explicitly documented Base block whenever reproducibility matters.

The workflow requires the `BASE_RPC_URL` GitHub Actions secret and never stores
RPC credentials in the repository.

`BaseDeploymentFactory.t.sol` runs at current Base state. It freezes the
Arachnid deterministic deployment proxy and EntryPoint runtime identities,
reconstructs every official `salt || initcode` payload, and verifies the
already-existing direct runtimes. The vacancy branch retains an equivalent
disposable-fork factory proof for earlier chain state. The separate
`script/check-base-v1-onchain-deployment.sh` RPC check verifies the three
historical transactions and receipts against the official manifest. No test or
check broadcasts a Base transaction.

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
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
forge snapshot --check \
  --match-path 'test/fork/BaseAaveV3StaticFlowGas.t.sol' \
  --match-test 'test_Gas_' \
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
```

The gas baselines are `182,769` for approve-plus-supply, `381,138` for
supply-plus-borrow, and `69,934` for repay-plus-withdraw. Setup calls are paused
out of the latter two measurements.

An execution revert atomically restores protocol, token, and allowance state,
but still consumes gas and nonce. For a first EIP-7702 transaction, a processed
delegation may remain installed even when the execution portion reverts.

## Guarded Aave V3 WETH-collateral/USDC-debt loop

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
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
forge snapshot --check \
  --match-path 'test/fork/BaseAaveV3*Gas.t.sol' \
  --match-test 'test_Gas_' \
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
```

The guarded WETH-collateral/USDC-debt loop baseline is `621,217` gas; setup and
fork identity checks are outside the measured test body.

## Flash-assisted Aave V3 cbETH/WETH lifecycle

`BaseAaveV3FlashLifecycle.t.sol` and
`BaseAaveV3FlashLifecycleGas.t.sol` pin Base block `48,961,870` and reuse the
frozen EntryPoint and Aave V3 Pool identities. They additionally verify:

- Base cbETH:
  `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22`
- Aave Base aCBETH:
  `0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad`
- Aave Base variable-debt WETH:
  `0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E`
- official Uniswap V3 `SwapRouter02`:
  `0x2626664c2603336E57B271c5C0b26F421741e481`
- direct cbETH/WETH 0.05% pool:
  `0x10648BA41B8565907Cfa1496765fA4D95390aa0d`
- Aave's reported simple-flash-loan premium: `5` basis points.

The fixture freezes the cbETH, reserve-token, Router, and pool runtime code
hashes; checks the Router factory and wrapped-native identity; checks the
Uniswap factory mapping, pool token order, fee, and nonzero liquidity; and
checks each Aave reserve token's underlying asset. These are reproducible fork
identities, not a claim that the externally governed Aave Pool proxy or token
contracts are immutable.

The three successful plans are:

1. **Leverage open:** supply `0.3 cbETH`, flash-borrow `0.2 WETH`, swap that
   WETH for exactly `176117556140503803` wei cbETH at the pinned state, patch
   only the checkpoint delta into Aave approval and supply calls, then borrow
   `0.2001 WETH` to fund principal plus premium.
2. **Partial deleverage:** start with `0.5 cbETH` collateral and `0.2 WETH`
   nominal variable debt, flash-borrow and repay `0.05 WETH`, withdraw
   `0.05 cbETH`, sell exactly `44096587638647255` wei cbETH for
   `0.050025 WETH`, and resupply only the
   `5903412361352745` wei outer-checkpoint remainder after the callback.
3. **Full close:** patch the visible variable-debt-token balance
   (`200000000000000001` wei at the pinned state) into
   `flashLoanSimple.amount` and the callback's Aave repayment approval, repay
   all debt, withdraw all visible collateral, sell only
   `176388991438775042` wei cbETH for principal plus the rounded-up
   `100000000000001` wei premium, and retain the unused collateral.

The full-close flash principal is resolved on-chain from the current debt-token
balance, while its exact-output repayment quote and `maxPremium` are signed
plan inputs. If debt accrual makes those inputs stale before execution, the
sentinel and repayment checks revert the whole batch; this v1 reference plan
does not perform on-chain arithmetic to reprice the callback envelope.

All three plans preserve pre-existing WETH and cbETH sentinels. They check
Aave and Uniswap events, delegated-EOA position ownership, final Aave account
data, exact Pool repayment, and zero residual Aave Pool and Router allowances.
The leverage and partial-deleverage plans end with typed health-factor
assertions. The full close ends with generic reviewed fixed-word assertions
that debt is zero and Aave reports the canonical no-position health factor.

The direct Base `SwapRouter02` entrypoints have `amountOutMinimum` or
`amountInMaximum` and a nonzero `sqrtPriceLimitX96`, but no deadline. This proof
does not turn dynamic patch BPS into slippage protection and does not claim an
on-chain expiry guarantee. Quotes, premiums, proxy implementations, market
liquidity, and token behavior must be re-simulated and revalidated against
production admission policy.

Fork failures cover a premium above the signed maximum, impossible
exact-input minimum output, excessive final health factor, insufficient
repayment balance, malformed callback envelope, nested callback request, and
an exact-output input cap below the pinned quote. Each compares native, token,
allowance, Aave position, and Uniswap pool state against its execution-time
snapshot. The faithful callback unit and invariant suites separately cover
wrong sender, wrong initiator and origin reconstruction, a callback-enabled
call returning without consumption, replay, public-entrypoint reentrancy,
Pool repayment-pull failure, residual allowance, invocation isolation, and
transient rollback. Together they prove the provider-specific Base integration
and provider-independent callback state machine without trying to induce
impossible Pool behavior on the live fork.

`abi/BaseAaveV3FlashLifecycle.golden.json` freezes every lifecycle patch offset,
original word, resolved word, and patched calldata. It also freezes the
complete full-close `CallbackEnvelope`, complete original and patched
`flashLoanSimple` calldata, and the hash of the actual patched origin for the
Go SDK boundary.

Run the proof and its committed gas baselines with:

```sh
forge test \
  --match-path 'test/fork/BaseAaveV3FlashLifecycle*.t.sol' \
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
forge snapshot --check \
  --match-path 'test/fork/BaseAaveV3FlashLifecycleGas.t.sol' \
  --match-test 'test_Gas_' \
  --fork-url "$BASE_RPC_URL" \
  --fork-retries 5 \
  --fork-retry-backoff 1000
```

The measured execution-only baselines are `688,723` gas for leverage open,
`414,017` for partial deleverage, and `300,587` for full close. Position setup,
fork identity checks, plan construction, and observed-debt reads are paused out
of the measured bodies.
