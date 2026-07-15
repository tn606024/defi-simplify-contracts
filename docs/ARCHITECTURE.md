# Architecture

Status: implementation design
Date: 2026-07-15

## 1. System Context

```text
Go application
  -> defi-simplify SDK
       -> builds static Calls or checkpoint-based DynamicCalls
       -> simulates the exact delegated execution
       -> submits EIP-7702 transaction or normal delegated-account call
            -> user's delegated EOA
                 -> protocol contracts
                 -> FlowAssertions
```

The Go SDK knows protocol ABIs and user intent. The account contract knows only
authorization, ERC20 balances, checkpoints, calldata offsets, and calls. The
assertion contract knows only read-only post-conditions.

## 2. Repository Boundary

Target repository layout:

```text
src/
  DefiSimplify7702Account.sol
  FlowAssertions.sol
  interfaces/
    IDefiSimplify7702Account.sol
    IFlowAssertions.sol
test/
  unit/
  fuzz/
  invariant/
  fork/
  mocks/
script/
  Deploy.s.sol
deployments/
  <chain-id>.json
docs/
  VISION.md
  ARCHITECTURE.md
  SPECIFICATION.md
  SECURITY.md
  ROADMAP.md
```

The repository exports ABI JSON, deployed implementation addresses, runtime
code hashes, compiler settings, and source verification metadata. It does not
contain Go protocol adapters.

## 3. Upstream Account Baseline

`DefiSimplify7702Account` inherits `Simple7702Account` from
`eth-infinitism/account-abstraction` v0.9.0 at full commit
`b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`. The source is an unmodified Git
submodule, and its OpenZeppelin v5.1.0 Solidity dependency is pinned at
`69c8def5f222ff96f2b5beff05dfba996368aa79`.

The account accepts an immutable EntryPoint constructor argument. Base uses
v0.9.0 EntryPoint `0x433709009B8330FDa32311DF1C2AFA402eD8D009` with runtime
code hash `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`.
The lock, compiler compatibility, licensing, audit evidence, inherited risks,
and update rule are recorded in ADR-001. No v0.9-specific audit evidence was
found, so the v0.8.0 release's audit statement is not extended to this baseline.

The custom account must not copy or edit upstream files. Inheritance preserves:

- `execute` and `executeBatch` static paths;
- self-or-EntryPoint execution authorization;
- ERC-4337 validation support;
- ERC-1271 signature validation;
- ERC-721 and ERC-1155 receiving support;
- upstream `ExecuteError(index, reason)` static-batch behavior.

The custom repository is responsible for the security of the resulting combined
bytecode even when inherited code has previously been audited.

The Phase 1 baseline at `src/DefiSimplify7702Account.sol` is a concrete,
directly deployable constructor wrapper around the pinned account. It defines no
custom storage or public surface: its ABI is required to match
`Simple7702Account` exactly. Dynamic execution is added only by the later phase
that owns that ABI and behavior.

## 4. Contract Components

### 4.1 DefiSimplify7702Account

At the static compatibility baseline, the custom account contains only the
inherited upstream behavior. The completed v1 account later adds one capability:

```solidity
function executeBatchDynamic(DynamicCall[] calldata calls) external payable;
```

It has no owner, upgrade mechanism, protocol registry, allowlist, or permanent
storage. Authorization is inherited from `_requireForExecute()`.

Conceptual data model:

```solidity
enum BalanceSource {
    CurrentBalance,
    CheckpointDelta
}

struct BalanceCheckpoint {
    address token;
    bytes32 id;
}

struct BalancePatch {
    address token;
    bytes32 checkpointId;
    uint32 offset;
    uint16 bps;
    BalanceSource source;
}

struct DynamicCall {
    address target;
    uint256 value;
    bytes data;
    BalanceCheckpoint[] checkpointsBefore;
    BalancePatch[] patches;
}
```

For each `DynamicCall`, the contract performs this order:

```text
validate call and patch metadata
  -> copy call.data from calldata to memory
  -> resolve every patch from checkpoints created by earlier calls
  -> record checkpointsBefore using current ERC20 balances
  -> CALL target with value and patched memory
  -> continue, or revert with DynamicCallFailed(index, target, reason)
```

Checkpoint creation happens after patches are resolved and immediately before
the target call. A patch cannot reference a checkpoint declared on the same
call. A patch that needs the output of call N references a checkpoint placed
before call N and is consumed by call N+1 or later.

### 4.2 Why Checkpoints Are In-Flow

A single flow-start snapshot is incorrect for common leverage flows:

```text
starting WETH balance = 1.0
supply 1.0 WETH       -> current balance = 0
swap borrowed USDC    -> current balance = 0.8 WETH
```

The flow-start delta is `0.8 - 1.0`, which is negative even though the swap
produced 0.8 WETH. The correct baseline is a WETH checkpoint immediately before
the swap. Named in-flow checkpoints also allow multiple independent deltas for
the same token in one transaction.

Example schedule:

```text
[0] supply WETH
[1] checkpoint USDC "borrow-output"; borrow USDC
[2] approve Router using USDC delta since "borrow-output"
[3] checkpoint WETH "swap-output"; swap USDC delta
[4] supply WETH delta since "swap-output"
[5] assert final Aave health factor
```

### 4.3 Patch Semantics

`offset` is measured from byte zero of `DynamicCall.data`; the four-byte
function selector occupies offsets 0 through 3. v1 patches one ABI-aligned
32-byte word and rejects out-of-bounds or unaligned offsets.

`bps` uses a denominator of 10,000:

```text
10,000 = 100%
 5,000 = 50%
   100 = 1%
     1 = 0.01%
```

The patched amount is `floor(base * bps / 10_000)`, implemented with full-
precision multiplication and division. `base` is either the entire current
balance or `currentBalance - checkpointBalance`.

Balance percentages compose sequentially across calls, not across patches in
the same call. If one consumer call spends 50% of a delta, a later consumer uses
10,000 bps to spend the remaining 50%. Two patches resolved before the same
target call both observe the same pre-call balance.

The implementation may cache one pre-call balance per token across patch
resolution and checkpoint creation for that call. Error attribution belongs to
the first patch or checkpoint that triggers the read. The cache ends before the
target `CALL`, so later calls observe updated chain state.

`token` explicitly selects which ERC20 is read:

```solidity
IERC20(token).balanceOf(address(this))
```

During EIP-7702 delegated execution, `address(this)` is the user's EOA.

### 4.4 Function-Local and Transient State

Account checkpoint records use function-local memory. The implementation first
sums every `checkpointsBefore.length`, allocates a fixed-capacity record array,
and tracks its populated length. Each record contains the opaque ID, token, and
balance. Duplicate and lookup checks linearly scan only the populated prefix.
For the v1 plan sizes, this is simpler and cheaper than hashing and accessing
multiple transient slots per record.

Function-local memory makes checkpoint isolation structural: an external target
frame cannot query the records, a later dynamic invocation receives a fresh
array, and a return or revert discards the records. The populated length is an
unambiguous presence marker, including when the recorded balance is zero. The
account therefore needs no checkpoint invocation counter, transient checkpoint
keys, or cleanup list.

The dynamic execution lock still uses a domain-separated EIP-1153 transient key.
Unlike checkpoint records, the lock must be visible to a new call frame that
tries to reenter the account. The account clears the lock on successful return;
reverts roll back the transient write. FlowAssertions snapshots remain
transaction-scoped transient state and are not changed by this account-specific
decision. ADR-002 records the boundary and alternatives.

### 4.5 FlowAssertions

`FlowAssertions` is deployed independently and called normally by the delegated
EOA. Therefore its `msg.sender` is the user account being checked.

It has:

- no owner;
- no upgradeability;
- no permanent storage;
- no asset-moving function;
- checkpointed transient state keyed by `msg.sender`, token, and checkpoint ID.

v1 assertions:

```solidity
snapshotBalance(address token, bytes32 checkpointId)
assertBalanceAtLeast(address token, uint256 minimum)
assertBalanceIncreaseAtLeast(address token, bytes32 checkpointId, uint256 minimumDelta)
assertBalanceDecreaseAtMost(address token, bytes32 checkpointId, uint256 maximumDelta)
assertAaveHealthFactorAtLeast(address pool, uint256 minimumHealthFactor)
assertStaticCallUint256AtLeast(target, data, accountOffset, returnOffset, minimum)
assertStaticCallUint256AtMost(target, data, accountOffset, returnOffset, maximum)
```

Assertions are ordinary calls. They work in upstream static batches and custom
dynamic batches without coupling the account to the checker.

The generic assertions support two explicit modes. A normal `accountOffset`
overwrites the designated calldata word with `msg.sender`; the
`type(uint32).max` sentinel performs an unmodified global read. Account binding
is an adapter guardrail, not an authorization boundary, because ignored trailing
calldata can bypass which argument the target actually reads. Compliant global
adapters use the sentinel rather than padding. Input and return offsets require
ABI-derived golden tests. Assertion snapshots remain scoped to
`(transaction, msg.sender)` and may be reused by multiple assertions; the SDK
namespaces IDs when composing multiple logical flows.

Neither v1 contract emits custom events. Receipts, protocol and token events,
and traces provide observability.

## 5. Execution Modes

```text
Direct EOA
  one call; EOA caller; no multi-call atomicity

Simple7702Account static batch
  exact calldata; EOA caller; atomic; lowest custom risk

DefiSimplify7702Account static batch
  inherited exact-calldata behavior; used for compatibility checks

DefiSimplify7702Account dynamic batch
  checkpoint deltas and full-balance patches; EOA caller; atomic

Legacy Multicall
  external contract caller; atomic; not EOA-native
```

Static batches remain a first-class path. Dynamic execution is selected only
when at least one amount must be resolved on-chain.

## 6. Capability Detection

The SDK should:

1. read the EOA code and parse an EIP-7702 delegation indicator;
2. compare the delegation target against a chain deployment manifest;
3. verify the target runtime code hash;
4. verify that official targets match reproducible direct immutable artifacts,
   rather than treating a proxy code hash as immutable logic;
5. call ERC-165 `supportsInterface` for the custom dynamic interface;
6. choose static or dynamic encoding from the built flow requirements.

A version string alone is not a security identity. Deployment address and
runtime code hash are authoritative for known direct artifacts. The SDK also
accepts custom deployment manifests, but distinguishes reproducibly verified
artifacts from user-trusted unknown code.

## 7. Protocol Compatibility

| Protocol shape | v1 status | Reason |
| --- | --- | --- |
| Aave V3 ordinary Pool calls | Supported | Inputs and outputs are ERC20 balances; final HF is readable |
| Uniswap router exact-input swap | Supported | Runtime input can be patched; router enforces `amountOutMinimum` |
| Morpho Blue ordinary lending calls | Supported | Asset amounts can use ERC20 balances |
| Morpho internal-share piping | Partial | Shares are protocol accounting, not always ERC20 balances |
| Pendle Router PT operations | Supported with adapter tests | Amount words may be nested but remain ABI-aligned |
| ERC4626, WETH, Lido wrappers | Supported with adapter tests | ERC20 in/out model |
| Uniswap V3 LP NFT management | Not supported dynamically | Later calls may need returned token IDs |
| Flash loans and direct callbacks | Not supported | Require authenticated callback state machine |
| Native ETH dynamic amounts | Not supported in v1 | ERC20-only balance source; use WETH |
| Cross-chain and off-chain signed routes | Out of scope | Different trust and lifecycle model |

Protocol-specific slippage and deadline parameters remain normal calldata. The
account must not replace router or protocol-native protections.

## 8. Deployment Model

Deploy the account and `FlowAssertions` as direct immutable contracts through
Foundry's default Arachnid Deterministic Deployment Proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. A deployment address is identical
across chains only when factory, salt, and complete initcode are identical;
initcode includes the immutable EntryPoint constructor argument. Users delegate
their EOA to the account implementation.

Cross-chain address identity is conditional, not universal. Before a chain is
listed as sharing the official address family, Phase 0 verifies that the
factory exists with the pinned code hash or that its canonical deployment
transaction can be accepted by that chain. Chains that cannot install this
legacy keyless factory may use a maintained alternative such as Safe Singleton
Factory, but they form a different address family and manifest.

Every deployment manifest must include:

- chain ID;
- implementation and assertion addresses;
- runtime code hashes;
- CREATE2 factory address and code hash;
- address-family identifier;
- salt, complete initcode hash, and constructor arguments;
- upstream account-abstraction commit;
- EntryPoint address, version, and code hash;
- Solidity and Foundry versions;
- optimizer and EVM settings;
- source verification links;
- deployment transaction hashes.

No target may be a proxy and no upgrade admin is used. A new version is a new
implementation or assertion address; users explicitly redelegate or select the
new checker when they choose to migrate. Old assertion versions remain usable.

Self-deployment is a first-class path. The SDK accepts a custom manifest and
applies the same address and code-hash verification. Deploying identical
initcode through the same factory and salt yields the same address; deploying
the same direct artifact by another method may preserve runtime code hash but
produce a different address.

The v1 SDK signs only per-chain EIP-7702 authorizations and rejects
authorization `chain_id == 0`. EIP-7702 exposes one delegation target at a time,
so the recommended operating model is a dedicated EOA whose active delegate is
this account implementation.

## 9. References

- EIP-7702: https://eips.ethereum.org/EIPS/eip-7702
- EIP-1153: https://eips.ethereum.org/EIPS/eip-1153
- Weiroll: https://github.com/weiroll/weiroll
- Foundry `cast create2` default deployer: https://getfoundry.sh/cast/reference/cast-create2
- Arachnid Deterministic Deployment Proxy: https://github.com/Arachnid/deterministic-deployment-proxy
- Safe Singleton Factory: https://github.com/safe-fndn/safe-singleton-factory
- account-abstraction releases: https://github.com/eth-infinitism/account-abstraction/releases
- Simple7702Account v0.9.0: https://github.com/eth-infinitism/account-abstraction/blob/v0.9.0/contracts/accounts/Simple7702Account.sol
- BaseAccount v0.9.0: https://github.com/eth-infinitism/account-abstraction/blob/v0.9.0/contracts/core/BaseAccount.sol
