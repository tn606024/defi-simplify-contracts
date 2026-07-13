# Roadmap

Status: implementation sequence
Date: 2026-07-12

## Phase 0: Repository and Dependency Freeze

Deliverables:

- initialize Foundry repository, CI, formatting, linting, coverage, and gas snapshots;
- add English and Traditional Chinese documentation;
- pin account-abstraction release and full commit;
- record license obligations;
- select and verify EntryPoint version;
- pin Foundry's default Arachnid factory
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`, its runtime code hash, and the
  salt policy;
- add deployment manifest schema;
- define official, verified self-deployed, and user-trusted custom manifest
  trust levels;
- create ADR-001 for the upstream version and audit evidence.

Exit gate:

- reproducible build of unmodified upstream `Simple7702Account`;
- fork test proving direct delegated static batch execution;
- for every target chain, verification that the pinned factory code already
  exists or its canonical deployment transaction is accepted;
- explicit address-family classification for chains that require Safe
  Singleton Factory or another maintained alternative;
- deployment scripts and address prediction use the same factory as the
  manifest and Foundry tooling configuration.

## Phase 1: Static Compatibility Baseline

Deliverables:

- minimal inherited `DefiSimplify7702Account` with no dynamic function yet;
- differential tests of `execute`, `executeBatch`, ERC-1271, receiver interfaces,
  and failure wrapping;
- EIP-7702 self-call and EntryPoint authorization tests;
- Base fork test for approve, Aave supply, and borrow;
- proof that Aave observes the user EOA, not Multicall;
- deployment and runtime code-hash tooling.

Exit gate: custom account is a verified static superset with no behavior drift.

## Phase 2: Dynamic Checkpoint Engine

Deliverables:

- `IDefiSimplify7702Account` ABI freeze;
- `executeBatchDynamic` implementation;
- checkpoint presence, token, value, and domain separation;
- transient invocation isolation without requiring a checkpoint cleanup list;
- current-balance and checkpoint-delta patch sources;
- full-precision bps math;
- indexed custom errors and nested revert preservation;
- reentrancy lock and self-target rejection;
- unit, fuzz, invariant, adversarial, and gas tests;
- Solidity-side golden vectors exported for the Go SDK.

Critical exit tests:

- existing WETH is spent before swap output is received, and only swap output is
  consumed by the next call;
- multiple checkpoints for one token remain independent;
- Go-generated offsets patch exactly one intended ABI word;
- malformed ERC20, offsets, source, bps, and checkpoint references revert.

## Phase 3: FlowAssertions v1

Deliverables:

- `IFlowAssertions` ABI freeze;
- balance snapshot and three balance assertions;
- Aave health-factor assertion;
- generic staticcall `uint256` at-least and at-most assertions with explicit
  bound and global modes;
- custom-error ABI and SDK decode fixtures;
- transaction-scoped assertion snapshot ID namespacing;
- explicit no-custom-events policy tests;
- padding-bypass documentation tests proving account binding is a guardrail,
  plus sanctioned global-read sentinel tests;
- static and dynamic batch integration tests;
- forced final-assertion failure proving total rollback.

Exit gate: assertions work identically when appended to upstream static batches
and custom dynamic batches.

## Phase 4: Protocol Proofs

Protocol claims are earned by end-to-end fork tests, not by theoretical ABI
compatibility.

Order:

1. ERC20, WETH, Aave V3, and Uniswap exact-input single.
2. Lido wstETH wrapper and flagship E-Mode loop through a DEX WETH-to-wstETH
   swap route. Direct WETH unwrap plus Lido `submit{value: ...}` is deferred
   with native ETH value patching.
3. Morpho Blue lending and Aave-to-Morpho migration.
4. Pendle PT buy, sell, redeem, and rollover legs.
5. Selected Curve stable exchange and ERC4626 adapters.

Every protocol addition requires:

- one newly unlocked flow;
- a successful fork test;
- a forced safety failure test;
- an ABI offset golden fixture where dynamic patching is used;
- documented token, router, deadline, slippage, and receiver assumptions.

## Phase 5: Release Hardening

Deliverables:

- Slither and reviewed findings;
- maximum practical branch and error-path coverage;
- invariant campaign report and gas report;
- reproducible deployment dry run on supported chains;
- deterministic CREATE2, per-chain factory availability, address-family, and
  self-deployment manifest reproduction;
- independent security review;
- fixes followed by regression and differential tests;
- verified immutable deployment;
- signed or reviewed deployment manifest;
- `v1.0.0` ABI and source tag;
- SDK integration pinned to address and runtime code hash.

The first production release remains labeled high risk until an independent
audit and meaningful real-world usage exist.

## Future Version: Callback Account

Flash loans, direct Uniswap callbacks, and one-shot migrations belong to a new
contract version. Design work begins only after v1 has stable fork coverage and
small real transactions.

The future design must include:

- active flow hash or commitment;
- authenticated callback initiator and protocol;
- callback type and expected asset validation;
- single-use callback state;
- repayment assertion;
- reentrancy interaction analysis;
- a separate audit boundary.

It must not silently change v1 implementation behavior. Users opt in by
delegating to a new immutable address.

## Deferred Capability Levels

- Return-data patching for non-ERC20 values.
- NFT position IDs and Uniswap V3 LP management.
- Morpho internal-share value piping.
- Policy/session-key modules.
- ERC-7579 adapter.
- Native ETH dynamic source.
- Off-chain aggregator quotes.
- Cross-chain flow coordination.

Each item requires a demonstrated flow that cannot be represented safely by
v1. Protocol count alone is not sufficient justification.
