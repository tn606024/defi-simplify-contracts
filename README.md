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

Install the pinned Foundry release, then run:

```sh
./script/check-foundry-version.sh
forge fmt --check
forge build
forge test
forge snapshot --check --no-match-test 'testFuzz'
forge coverage --report summary
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
