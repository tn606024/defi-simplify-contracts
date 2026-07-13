# AGENTS.md

This file defines the working rules for agents modifying
`defi-simplify-contracts`. It is a routing and safety checklist, not a replacement
for the normative documents under `docs/`.

## Source of truth

Read the relevant documents before implementing or reviewing contract behavior:

1. `docs/SPECIFICATION.md` — normative Solidity behavior, ABI, errors, and tests.
2. `docs/SECURITY.md` — threat model, invariants, non-guarantees, and release gates.
3. `docs/ARCHITECTURE.md` — component boundaries and design rationale.
4. `docs/ROADMAP.md` — implementation order and exit criteria.
5. `docs/VISION.md` — product intent and deliberately unsupported capabilities.

English is normative. The `*.zh-TW.md` files are complete companion documents.
When behavior changes, update the English and Traditional Chinese documents in
the same change. If they disagree, follow English until both are reconciled.

Do not infer new contract behavior from this file when the specification is more
precise. If a Linear issue conflicts with the normative specification, stop and
surface the conflict before coding.

## Confirmed v1 scope

- Target Base only. Do not add multi-chain deployment logic unless a later issue
  explicitly expands scope.
- Pin `eth-infinitism/account-abstraction` v0.9.0 to an exact commit. Never build
  production artifacts from `develop`, another moving branch, or an unpinned tag.
- Use the canonical v0.9 EntryPoint address and verify its Base runtime code hash.
- Build with the repository-pinned Foundry and Solidity settings. Do not change
  compiler, EVM target, optimizer, `via_ir`, metadata, or dependency revisions
  casually: they affect bytecode, CREATE2 addresses, manifests, and audits.
- Prove Aave-related strategies first. A swap venue may be used as infrastructure
  for an Aave strategy, but v1 does not claim general router support.
- Keep Morpho, Pendle, Curve, ERC4626, other chains, callbacks, and flash loans out
  of v1 unless their dedicated scope is approved.

## Repository and issue discipline

- Work from the active Linear issue and stay inside its acceptance criteria.
- Respect issue dependencies. Do not silently implement behavior assigned to a
  later ticket merely because a placeholder file exists.
- The initial contracts and interfaces may be non-deployable compilation
  scaffolds. Replace them only in the issue that owns the corresponding ABI and
  behavior.
- Preserve unrelated user changes and existing documentation.
- Do not commit `out/`, `cache/`, `broadcast/`, secrets, RPC URLs, private keys,
  local traces, or explorer API keys.
- Commit deterministic ABI/golden fixtures and `.gas-snapshot` when a ticket
  requires them.

## Contract architecture boundaries

The on-chain surface is intentionally small:

```text
Simple7702Account (pinned upstream v0.9.0)
  └── DefiSimplify7702Account
        ├── inherited static execute / executeBatch
        └── executeBatchDynamic

FlowAssertions
  └── independent, permissionless post-condition checker
```

### DefiSimplify7702Account

- Inherit the pinned upstream `Simple7702Account`; do not copy or modify upstream
  source.
- Preserve inherited static execution, ERC-4337, ERC-1271, ERC-165, receiver,
  fallback, receive, and failure-wrapping behavior.
- Add only the generic checkpoint-based dynamic execution primitive specified in
  the docs. Protocol routing and protocol address knowledge belong in the Go SDK.
- Use EVM `CALL`, never `DELEGATECALL`, for dynamic targets.
- Discard successful target return data in v1 and preserve complete revert data
  in `DynamicCallFailed`.

### FlowAssertions

- Keep it independent from the account and callable from static or dynamic
  batches.
- Bind typed balance and Aave assertions to `msg.sender`; do not accept an
  arbitrary account argument.
- Keep protocol knowledge read-only and narrowly scoped. The Aave health-factor
  assertion trusts the supplied Pool and its oracle/accounting view.
- Treat generic uint256 account binding as an adapter guardrail, not an
  authorization boundary. Genuine global reads must use the explicit
  `type(uint32).max` sentinel.

### Go SDK boundary

The contracts do not construct protocol calldata, find routes, quote prices,
manage keys, schedule execution, maintain protocol registries, or decide whether
a strategy is profitable. Structured ABI encoding, patch-offset derivation,
simulation, manifest verification, authorization construction, and human-readable
error decoding belong in `tn606024/defi-simplify`.

## Non-negotiable security rules

- No proxy, upgrade path, owner, admin, role, withdrawal function, protocol
  registry, allowlist, session key, relayer authorization, secondary signature
  scheme, or custom nonce system.
- No custom permanent storage variables. Constants and immutables are allowed.
  Runtime locks, account checkpoints, and assertion snapshots use EIP-1153
  transient storage with explicit domain-separated keys.
- Every custom execution entrypoint calls inherited `_requireForExecute()` before
  reading or changing execution state.
- Dynamic execution uses a transient reentrancy lock and rejects zero targets and
  `target == address(this)`.
- Account checkpoints are isolated per `executeBatchDynamic` invocation.
  Assertion snapshots are scoped to `(transaction, msg.sender)` and may be reused
  by multiple assertions in that transaction.
- Store transient presence, token, and value separately. Never encode presence as
  `balance + 1`.
- Read ERC20 balances with checked low-level `STATICCALL balanceOf(address(this))`
  in the account and `balanceOf(msg.sender)` in assertions. Reject failed or short
  return data.
- Named checkpoints are created inside the flow immediately before producer
  calls. A single flow-start balance snapshot is not an acceptable substitute.
- `CheckpointDelta` never includes inventory held before its checkpoint. Missing,
  mismatched, duplicate, or negative deltas must revert; never clamp underflow to
  zero.
- A patch may replace exactly one validated ABI-aligned 32-byte calldata word.
  Offsets include the 4-byte selector, must be in bounds, and must be strictly
  increasing within a call.
- Validate `1 <= bps <= 10_000` and calculate
  `floor(base * bps / 10_000)` with full-precision `mulDiv`.
- Resolve patches before creating the same call's checkpoints; patches may only
  consume checkpoints from earlier calls.
- Do not interpret `msg.value` as a batch spending budget. Each declared call
  value is paid from the delegated account balance.
- Use indexed custom errors and preserve enough context for the SDK to attribute
  call, checkpoint, patch, target, selector, offset, actual value, and bound.
- Neither v1 contract emits custom execution or assertion events.

## Security claims and non-guarantees

Use precise language in code comments, docs, PRs, and release notes:

- A failed call/assertion atomically reverts execution-time protocol and asset
  state changes.
- Gas and nonce are consumed.
- On a first EIP-7702 transaction, a processed delegation may remain installed
  even when the execution portion reverts.
- Simulation improves UX but is not an on-chain safety proof. Critical economic
  limits still require protocol-native slippage/deadline controls and final
  assertions.
- Runtime code-hash matching alone does not prove a target is not a proxy. Official
  manifests must tie hashes to reproducible direct immutable artifacts.
- v1 does not support universal EIP-7702 authorization with `chain_id == 0`; the
  Go SDK must reject it.

## Required implementation order

Unless the active issue says otherwise, preserve this dependency sequence:

1. Reproducible repo and pinned toolchain.
2. Exact upstream dependency and EntryPoint freeze.
3. Minimal inherited static account and differential tests.
4. Dynamic interface, transient checkpoint engine, patching, call execution, and
   adversarial coverage.
5. FlowAssertions balance, Aave, and generic uint256 assertions.
6. Base static and guarded dynamic Aave fork proofs.
7. Security hardening and independent review preparation.
8. Reproducible direct CREATE2 deployment and official Base manifest.

Deployment scripts/manifests belong near the end, after ABI, bytecode, compiler
settings, and security fixes are frozen.

## Testing expectations

Every behavior change includes proportional tests. At minimum, run:

```sh
export PATH="$HOME/.foundry/bin:$PATH"
./script/check-foundry-version.sh
forge fmt --check
forge build --sizes
forge test --no-match-path 'test/fork/**'
forge snapshot --check --no-match-test 'testFuzz' --no-match-path 'test/fork/**'
forge coverage --no-match-path 'test/fork/**' --report summary
./script/check-reproducible-build.sh
```

Also run the test class relevant to the issue:

- unit and indexed error-path tests for each new rule;
- fuzz/property tests for patch byte isolation and full-precision amount math;
- stateful invariants for transient isolation, stale checkpoints, locks, reverts,
  and malicious callbacks;
- differential tests against pinned upstream static behavior;
- Base fork tests for claimed Aave compatibility and forced safety failures;
- Go/Solidity byte-for-byte golden vectors whenever calldata offsets or error ABI
  cross the repository boundary;
- Slither with findings manually reviewed rather than blindly suppressed.

RPC-dependent Base tests are separate from default CI and require `BASE_RPC_URL`.
Use a pinned or documented fork block where reproducibility matters. Never weaken
validation solely to reduce gas or make a test pass.

## Definition of done

Before marking a Linear issue complete:

- all acceptance criteria are implemented;
- normative docs and both languages remain consistent;
- relevant unit/fuzz/invariant/differential/fork tests pass;
- ABI, errors, golden fixtures, and gas snapshot are updated when applicable;
- build-affecting changes and dependency revisions are explicit;
- no new permanent storage, admin, proxy, event, or protocol-routing surface was
  introduced accidentally;
- PR description states scope, security impact, validation, limitations, and
  unresolved assumptions;
- release/deployment claims are not made before their roadmap gates pass.
