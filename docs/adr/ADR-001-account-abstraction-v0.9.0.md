# ADR-001: Pin account-abstraction v0.9.0 and Base EntryPoint

Status: accepted
Date: 2026-07-13
Linear issue: IAN-44

## Context

`DefiSimplify7702Account` will inherit upstream `Simple7702Account`. The
dependency controls the account's authorization, ERC-4337 validation,
signature checks, static execution, receiver interfaces, fallback behavior,
and immutable EntryPoint. A moving dependency or an unverified EntryPoint would
therefore change the security boundary and final bytecode without an explicit
project decision.

## Decision

### Upstream revision and lock

The canonical upstream dependency is:

- repository: `https://github.com/eth-infinitism/account-abstraction.git`;
- release: `v0.9.0`;
- full commit: `b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`;
- local path: `lib/account-abstraction` as an unmodified Git submodule.

The upstream lock resolves `@openzeppelin/contracts` to v5.1.0. This repository
pins that transitive Solidity dependency separately at commit
`69c8def5f222ff96f2b5beff05dfba996368aa79` in
`lib/openzeppelin-contracts`.

`config/account-abstraction-v0.9.0.json` is the machine-readable lock and Base
identity record. `script/check-account-abstraction-revision.sh` fails when a
submodule checkout, committed gitlink, or upstream working tree differs from
the lock. CI runs this check before compilation.

The custom account must inherit upstream source through the configured
remapping. It must not copy, patch, or vendor modified versions of
`Simple7702Account`, `BaseAccount`, their interfaces, or receiver behavior.

### Compiler compatibility

Upstream v0.9.0 uses Solidity `0.8.28`. Its published EntryPoint build settings
are Cancun, via-IR, optimizer enabled, and 1,000,000 optimizer runs. BaseScan
reports an exact source match for the Base deployment with Solidity
`0.8.28+commit.7893614a`, Cancun, and 1,000,000 optimizer runs.

This repository compiles the unmodified upstream `EntryPoint`,
`Simple7702Account`, `BaseAccount`, inherited interfaces, ERC-1271, ERC-165,
ERC-721/ERC-1155 receivers, fallback, and receive behavior using the repository
toolchain: Solidity 0.8.28, Prague, via-IR, and 200 optimizer runs. This proves
source compatibility; it does not claim that the locally compiled EntryPoint
artifact is byte-identical to the upstream deployment, because the build
settings intentionally differ.

The final custom account bytecode will use the repository settings. Changing
either the upstream revision or repository compiler settings requires a new
artifact identity and review.

### Base EntryPoint identity

Base mainnet is the only v1 target:

- chain ID: `8453`;
- EntryPoint version: `v0.9.0`;
- address: `0x433709009B8330FDa32311DF1C2AFA402eD8D009`;
- runtime code hash:
  `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`;
- EntryPoint constructor arguments: none;
- `Simple7702Account` constructor argument: the immutable `IEntryPoint` above;
- verification: BaseScan exact-match source at the address above.

The expected runtime hash was computed from Base RPC bytecode on 2026-07-13 and
is checked by `test/fork/BaseEntryPoint.t.sol`. The test requires Base chain ID,
non-empty code, and the exact runtime hash. This record does not define the
later account/assertion deployment manifest schema.

### Release and audit evidence

The v0.9.0 release adds EntryPoint behavior including paymaster signatures,
block-number validity ranges, ignoring non-empty `initCode` after an account
already exists, execution-time UserOperation hash access, and EIP-7702
initialization observability. Bundlers must explicitly support v0.9 behavior.
Account code must not assume that non-empty `initCode` proves first use.

No evidence was found that permits this project to claim the v0.9.0 tag or its
EntryPoint deployment was audited. The newest report committed in the v0.9.0
tag is the March 2025 Spearbit review. It identifies account-abstraction review
commit `ed8a5c79` and final review commit `57f9a8d7`; the v0.9 implementation was
introduced later by `f54584e`. BaseScan also shows no submitted security audit
for the v0.9 EntryPoint address.

The upstream v0.8.0 release described `Simple7702Account` as audited. That
statement is not extended to v0.9.0 or to this project's combined inherited and
custom bytecode. Until new evidence and an independent review exist, both the
v0.9 baseline and the custom account are treated as unaudited by this project.

### License obligations

The upstream repository carries a GPL-3.0 root license, while individual
Solidity files use their own SPDX identifiers. At this revision,
`Simple7702Account.sol`, `BaseAccount.sol`, `IEntryPoint.sol`, and the relevant
interfaces/utilities are MIT; `EntryPoint.sol` is GPL-3.0. OpenZeppelin
Contracts v5.1.0 is MIT.

Source SPDX notices and upstream license texts must remain intact. Any
distribution of the GPL EntryPoint source or compiled artifact must satisfy the
applicable GPL-3.0 obligations. The project must review licensing again when
the production artifact composition or distribution method changes; this ADR
is an engineering record, not legal advice.

### Known inherited risks

- `Simple7702Account` authorizes execution from itself or its immutable
  EntryPoint. A wrong EntryPoint changes an authorization boundary.
- Signature validity recovers the delegated EOA itself from the supplied hash;
  no independent owner or recovery authority exists.
- The account intentionally accepts ETH and unknown fallback calls and accepts
  ERC-721/ERC-1155 transfers. Assets sent to it depend on the delegated EOA's
  continuing ability to execute or redelegate.
- Upstream static execution and revert wrapping must remain unchanged. Later
  custom behavior can invalidate prior audit assumptions even if upstream code
  is unchanged.
- Runtime code-hash verification proves bytecode identity at the checked
  address, not the safety of EntryPoint logic or bundler behavior.

### Upgrade rule

Dependency updates are never automatic. A new upstream commit, tag,
EntryPoint address, compiler setting, or transitive Solidity dependency
requires:

1. a new or superseding ADR with release-note, diff, license, and audit review;
2. updated locks and unmodified-upstream compilation tests;
3. chain-specific EntryPoint address and runtime-hash verification;
4. full differential, fork, and security regression tests;
5. a new custom account deployment address and explicit user redelegation.

Existing deployments remain pinned to their original immutable EntryPoint and
bytecode. A dependency update must not reuse an established deployment identity.

## Consequences

The build is larger because two Git submodules are checked out, but dependency
identity is reviewable and CI-enforced. Base RPC-dependent verification remains
separate from the deterministic default test suite. IAN-45 may now implement
the minimal custom account by inheriting this exact upstream source; it may not
replace the dependency or change inherited behavior within that issue.

## References

- https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.9.0
- https://github.com/eth-infinitism/account-abstraction/tree/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410
- https://github.com/eth-infinitism/account-abstraction/blob/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410/audits/SpearBit%20Account%20Abstraction%20Security%20Review%20-%20Mar%202025.pdf
- https://basescan.org/address/0x433709009B8330FDa32311DF1C2AFA402eD8D009#code
