# DeFi Simplify Contracts

[![CI](https://github.com/tn606024/defi-simplify-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/tn606024/defi-simplify-contracts/actions/workflows/ci.yml)
[![Base fork tests](https://github.com/tn606024/defi-simplify-contracts/actions/workflows/base-fork.yml/badge.svg)](https://github.com/tn606024/defi-simplify-contracts/actions/workflows/base-fork.yml)

Many DeFi workflows require several calls in a specific order. Supplying
collateral and borrowing from Aave, for example, requires an ERC20 approval and
multiple Pool calls. These operations are most useful when the whole sequence
succeeds or reverts as one atomic transaction.

An external Multicall contract can batch the calls, but it becomes `msg.sender`
at every downstream protocol. ERC20 and DeFi contracts then observe the
Multicall contract instead of the user's EOA, changing whose allowances,
assets, positions, receivers, and callbacks are involved.

DeFi Simplify uses EIP-7702 to run a reusable batch executor in the user's EOA
context. Downstream calls still originate from the EOA, so the user remains the
protocol-visible caller and continues to hold the resulting assets and
positions at the same address.

Protocol routing and plan construction remain off chain. Developers can
compose workflows in Go from reusable steps instead of deploying and upgrading
a new Solidity strategy contract for every combination. The resulting plan is
submitted to the shared on-chain account as one atomic transaction.

This repository provides the three direct, immutable contracts used to execute
those plans and check their outcomes on Base:

| Contract | Responsibility |
| --- | --- |
| [`DefiSimplify7702Account`](src/DefiSimplify7702Account.sol) | Preserves the pinned account's ordinary `execute` / `executeBatch` behavior, adds runtime balance-based `executeBatchDynamic`, and receives one authenticated Aave V3 simple-flash-loan callback |
| [`FlowAssertions`](src/FlowAssertions.sol) | Provides typed post-condition checks for ERC20 balances, balance changes, and Aave V3 health factor |
| [`StaticCallUint256Assertions`](src/StaticCallUint256Assertions.sol) | Reads one reviewed `uint256` return word and enforces a minimum or maximum |

Together, they let a delegated account execute an atomic call sequence, use
token amounts that become known only while that sequence is running, and check
the final result before the transaction can commit.

> [!WARNING]
> **Experimental and unaudited.** A bad execution plan can cause total and
> irreversible loss. Do not use the current deployment with production funds.

## Why `executeBatchDynamic` exists

An ordinary multicall works only when every call's calldata can be fully encoded
before the transaction starts. That is often not true for DeFi. A borrow,
withdrawal, claim, swap, or flash-loan callback may produce an amount that a
later call needs as its input. Before execution, the client can estimate that
amount, but it cannot know the account's exact runtime balance or exact balance
increase.

For example, a fixed multicall cannot directly express "after this call returns,
swap exactly the USDC it added to my account." Hard-coding the expected output
can leave dust or make the next call revert when the actual amount differs.

`executeBatchDynamic` solves this by letting an ordered batch connect a runtime
ERC20 balance to a later call:

1. A producer call declares a named checkpoint for a token. The account records
   its balance immediately before calling the producer.
2. After the producer runs, a later consumer call can read either the account's
   complete current token balance or the exact increase since that checkpoint.
3. The account applies optional basis points, then replaces one validated,
   ABI-aligned 32-byte calldata word with the resulting amount.
4. The consumer executes with the patched calldata. Later calls may repeat the
   same pattern, and an assertion call can validate the final outcome.

`CurrentBalance` includes inventory the account already held.
`CheckpointDelta` computes `currentBalance - checkpointBalance`, so a consumer
can use only the amount produced after the checkpoint. Patches are resolved
immediately before their target call, not during off-chain plan construction.
See [Build a dynamic batch](#3-build-a-dynamic-batch) for the exact data model
and offset rules.

The account deliberately does not interpret the strategy. It does not find
routes, quote prices, choose protocols, decide profitability, or determine
whether arbitrary calldata is appropriate. Those decisions remain with the
integrating SDK, wallet, automation system, signer, and user.

If any target or final assertion reverts, the execution-time protocol, token,
and allowance changes made by the sequence revert atomically.

## System boundary

```text
Go SDK / wallet / automation / signer
  - builds typed calldata and EIP-7702 authorization
  - admits chain, runtime, target, selector, offsets, and economic limits
  - simulates the exact transaction and explains it to the signer
                         |
                         v
EIP-7702 delegated EOA using DefiSimplify7702Account
  - inherited execute / executeBatch and ERC-4337 validation
  - checkpoint-scoped executeBatchDynamic calldata patching
  - one authenticated direct Aave V3 flashLoanSimple callback window
                         |
                         v
Reviewed protocol and token calls on Base
                         |
                         v
FlowAssertions / StaticCallUint256Assertions
  - caller-bound typed or reviewed fixed-word post-conditions
```

Every execution path uses EVM `CALL`, never `DELEGATECALL`. The three deployed
contracts are direct and immutable, with no owner, admin, proxy, upgrade
function, withdrawal function, protocol registry, or custom permanent storage.

## Current SDK compatibility

The contracts remain independently integrable from any system that can
construct EIP-7702 transactions and encode Solidity calldata; using the
official SDK is not required.

The public [`defi-simplify` Go SDK](https://github.com/tn606024/defi-simplify)
now selects the official v1.1.0 Base deployment and supports inherited static
and custom dynamic account execution. Full public SDK parity for typed
assertions, callback-plan construction, and every documented Base strategy is
still in progress.

The released [`base-v1.1.json`](deployments/base-v1.1.json) manifest retains
`sdkIntegrationStatus: "not-integrated"` because it records the exact status at
the v1.1.0 publication commit. It is frozen release evidence, not a live
compatibility flag, and later SDK adoption does not rewrite that historical
manifest state.

## Development quick start

Prerequisites are Git, the repository-pinned Foundry `v1.7.1`, and Slither
`0.11.4` for the complete non-RPC gate. The
[`ci.yml`](.github/workflows/ci.yml) workflow documents the pinned Python and
Slither installation used by the project.

```sh
git clone --recurse-submodules \
  https://github.com/tn606024/defi-simplify-contracts.git
cd defi-simplify-contracts
export PATH="$HOME/.foundry/bin:$PATH"
make check
```

For an existing checkout, initialize or refresh the exact submodule revisions
before validation:

```sh
git submodule update --init --recursive
make check-toolchain
```

The Base suite is intentionally separate because it requires an RPC endpoint:

```sh
BASE_RPC_URL="https://your-reviewed-base-rpc.example" make check-base
```

Never commit RPC URLs, API keys, keystores, or broadcast output. Run
`make help` for focused build, test, coverage, gas, reproducibility, deployment,
and fork targets.

## Base v1.1.0 deployment

The current 10,000-optimizer-run source build is deployed as three direct,
immutable contracts recorded in the reproducible
[`v1.1.0` Base manifest](deployments/base-v1.1.json):

| Contract | Address | Deployment transaction |
| --- | --- | --- |
| `DefiSimplify7702Account` | [`0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69`](https://basescan.org/address/0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69#code) | [`0x9256cd…80855`](https://basescan.org/tx/0x9256cd73512476ad7ec3e955bbeb91d9b9f8d34d2c26aaafec0d18f4d4c80855) |
| `FlowAssertions` | [`0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16`](https://basescan.org/address/0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16#code) | [`0x936043…d22c6`](https://basescan.org/tx/0x93604354100fef930e19b8924b624c8b1044d2360cbf62cd28aadba6437d22c6) |
| `StaticCallUint256Assertions` | [`0x28734029a24448cAA307D286823cA21DC57e8393`](https://basescan.org/address/0x28734029a24448cAA307D286823cA21DC57e8393#code) | [`0x944c82…b9900`](https://basescan.org/tx/0x944c827a13313750bd6ee282c2424a576b57bce73026bf31abcac34b7fbb9900) |

All three receipts and direct runtime identities have been independently
re-read from Base. Each direct contract has exact-match BaseScan source
verification from its metadata-derived production source closure. The released
manifest assigns `official` only as the project-published artifact and
deployment identity, not as a security claim. The manifest's `not-integrated`
value records its release-publication state; see
[Current SDK compatibility](#current-sdk-compatibility) for the later SDK
adoption.

Base is the only supported chain in this version.

The account address above is an implementation address. Do not send user funds
to it. An EOA authorizes that implementation through EIP-7702 and continues to
hold assets and protocol positions at the EOA address.

Complete ABIs are available in [`abi/`](abi/). Deployment transactions, runtime
code hashes, and reproducible deployment identities are available in
[`deployments/base-v1.1.json`](deployments/base-v1.1.json).

## Using `DefiSimplify7702Account`

### 1. Install the implementation on an EOA

Create a chain-specific EIP-7702 authorization that delegates the user's EOA to
the account implementation. The implementation is configured for Base
EntryPoint v0.9.0:

`0x433709009B8330FDa32311DF1C2AFA402eD8D009`

Account execution must be invoked either by the delegated EOA itself or through
that EntryPoint. The implementation deployment address is not the user's
account and does not hold the user's assets.

Use the complete account ABI:

- [`abi/DefiSimplify7702Account.json`](abi/DefiSimplify7702Account.json)
- [`IDefiSimplify7702Account.sol`](src/interfaces/IDefiSimplify7702Account.sol)

Your EIP-7702 client is responsible for constructing the authorization,
transaction, signature, nonce, gas settings, and optional ERC-4337
`PackedUserOperation`.

### 2. Choose an execution mode

The account provides three useful paths:

| Need | Function |
| --- | --- |
| Execute one call with an already-known amount | inherited `execute` |
| Execute several calls with already-known calldata | inherited `executeBatch` |
| Use balances produced during the batch as later call inputs | `executeBatchDynamic` |

Every path uses normal EVM `CALL`. If any target or final assertion reverts, the
execution-time protocol, token, and allowance changes made by the batch revert
atomically.

### 3. Build a dynamic batch

`executeBatchDynamic` accepts an ordered list of `DynamicCall` values:

```solidity
struct DynamicCall {
    address target;
    uint256 value;
    bytes data;
    BalanceCheckpoint[] checkpointsBefore;
    BalancePatch[] patches;
    bool expectsCallback;
}
```

For each call, the account:

1. copies `data` into memory;
2. resolves each patch from the current balance or an earlier checkpoint and
   writes the amount into its ABI word;
3. records `checkpointsBefore` immediately before the target call;
4. calls `target` with the patched calldata;
5. reverts the entire batch if the target or callback validation fails.

A `BalancePatch` replaces one ABI-aligned 32-byte word:

```solidity
struct BalancePatch {
    address token;
    bytes32 checkpointId;
    uint32 offset;
    uint16 bps;
    BalanceSource source;
}
```

- `CurrentBalance` uses the account's entire current ERC20 balance and requires
  `checkpointId == 0`.
- `CheckpointDelta` uses only
  `currentBalance - checkpointBalance`, excluding inventory that existed before
  the producer call.
- `bps` selects between 1 and 10,000 basis points of that amount.
- `offset` includes the four-byte function selector. For the first static ABI
  argument it is `4`, for the second it is `36`, and so on. Dynamic tuples and
  arrays require offsets derived from the actual ABI encoding.

The contract checks alignment, bounds, and patch ordering, but it cannot know
whether an offset represents an amount, receiver, pointer, or array length.
Derive offsets from structured ABI data and compare the final bytes against a
known-good encoding before signing.

### Dynamic-flow example

Suppose a flow borrows USDC, swaps exactly the borrowed output to WETH, and
supplies exactly the WETH received:

```text
[0] supply initial collateral
[1] checkpoint USDC, then borrow USDC
[2] approve the router using the USDC checkpoint delta
[3] checkpoint WETH, then swap using the USDC checkpoint delta
[4] approve Aave using the WETH checkpoint delta
[5] supply the WETH checkpoint delta
[6] assert the final Aave V3 health factor
```

The checkpoints prevent pre-existing USDC or WETH in the account from being
accidentally swept into the strategy.

See the complete Base example:

- [`BaseAaveV3DynamicStrategy.t.sol`](test/fork/BaseAaveV3DynamicStrategy.t.sol)
- [`BaseAaveV3DynamicStrategy.golden.json`](abi/BaseAaveV3DynamicStrategy.golden.json)

### Aave V3 simple flash loans

The account supports one direct Aave V3 `flashLoanSimple` call in a dynamic
batch. Encode the callback plan in the flash-loan `params` field:

```solidity
struct CallbackEnvelope {
    uint256 maxPremium;
    DynamicCall[] callbackCalls;
}
```

Then set `expectsCallback = true` on the outer `DynamicCall` that directly calls
the Aave V3 Pool. The account:

1. commits the direct Pool address and fully patched `flashLoanSimple` calldata;
2. authenticates Aave's `executeOperation` callback against that exact call;
3. executes `callbackCalls` with a separate checkpoint scope;
4. rejects nested callbacks;
5. checks `premium <= maxPremium`;
6. approves exactly `amount + premium` for repayment;
7. requires the Pool to leave zero repayment allowance before continuing.

Applications should never call `executeOperation` as a normal user entrypoint.
It succeeds only during the matching active dynamic call.

Reference implementations:

- [`BaseAaveV3FlashLifecycle.t.sol`](test/fork/BaseAaveV3FlashLifecycle.t.sol)
- [`BaseAaveV3FlashLifecycle.golden.json`](abi/BaseAaveV3FlashLifecycle.golden.json)
- [`CallbackExecution.golden.json`](abi/CallbackExecution.golden.json)

## Using `FlowAssertions`

`FlowAssertions` is an independent, permissionless checker. It can be appended
to an inherited static batch, a dynamic batch, or another account system that
makes ordinary calls.

Every assertion checks `msg.sender`. When a delegated EOA calls it during a
batch, the EOA is automatically the subject of the assertion; the caller cannot
provide a different account address by mistake.

Available operations:

```solidity
snapshotBalance(address token, bytes32 checkpointId)
assertBalanceAtLeast(address token, uint256 minimum)
assertBalanceIncreaseAtLeast(
    address token,
    bytes32 checkpointId,
    uint256 minimumDelta
)
assertBalanceDecreaseAtMost(
    address token,
    bytes32 checkpointId,
    uint256 maximumDelta
)
assertAaveV3HealthFactorAtLeast(
    address pool,
    uint256 minimumHealthFactor
)
```

Balance snapshots last for the current transaction and are scoped to
`(msg.sender, checkpointId)`. A snapshot can therefore be created before a flow
and consumed by one or more assertions near the end of the same transaction.

The Aave assertion reads `getUserAccountData(msg.sender)` from the supplied
Aave V3-compatible Pool. It trusts that Pool and its configured oracle; callers
must verify the Pool address themselves.

Usage references:

- [`IFlowAssertions.sol`](src/interfaces/IFlowAssertions.sol)
- [`abi/FlowAssertions.json`](abi/FlowAssertions.json)
- [`FlowAssertionsBatchIntegration.t.sol`](test/integration/FlowAssertionsBatchIntegration.t.sol)
- [`BaseAaveV3FlowAssertions.t.sol`](test/fork/BaseAaveV3FlowAssertions.t.sol)

## Using `StaticCallUint256Assertions`

This contract covers reviewed read methods that return a fixed-position
`uint256` but do not have a typed function in `FlowAssertions`.

```solidity
assertStaticCallUint256AtLeast(
    address target,
    bytes data,
    uint32 accountOffset,
    uint32 returnOffset,
    uint256 minimum
)

assertStaticCallUint256AtMost(
    address target,
    bytes data,
    uint32 accountOffset,
    uint32 returnOffset,
    uint256 maximum
)
```

There are two modes:

- **Account-bound:** `accountOffset` identifies an ABI word in `data` that the
  checker replaces with `msg.sender` before `STATICCALL`.
- **Global read:** `accountOffset == type(uint32).max`; `data` is not modified.

`returnOffset` selects the 32-byte word to compare, starting at byte zero of the
returned data.

This is a low-level adapter, not a general authorization or type-safety
mechanism. Before using it, verify the exact checker address, target, selector,
input offset, return offset, comparison direction, and unit of the bound.
Prefer a typed assertion whenever one exists.

Usage references:

- [`IStaticCallUint256Assertions.sol`](src/interfaces/IStaticCallUint256Assertions.sol)
- [`abi/StaticCallUint256Assertions.json`](abi/StaticCallUint256Assertions.json)
- [`StaticCallUint256AssertionsBatchIntegration.t.sol`](test/integration/StaticCallUint256AssertionsBatchIntegration.t.sol)
- [`BaseStaticCallUint256Assertions.t.sol`](test/fork/BaseStaticCallUint256Assertions.t.sol)
