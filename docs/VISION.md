# Vision

Status: proposed repository vision
Date: 2026-07-12

## Purpose

`defi-simplify-contract` provides the smallest on-chain execution layer needed
by the `defi-simplify` Go SDK to compose atomic, EOA-native DeFi flows.

The contract repository is not a wallet product, protocol router, strategy
marketplace, or general-purpose workflow virtual machine. It is a security-
critical execution primitive for developers who build DeFi services, bots, and
infrastructure in Go and manage their own signing keys.

## Product Thesis

The complete project combines three properties:

1. Go-native DeFi composition.
2. EIP-7702 execution where protocols observe the user's EOA as `msg.sender`.
3. Preflight simulation, on-chain post-conditions, and transaction atomicity.

The intended result is that a stale quote, changed market, invalid protocol
state, or incorrectly built flow reverts without leaving partial protocol or
asset changes. Gas and nonces are still consumed. A delegation installed by an
EIP-7702 authorization is persistent and is not rolled back by a later execution
revert.

## Responsibilities

This repository owns:

- a pinned `Simple7702Account` integration;
- an EOA-native static batch baseline through inherited `executeBatch`;
- checkpoint-based ERC20 balance patching for dynamic batches;
- small, composable post-condition assertion contracts;
- ABI artifacts and deployment metadata consumed by the Go SDK;
- unit, invariant, fuzz, fork, and adversarial tests for the on-chain surface.

This repository does not own:

- protocol calldata construction;
- route finding or price discovery;
- key custody, signing UI, or wallet recovery;
- transaction triggering, scheduling, or keeper infrastructure;
- off-chain simulation reports and human-readable error explanation;
- protocol address registries;
- strategy profitability logic.

Those responsibilities belong to the Go SDK or the integrating application.

## Account Model and User Sovereignty

EIP-7702 gives an EOA one active delegation target at a time. This project
therefore competes for that delegation slot rather than coexisting as an
independent module. The recommended model is a dedicated operation EOA whose
only active delegate is the selected immutable `DefiSimplify7702Account`
implementation. Using a primary long-lived EOA is technically possible but has
a larger asset and compatibility blast radius.

User sovereignty comes from small readable contracts, no admin, no permanent
state, reproducible builds, and explicit migration to a new address. It does
not come from an upgrade key. Users may self-deploy the exact direct immutable
artifact and provide a custom code-hash-pinned manifest without changing SDK
verification semantics.

v1 uses per-chain EIP-7702 authorizations only. Universal `chain_id == 0`
authorizations are deliberately excluded.

## Capability Ladder

### Tier 1: Static EOA-Native Batch

Use the pinned upstream `Simple7702Account` behavior for exact calldata known
before submission.

Examples:

- ERC20 approve, then Aave supply;
- approve, supply, then borrow;
- repay, then withdraw;
- exact-amount Morpho or Pendle Router calls;
- any caller-sensitive batch that does not need runtime value passing.

This is a production feature and the baseline against which custom account
behavior is tested.

### Tier 2: Dynamic EOA-Native Batch

Use `DefiSimplify7702Account` when a later call must consume an ERC20 amount
created by earlier calls.

Examples:

- borrow USDC, swap exactly the borrowed delta, then supply the received asset;
- claim rewards, swap the actual reward balance, then compound;
- withdraw from one lending market and supply the actual received amount to
  another;
- buy or redeem Pendle PT and pass the actual ERC20 output onward.

The contract reads balances and patches explicitly identified ABI words. It
does not understand Aave, Uniswap, Morpho, or Pendle.

### Tier 3: Guarded Execution

Append `FlowAssertions` calls to static or dynamic batches so final state must
satisfy declared constraints.

Examples:

- final Aave health factor is at least a threshold;
- final token balance is at least a minimum;
- a token increased by at least the expected amount;
- a token decreased by no more than a maximum.

### Future: Callback Execution

Flash loans and direct callback protocols require a separate execution model
with callback authentication and an active-flow commitment. They are not an
extension to sneak into v1. They should be designed and reviewed as a new
contract version.

## Protocol Outlook

The generic v1 primitive covers a broad class of strategies whose intermediate
values are represented by ERC20 balances and whose protocol calls are ordinary
ABI calls.

It is a strong fit for:

- Aave V3 supply, withdraw, borrow, repay, leverage, and deleverage flows;
- Uniswap exact-input swaps through a router;
- Morpho Blue lending, collateral, borrow, repay, and market migration flows;
- Pendle Router PT buy, sell, redeem, and rollover legs;
- ERC4626 vaults, WETH, Lido wrappers, and selected Curve exchanges.

It does not fully cover:

- flash loans or direct callbacks;
- values available only in return data and not reflected in ERC20 balances;
- NFT position identifiers such as Uniswap V3 LP token IDs;
- Morpho internal share values when a later call requires the exact share count;
- off-chain signed aggregator routes and cross-chain execution;
- native ETH dynamic patching in v1.

## Design Values

- Minimize delegated code power and line count.
- Keep protocol knowledge off-chain unless a read-only assertion requires it.
- Prefer explicit semantics over inference.
- Preserve exact upstream static behavior.
- Use immutable deployments instead of upgradeability.
- Treat self-deployment as a first-class, code-hash-verified path.
- Make failures attributable to a call and patch index.
- Treat simulation as required UX, not as an on-chain security boundary.
- Publish limitations as prominently as capabilities.

## Success Definition

The first credible release is not measured by protocol count. It is complete
when the repository can demonstrate, on a supported fork:

1. the same static batch succeeds through upstream and custom accounts;
2. protocols observe the EOA as caller;
3. checkpoint deltas preserve pre-existing inventory;
4. a multi-step Aave and Uniswap leverage flow uses actual intermediate amounts;
5. a failing final assertion reverts all protocol and token changes;
6. unauthorized, reentrant, malformed-offset, and missing-checkpoint attempts
   fail with tested errors;
7. source, compiler settings, deployment addresses, and code hashes are
   reproducible.
