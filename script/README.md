# Scripts

- `check-foundry-version.sh` rejects an unpinned local Foundry toolchain.
- `check-account-abstraction-revision.sh` verifies the account-abstraction and
  OpenZeppelin submodule checkouts, committed gitlinks, and clean upstream
  working trees against `config/account-abstraction-v0.9.0.json`.
- `check-reproducible-build.sh` performs two clean builds and compares the
  SHA-256 digest of every generated JSON artifact.

Deployment scripts are added only after the account and assertion ABIs freeze.
