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
- `generate-base-v1-manifest.sh` validates the official Base deployment config
  against the dependency and effective build locks, substitutes the immutable
  EntryPoint into account runtime bytecode, derives the three direct artifact
  hashes and CREATE2 addresses, and combines them with mined transaction and
  exact source-verification evidence.
- `check-base-v1-manifest.sh` independently regenerates the official manifest
  and rejects stale output, incomplete deployment evidence, or misleading
  audit, release, trust-level, warranty, security, and SDK-readiness claims.
- `check-base-v1-onchain-deployment.sh` uses `BASE_RPC_URL` to verify the live
  factory, EntryPoint, and artifact runtime hashes, then checks each historical
  deployment transaction's sender, factory destination, salt, complete
  initcode hash, successful receipt, and mined block against the manifest.
- `DeployBaseV1.s.sol` verifies the live Base factory and EntryPoint, rebuilds
  every initcode and CREATE2 prediction, and idempotently deploys or verifies
  all three runtimes. The official addresses are already deployed, so the
  script is now an idempotent reproduction check and must not be broadcast.
- `check-reproducible-build.sh` performs two clean builds and compares the
  SHA-256 digest of every generated JSON artifact.

See `deployments/README.md` for the official addresses, transactions, source
verification, manifest semantics, and non-broadcast reproduction commands.
