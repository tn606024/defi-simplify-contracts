# defi-simplify-contract Documentation Seed

Status: design approved with required corrections
Date: 2026-07-12

This directory is the documentation seed for the future
`defi-simplify-contract` repository. Copy these files to the new repository
before Solidity implementation begins.

English is the normative language for contract behavior. Traditional Chinese
files are maintained as complete companion documents. If translations differ,
the English specification wins until both files are reconciled.

## Reference Sources

This documentation seed is derived from the product and SDK work in
[tn606024/defi-simplify](https://github.com/tn606024/defi-simplify).

The Tier 1 static account path and the Tier 2 custom account inheritance model
are based on eth-infinitism account-abstraction v0.9
[`Simple7702Account.sol`](https://github.com/eth-infinitism/account-abstraction/blob/develop/contracts/accounts/Simple7702Account.sol).
The linked `develop` branch is a reading reference only; implementation MUST
pin an exact v0.9 release tag or full commit before deployment artifacts are
built.

## Documents

- `VISION.md` / `VISION.zh-TW.md`: product purpose, scope, and long-term outlook.
- `ARCHITECTURE.md` / `ARCHITECTURE.zh-TW.md`: component boundaries and design decisions.
- `SPECIFICATION.md` / `SPECIFICATION.zh-TW.md`: normative Solidity behavior and ABI.
- `SECURITY.md` / `SECURITY.zh-TW.md`: threat model, invariants, and audit requirements.
- `ROADMAP.md` / `ROADMAP.zh-TW.md`: implementation order and release gates.

## Decision Summary

The architecture is viable, with two corrections that are requirements rather
than optional refinements:

1. Balance deltas use named, in-flow checkpoints. A single snapshot at flow
   start is incorrect when the same token is spent and later received.
2. The safety promise is about atomic protocol and asset state. On a first
   EIP-7702 transaction, a processed delegation remains installed even if the
   execution portion reverts; gas and nonces are also consumed.
3. Official contracts are direct immutable CREATE2 deployments through the
   Foundry-aligned `0x4e59...956C` factory where each target chain passes the
   factory availability gate. v1 rejects universal EIP-7702 authorization with
   `chain_id == 0`.
4. Generic uint256 assertions support explicit `msg.sender` binding or an
   explicit global-read sentinel. Binding is an adapter guardrail, not an
   authorization boundary.
5. Account checkpoints are invocation-isolated, assertion snapshots are
   transaction-scoped, and neither v1 contract emits custom events.

The v1 on-chain scope remains deliberately small:

```text
Simple7702Account (pinned upstream dependency)
  └── DefiSimplify7702Account
        ├── inherited static execute / executeBatch
        └── executeBatchDynamic with checkpoint-based balance patching

FlowAssertions
  └── independent, permissionless, stateless post-condition checker
```

No protocol-specific routing belongs in the account. Aave, Uniswap, Morpho,
and Pendle knowledge remains in the Go SDK, except for narrowly scoped read-only
assertions such as Aave health-factor checks.
