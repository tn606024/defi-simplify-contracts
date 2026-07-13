# defi-simplify-contracts

Minimal EIP-7702 execution primitives for the `defi-simplify` Go SDK.

The v1 implementation targets Base, inherits the pinned account-abstraction
v0.9.0 `Simple7702Account`, adds checkpoint-based ERC20 amount patching, and
provides independent post-condition assertions. Contract behavior is specified
in [`docs/SPECIFICATION.md`](docs/SPECIFICATION.md); the English documents are
normative when translations differ.

## Pinned bootstrap toolchain

- Foundry: `v1.7.1`
- Solidity: `0.8.28`
- EVM: `prague`
- optimizer: enabled, 200 runs
- IR pipeline: enabled

## Pinned account-abstraction baseline

- account-abstraction: v0.9.0,
  `b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`
- OpenZeppelin Contracts: v5.1.0,
  `69c8def5f222ff96f2b5beff05dfba996368aa79`
- Base EntryPoint v0.9.0: `0x433709009B8330FDa32311DF1C2AFA402eD8D009`
- Base EntryPoint runtime code hash:
  `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`

Initialize submodules and verify the dependency lock before building:

```sh
git submodule update --init
./script/check-account-abstraction-revision.sh
```

See `docs/adr/ADR-001-account-abstraction-v0.9.0.md` for compiler, audit,
license, inherited-risk, and update decisions. This project does not claim the
v0.9.0 baseline is audited.

Install the pinned Foundry release, then run:

```sh
./script/check-foundry-version.sh
./script/check-account-abstraction-revision.sh
forge fmt --check
forge build
forge test --no-match-path 'test/fork/**'
forge snapshot --check --no-match-test 'testFuzz' --no-match-path 'test/fork/**'
forge coverage --no-match-path 'test/fork/**' --report summary
./script/check-reproducible-build.sh
```

Base fork tests are intentionally separate from the default suite and require
`BASE_RPC_URL`:

```sh
forge test --match-path 'test/fork/**/*.t.sol' --fork-url "$BASE_RPC_URL"
```

Generated build output and RPC credentials are ignored. `.gas-snapshot`, source
documents, deployment manifests, compiler configuration, and dependency locks
are expected to be committed.
