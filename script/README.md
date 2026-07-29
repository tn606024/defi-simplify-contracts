# Scripts

The root `Makefile` is the canonical validation interface. Use `make check` for
the complete non-RPC suite, `make check-base` for the `BASE_RPC_URL`-dependent
suite, or `make help` to list focused targets. The scripts below remain
independently callable implementation units used by those targets.

- `check-foundry-version.sh` rejects an unpinned local Foundry toolchain.
- `check-account-abstraction-revision.sh` verifies the account-abstraction and
  OpenZeppelin submodule checkouts, committed gitlinks, and clean upstream
  working trees against `config/account-abstraction-v0.9.0.json`. It also
  requires the effective Foundry Solidity, EVM, optimizer, optimizer-run, and
  via-IR settings to match the complete local compatibility build lock, and
  every repository-owned Solidity source under `src/`, `test/`, and `script/`
  to use the locked compiler.
- `check-foundry-build-settings.sh` is the focused build-lock validator used by
  the account-abstraction revision check and its mismatch regression harness.
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
- `generate-base-v1.1-candidate-manifest.sh` validates the active artifact
  source commit and tree, dependency and build locks, versioned salts, ABI
  hashes, immutable substitution, complete initcodes, CREATE2 predictions, and
  direct runtime identities. It emits only `not-broadcast` candidate facts.
- `check-base-v1.1-candidate-manifest.sh` independently regenerates the active
  candidate and rejects stale output or any deployed, released, verified,
  assigned-trust, warranty, SDK-readiness, or security overclaim.
- `generate-base-v1.1-verification-inputs.sh` prepares one metadata-derived
  Solidity Standard JSON source closure per candidate artifact under the
  ignored `out/` tree. It does not submit those inputs to an explorer.
- `check-base-v1.1-candidate-onchain.sh` verifies the live Base chain, factory,
  and EntryPoint identities, then requires all three predicted addresses to
  remain vacant.
- `DeployBaseV1_1Candidate.s.sol` reconstructs all candidate identities and
  dry-runs the exact factory payloads. It deliberately rejects Forge broadcast
  and resume contexts until a separate approved live-deployment change.
- `generate-base-v1-manifest.sh` validates the official Base deployment config
  from the retired v1.0.0 source state. It is historical tooling and is outside
  active current-source validation.
- `generate-base-v1-verification-inputs.sh` derives one Solidity Standard JSON
  source closure per artifact. The active candidate wrapper selects a distinct
  output directory and first validates the candidate manifest.
- `check-base-v1-manifest.sh` independently regenerates the official manifest
  from the retired v1.0.0 source state and is not part of active checks.
- `check-base-v1-onchain-deployment.sh` uses `BASE_RPC_URL` to verify the live
  retired factory, EntryPoint, and artifact runtime hashes, then checks each historical
  deployment transaction's sender, factory destination, salt, complete
  initcode hash, successful receipt, and mined block against the manifest.
- `DeployBaseV1.s.sol` is retained for the retired v1.0.0 source state and is
  not an active-build deployment script.
- `check-reproducible-build.sh` performs two clean builds and compares the
  SHA-256 digest of every generated JSON artifact.

See `deployments/README.md` for the active candidate, retired addresses,
manifest semantics, and non-broadcast reproduction commands.
