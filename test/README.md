# Test fixtures

`utils/DelegatedAccountFixture.sol` is the canonical EIP-7702 fixture for unit
and Base fork tests. It deploys pinned upstream and custom implementations, then
uses forge-std's Prague `signAndAttachDelegation` cheatcode to install each
implementation on a real test EOA.

Calls made through the returned EOA addresses execute with the required account
context: `address(this)` is the EOA and inherited self-or-EntryPoint
authorization observes that EOA. Direct calls to an implementation contract and
`vm.etch` do not model delegation processing and must not replace this fixture
for authorization, signature, receiver, fallback, or protocol-accounting tests.

The static differential suite in `unit/UpstreamCompatibility.t.sol` intentionally
runs semantically identical operations through both delegated EOAs. Keep that
suite unchanged as a regression gate when dynamic execution is introduced; add
new cases only when the inherited upstream surface or a documented static
invariant expands.

`mocks/CheckpointBalanceToken.sol` includes the test-only delegated checkpoint
harness. Its authorization-protected inspectors verify transient slot layout,
invocation isolation, rollback, and lookup cost without adding a getter to the
production account ABI. `unit/CheckpointEntryPointBundle.t.sol` uses the real
pinned EntryPoint source to prove that multiple same-account UserOperations in
one bundle receive isolated invocation scopes.

## DSC-51 dynamic-engine verification report

DSC-51 is a verification-only change. It does not modify production contracts,
the frozen dynamic ABI, validation order, or transient layout.

Coverage added by DSC-51:

- `invariant/DynamicEngineInvariant.t.sol` executes randomized stateful action
  sequences through a real delegated EOA and the configured EntryPoint path;
- `fuzz/DynamicCalldataPatchingFuzz.t.sol` covers arbitrary inventory,
  producer output, checkpoint IDs, independent same-token checkpoints,
  sequential consumers, offset ordering, and an independent slot model;
- `fuzz/DynamicExecutionAdversarialFuzz.t.sol` preserves arbitrary bounded
  nested revert bytes and proves prior target state rolls back;
- `unit/DynamicGoldenVectors.t.sol` verifies the self-describing
  `abi/DynamicExecution.golden.json` fixture containing struct/function
  encoding, all custom errors, patch bytes, amount math, transient slots, and
  malformed cases; and
- `unit/DynamicEngineGas.t.sol` records representative integrated plans in
  `.gas-snapshot` alongside the existing 1/4/8/16/32 checkpoint matrices.

The invariant profiles and seed reproduction commands are documented in
`invariant/README.md`. The default campaign runs 256 sequences at depth 128;
the CI profile runs 512 sequences at depth 256 with `fail_on_revert = true`.
CI also executes each dynamic-engine fuzz property with 10,000 runs.

### Gas evidence

| Scenario | Test gas |
| --- | ---: |
| One-call `CurrentBalance` patch | 145,298 |
| Two-call `CheckpointDelta` producer/consumer | 153,792 |
| Three same-token cached patches | 173,550 |
| Two same-account sequential invocations | 159,242 |

The existing production checkpoint-delta matrix remains:

| Checkpoint-delta patches | Test gas |
| ---: | ---: |
| 1 | 87,528 |
| 4 | 111,515 |
| 8 | 142,287 |
| 16 | 205,941 |
| 32 | 332,893 |

The incremental cost remains approximately linear as checkpoint/patch count
grows. These figures are regression evidence for table complexity, not
protocol-flow estimates or permission to weaken validation.

The snapshot command excludes `invariant_` functions because their reported
run/call totals intentionally differ between the default and CI profiles. The
deterministic tests in the invariant suite remain in `.gas-snapshot`.

### Findings and accepted gaps

No production-contract defect was found by the added campaigns. During test
harness development, selector targeting alone allowed Forge to fuzz deployed
dependency contracts; pairing `targetContract` with `targetSelector` fixed the
campaign boundary and is retained as the canonical setup.

The dependency-inclusive Slither review reports 58 findings for manual review.
After filtering pinned libraries, four project-owned informational/low findings
remain: the intentional checked ERC20 `STATICCALL` inside the execution loop,
the two reviewed assembly blocks for calldata word replacement and returndata
decoding, and the same checked low-level balance call. The project-owned
high-severity gate reports zero high findings.

The accepted v1 returndata limitation remains unchanged: a malicious target can
return enough revert data to exhaust gas before `DynamicCallFailed` is encoded.
Bounded revert data is preserved byte-for-byte and atomic rollback remains
covered, but indexed failure attribution cannot be guaranteed under OOG.

The Solidity fixture is directly consumable as JSON by the Go repository. A
cross-repository test that imports it belongs to the SDK integration issues; no
claim is made here that the Go consumer has already shipped.

The completed local suite contains 130 non-fork tests. The production account
retains 100% line, statement, branch, and function coverage. The reproducible
repository artifact tree is
`9bb6a848a89b356c8e8d42cc0943da2ca723a373240d24f22c3b731a049561e9`;
DSC-51 changes test artifacts only.

### Validation commands

Run the focused verification layers with:

```sh
forge test --match-path 'test/fuzz/**/*.t.sol' -vvv
FOUNDRY_PROFILE=ci forge test --match-path 'test/fuzz/**/*.t.sol' -vvv
forge test --match-path 'test/invariant/**/*.t.sol' -vvv
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariant/**/*.t.sol' -vvv
forge test --match-path 'test/unit/DynamicGoldenVectors.t.sol' -vvv
forge snapshot --check --no-match-test 'testFuzz|invariant_' --no-match-path 'test/fork/**'
forge coverage --no-match-path 'test/fork/**' --report summary
./script/check-reproducible-build.sh
slither . --fail-none
slither . --filter-paths 'lib/' --fail-high
```

The repository-wide commands in the root `README.md` remain the release gate.
