# Invariant tests

`DynamicEngineInvariant.t.sol` is the canonical stateful campaign for the
checkpoint-based dynamic executor. Its handler is the delegated account's
configured mock EntryPoint, so every generated action enters the production
authorization path while executing through a real EIP-7702 delegated EOA.

The campaign covers:

- current-balance and checkpoint-delta amount resolution;
- arbitrary starting inventory and checkpoint identifiers;
- same-ID reuse across sequential invocations;
- stale-scope lookup rejection;
- duplicate-ID, negative-delta, target-revert, counter, and record rollback;
- exact atomic rollback against a persistent target-state model; and
- preservation of the installed delegation target.

Expected protocol and validation failures are captured inside the handler and
compared byte-for-byte with their indexed custom errors. A handler-level revert
therefore represents an unexpected failure and remains fatal under
`fail_on_revert = true`.

## Campaign profiles

| Profile | Runs | Depth | Maximum generated actions per invariant |
| --- | ---: | ---: | ---: |
| `default` | 256 | 128 | 32,768 |
| `ci` | 512 | 256 | 131,072 |

Run the local campaign with:

```sh
forge test --match-path 'test/invariant/**/*.t.sol' -vvv
```

Run the CI-depth campaign with:

```sh
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariant/**/*.t.sol' -vvv
```

Forge prints the failing sequence and fuzz seed when it finds a counterexample.
Reproduce that exact campaign by passing the printed seed:

```sh
forge test \
  --match-path 'test/invariant/**/*.t.sol' \
  --fuzz-seed 0x<reported-seed> \
  -vvvv
```

Do not commit files under `cache/invariant/failures/`; they are local shrinking
artifacts. Convert every confirmed counterexample into a deterministic
regression test before fixing the implementation.
