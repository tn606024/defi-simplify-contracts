# DeFi Simplify Contracts

Independent EIP-7702 execution and post-condition contracts for building atomic
DeFi transactions.

These contracts can be integrated directly from any wallet, SDK, or automation
system that can construct EIP-7702 transactions and encode Solidity calldata.
They do not require the `defi-simplify` Go SDK.

> [!WARNING]
> **Experimental and unaudited.** The contracts can execute arbitrary external
> calls from a delegated account. Incorrect targets, calldata, patch offsets,
> approvals, price limits, or assertions can cause total and irreversible loss.
> The current deployment is not recommended for production funds. Use at your
> own risk.

## Contracts at a glance

| Contract | Use it when you need |
| --- | --- |
| [`DefiSimplify7702Account`](src/DefiSimplify7702Account.sol) | An EIP-7702 account that can execute ordinary batches, derive later call amounts from ERC20 balances, and receive one authenticated Aave V3 simple-flash-loan callback |
| [`FlowAssertions`](src/FlowAssertions.sol) | Typed end-of-transaction checks for ERC20 balances, balance changes, or an Aave V3 health factor |
| [`StaticCallUint256Assertions`](src/StaticCallUint256Assertions.sol) | A low-level adapter that reads one fixed `uint256` word from a caller-reviewed target and enforces a minimum or maximum |

All three contracts are direct and immutable. They have no owner, admin, proxy,
upgrade function, withdrawal function, or protocol registry.

## Base deployment

Base is the only supported chain in this version.
The official deployment is published as the experimental, unaudited
[`v1.0.0`](https://github.com/tn606024/defi-simplify-contracts/releases/tag/v1.0.0)
release.

| Contract | Address |
| --- | --- |
| `DefiSimplify7702Account` | [`0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA`](https://basescan.org/address/0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA#code) |
| `FlowAssertions` | [`0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5`](https://basescan.org/address/0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5#code) |
| `StaticCallUint256Assertions` | [`0x034ee940A644323463AB074DCA99504BF5a666EA`](https://basescan.org/address/0x034ee940A644323463AB074DCA99504BF5a666EA#code) |

The account address above is an implementation address. Do not send user funds
to it. An EOA authorizes that implementation through EIP-7702 and continues to
hold assets and protocol positions at the EOA address.

Complete ABIs are available in [`abi/`](abi/). Deployment transactions, runtime
code hashes, and reproducible deployment identity are available in
[`deployments/base-v1.json`](deployments/base-v1.json).

The repository's current default build is the **unreleased and unbroadcast
v1.1.0 candidate**, compiled with 10,000 optimizer runs. It is not installed at
the official v1.0.0 addresses above and has no assigned trust level. Its
predicted addresses, hashes, sizes, and explicit `not-broadcast` status are
recorded in
[`deployments/base-v1.1-candidate.json`](deployments/base-v1.1-candidate.json).
The historical v1.0.0 build remains reproducible from its pinned deployment
source commit with 200 optimizer runs.

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

## Integration checklist

Before submitting a transaction:

1. verify the chain ID, implementation address, runtime code hash, EntryPoint,
   protocol targets, and selectors;
2. encode calls from structured ABIs rather than editing raw hex;
3. derive and test every patch or assertion offset;
4. set protocol-native slippage, price, premium, and other economic limits;
5. append final assertions for the outcome that must remain true;
6. simulate the exact signed transaction against recent chain state;
7. display targets, asset movements, approvals, and bounds to the signer;
8. keep a way to clear or replace the EIP-7702 delegation.

Simulation reduces mistakes but is not an on-chain safety proof. State,
liquidity, oracle values, proxy implementations, and prices may change before
inclusion.

## Important limitations

- A failed execution still consumes gas and nonce. A newly processed EIP-7702
  delegation may remain installed even if the execution portion reverts.
- Dynamic patches read ERC20 balances only. Native ETH balances and target
  return values cannot be used as patch sources in v1.
- Only direct Aave V3 `flashLoanSimple` callbacks are supported. Multi-asset,
  nested, wrapper-mediated, ERC-3156, Balancer, Morpho, and Uniswap callbacks
  are not supported.
- The account does not identify safe protocols, routers, tokens, proxies, or
  calldata. Target admission belongs to the integrating wallet or client.
- A successful EVM call does not prove useful work occurred. Calls to addresses
  without code may succeed, and value may be transferred to them.
- Token behavior is assumed to resemble conventional ERC20
  `balanceOf`/`allowance`/`approve`. Unusual tokens require separate review.
- Assertions check only their stated post-condition. They do not validate
  profitability, fair pricing, oracle quality, or every intermediate action.
