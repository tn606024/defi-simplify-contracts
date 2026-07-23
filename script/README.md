# Scripts

- `check-foundry-version.sh` rejects an unpinned local Foundry toolchain.
- `check-account-abstraction-revision.sh` verifies the account-abstraction and
  OpenZeppelin submodule checkouts, committed gitlinks, and clean upstream
  working trees against `config/account-abstraction-v0.9.0.json`. It also
  requires `foundry.toml` and every repository-owned Solidity source under
  `src/` and `test/` to use the exact local compiler recorded by that lock.
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
- `check-abi-fixtures.sh` verifies the committed account, typed-assertion, and
  generic-assertion interface ABIs used by the Go SDK remain byte-for-byte
  synchronized with Solidity.
- `check-reproducible-build.sh` performs two clean builds and compares the
  SHA-256 digest of every generated JSON artifact.

Deployment scripts are added only after the account and assertion ABIs freeze.
