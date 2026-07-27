# Scripts

- `check-foundry-version.sh` rejects an unpinned local Foundry toolchain.
- `check-account-abstraction-revision.sh` verifies the account-abstraction and
  OpenZeppelin submodule checkouts, committed gitlinks, and clean upstream
  working trees against `config/account-abstraction-v0.9.0.json`. It also
  requires `foundry.toml` and every repository-owned Solidity source under
  `src/`, `test/`, and `script/` to use the exact local compiler recorded by
  that lock.
- `check-forge-std-revision.sh` verifies the forge-std tag, checkout, committed
  gitlink, and clean working tree against `foundry.lock`.
- `check-minimal-account-surface.sh` requires the custom account ABI to be the
  exact union of pinned `Simple7702Account` and the frozen dynamic interface,
  and rejects custom permanent storage.
- `check-flow-assertions-surface.sh` requires `FlowAssertions` to expose exactly
  `IFlowAssertions` and rejects permanent storage.
- `check-static-call-uint256-assertions-surface.sh` requires the independent
  generic checker to expose exactly `IStaticCallUint256Assertions`, rejects
  permanent and transient storage access, and rejects events, payable paths,
  asset-moving calls, delegated execution, contract creation, and destruction.
- `check-direct-immutable-artifacts.sh` verifies that the account and both
  checkers are unlinked direct artifacts with no permanent storage, custom
  events, or `DELEGATECALL`/`CALLCODE` proxy runtime. It also freezes the
  account's sole immutable EntryPoint constructor input and keeps both checkers
  constructor-free.
- `check-abi-fixtures.sh` verifies both the smaller account/checker interface
  ABIs and the complete deployment ABIs remain byte-for-byte synchronized with
  Solidity.
- `generate-base-v1-candidate-manifest.sh` validates the Base deployment config
  against the dependency and effective build locks, substitutes the immutable
  EntryPoint into account runtime bytecode, and derives the three direct
  artifact hashes and CREATE2 addresses.
- `check-base-v1-candidate-manifest.sh` independently regenerates the candidate
  manifest and rejects stale output or misleading audit, deployment,
  verification, trust-level, and SDK-readiness placeholders.
- `DeployBaseV1.s.sol` verifies the live Base factory and EntryPoint, rebuilds
  every initcode and CREATE2 prediction, and idempotently deploys or verifies
  all three runtimes. It simulates unless the maintainer explicitly adds
  `--broadcast`.
- `check-reproducible-build.sh` performs two clean builds and compares the
  SHA-256 digest of every generated JSON artifact.

See `deployments/README.md` for the candidate/deployed manifest lifecycle and
the non-broadcast dry-run commands.
