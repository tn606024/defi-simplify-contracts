# defi-simplify-contracts Documentation

Status: implementation source of truth
Date: 2026-07-15

This directory contains the normative design, security, and implementation
sequence for `defi-simplify-contracts`.

English is the normative language for contract behavior. Traditional Chinese
files are maintained as complete companion documents. If translations differ,
the English specification wins until both files are reconciled.

## Reference Sources

This documentation seed is derived from the product and SDK work in
[tn606024/defi-simplify](https://github.com/tn606024/defi-simplify).

The static account path and custom account inheritance model use
eth-infinitism account-abstraction v0.9.0 at full commit
`b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`. ADR-001 records the dependency,
Base EntryPoint, compiler compatibility, audit evidence, licenses, and update
rule.

## Documents

- `VISION.md` / `VISION.zh-TW.md`: product purpose, scope, and long-term outlook.
- `ARCHITECTURE.md` / `ARCHITECTURE.zh-TW.md`: component boundaries and design decisions.
- `SPECIFICATION.md` / `SPECIFICATION.zh-TW.md`: normative Solidity behavior and ABI.
- `SECURITY.md` / `SECURITY.zh-TW.md`: threat model, invariants, and audit requirements.
- `ROADMAP.md` / `ROADMAP.zh-TW.md`: implementation order and release gates.
- `adr/ADR-001-account-abstraction-v0.9.0.md` and its `zh-TW` companion:
  upstream dependency and Base EntryPoint decision.
- `adr/ADR-002-function-local-account-checkpoints.md` and its `zh-TW`
  companion: account checkpoint memory lifecycle and transient-lock boundary.

## Decision Summary

The architecture is viable with the following requirements:

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
5. Account checkpoints are function-local memory and invocation-isolated;
   execution locks and assertion snapshots remain transient because they must
   cross call frames. Neither v1 contract emits custom events.
6. Balance-read failures carry complete call/checkpoint or call/patch indices.
   Same-call caching attributes a failure to the first logical consumer that
   triggered the read.

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
