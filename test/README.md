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
Use the fixture's `_upstreamAccount(pair)`, `_customAccount(pair)`, and
`_dynamicAccount(pair)` accessors instead of repeating delegated-address casts
or defining suite-local wrappers.

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

The DSC-51 local suite contained 130 non-fork tests. The production account
retained 100% line, statement, branch, and function coverage. Its reproducible
repository artifact tree was
`9bb6a848a89b356c8e8d42cc0943da2ca723a373240d24f22c3b731a049561e9`;
DSC-51 changes test artifacts only.

## DSC-53 balance assertions

`unit/FlowAssertions.t.sol` proves caller-scoped transaction-lifetime snapshots,
duplicate and cross-sender identity, reusable snapshots, validation order,
saturating increase/decrease semantics, malformed ERC20 handling, and the
zero-event policy. A dedicated setup-to-test boundary case proves transient
records do not survive the top-level transaction.

`integration/FlowAssertionsBatchIntegration.t.sol` appends the real checker to
inherited static and custom dynamic delegated-account batches. Its failure cases
prove the final assertion atomically rolls back earlier token changes and
snapshot writes. `integration/TransientNamespaceSeparation.t.sol` keeps the
account and assertion namespace and record-layout checks at the cross-component
boundary rather than mixing them into either contract's unit suite.
`fuzz/FlowAssertionsFuzz.t.sol` checks all three unsigned threshold relations
against independent arithmetic models.

The completed DSC-53 suite contains 164 non-fork tests. Both production
contracts retain 100% line, statement, branch, and function coverage. The
reproducible artifact tree is
`44d9c6c37cac58e8d82c8e24f59defcfed48384cb6b59b69c7bd03ac73d6700c`.
Dependency-inclusive Slither reports 60 findings for review; six remain after
filtering pinned libraries, with zero project-owned high-severity findings. The
two new findings are the intentional checked low-level ERC20 `STATICCALL` and
the reviewed assembly word read in `FlowAssertions._readBalance`.

Run the focused DSC-53 suites with:

```sh
forge test --match-path 'test/unit/FlowAssertions*.t.sol' -vvv
forge test --match-path 'test/fuzz/FlowAssertionsFuzz.t.sol' -vvv
forge test --match-path 'test/integration/**/*.t.sol' -vvv
```

## DSC-76 shared transient token-balance records

`src/libraries/TransientTokenBalanceRecord.sol` is the canonical production
accessor for the shared physical record shape used by account checkpoints and
assertion snapshots: presence at offset zero, token at offset one, and balance
at offset two. The internal-only library is compiler-inlined and introduces no
creation-time or runtime link references. Each consumer continues to own its
record-root derivation, scope, lifecycle, validation order, balance reads, and
custom errors.

`unit/TransientTokenBalanceRecord.t.sol` independently verifies the three slot
offsets through raw transient reads, distinguishes a present zero balance from
an absent record, and checks adjacent-slot and independent-root isolation. The
existing account, assertion, integration, golden-vector, fuzz, and invariant
suites remain the behavioral regression gates for both consumers.

The completed DSC-76 suite contains 168 non-fork tests. Both production
contracts and the shared library retain 100% line, statement, and function
coverage; both production contracts retain 100% branch coverage. The public ABI
fixtures are unchanged. Runtime size increases by two bytes for each production
contract because the shared internal accessor is inlined: the account is 5,398
bytes and `FlowAssertions` is 1,234 bytes. The reproducible artifact tree is
`87655d1f2d69122b9b069bf2c6fa6537b0d5cc9e671957f42a32329a9509479e`.

Run the focused DSC-76 suite with:

```sh
forge test --match-path 'test/unit/TransientTokenBalanceRecord.t.sol' -vvv
```

## DSC-55 Aave V3 health-factor assertion

`FlowAssertions.assertAaveV3HealthFactorAtLeast` is deliberately versioned and
implemented directly on the immutable checker. It low-level `STATICCALL`s the
supplied Aave V3-compatible Pool with `getUserAccountData(msg.sender)`, requires
the complete six-word static return tuple, and reads only the sixth word as the
health factor. Failed calls and short successful responses preserve their
complete returned bytes. The checker trusts the supplied Pool and its
oracle/accounting view; the SDK remains responsible for target verification.

`unit/FlowAssertionsAaveV3.t.sol` covers equality and threshold failure,
zero/no-position values, caller binding, full revert-data preservation,
malformed and no-code targets, the fake-Pool trust assumption, and the no-event
policy. `integration/FlowAssertionsAaveV3BatchIntegration.t.sol` proves success
at the end of inherited static and custom dynamic batches and proves a failed
final health-factor assertion rolls back earlier token state in both paths.

`fork/BaseAaveV3FlowAssertions.t.sol` uses Base block `48,961,870` and the
official Aave V3 Base Pool
`0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`. It verifies the Pool's canonical
maximum no-position health factor for a suite-specific delegated EOA and checks
that exact value through an inherited static batch.

The DSC-55 suite contains 182 non-fork tests plus the pinned Base fork test.
Both production contracts retain 100% line, statement, branch, and function
coverage. `FlowAssertions` runtime size is 1,445 bytes, an increase of 211
bytes; the account remains 5,398 bytes and byte-for-byte unchanged. The new
FlowAssertions runtime code hash is
`0x9c5201f0b2f068db3ec15ce42b72500c17eeae9e4470a0df469d699a0ccf43fd`.
The reproducible artifact tree is
`d3751dd891e7ce3e4b6d9585e80d5fd52670a24083535752d71a7479000c0337`.

Run the focused DSC-55 suites with:

```sh
forge test --match-path 'test/unit/FlowAssertionsAaveV3.t.sol' -vvv
forge test --match-path 'test/integration/FlowAssertionsAaveV3BatchIntegration.t.sol' -vvv
forge test --match-path 'test/fork/BaseAaveV3FlowAssertions.t.sol' --fork-url "$BASE_RPC_URL" -vvv
```

## DSC-54 independent generic uint256 staticcall checker

`StaticCallUint256Assertions` is deployed and reviewed independently from the
typed `FlowAssertions` checker. It supports an account-binding mode that
replaces exactly one selector-relative ABI word with `msg.sender`, and an
explicit `type(uint32).max` global-read mode that leaves calldata unchanged.
Both paths select one aligned fixed-width returndata word and apply either a
minimum or maximum uint256 bound.

`unit/StaticCallUint256Assertions.t.sol` covers validation order, account-word
byte isolation, subject-change evidence, both comparison directions, adjacent
return sentinels, malformed return data, complete target revert data, the
documented trailing-padding bypass, direct immutable identity, and the no-event
policy. `fuzz/StaticCallUint256AssertionsFuzz.t.sol` checks offset models,
unsigned comparisons, and independently reconstructed patched calldata across
512 default cases per property. The language-neutral
`abi/StaticCallUint256Assertions.golden.json` and checked-in interface ABI are
verified from Solidity for SDK consumption.

`integration/StaticCallUint256AssertionsBatchIntegration.t.sol` runs the
checker through real delegated EOAs as the final inherited static and custom
dynamic batch step. Forced failures prove that earlier token changes roll back
atomically. `fork/BaseStaticCallUint256Assertions.t.sol` uses Base block
`48,961,870`, account-binds the real Aave V3 Base Pool health-factor read, and
uses the global sentinel for Base WETH `totalSupply()`.

The DSC-54 suite brings the repository to 210 non-fork tests. All three
production contracts retain 100% line, statement, branch, and function
coverage. The independent checker runtime is 1,082 bytes with runtime code hash
`0xc26f9f8ce08cbeb069a32ac005b6a6c26dd878cb085295381f52e8de0f7e10d8`.
The reproducible artifact tree is
`de7c07913cacf335f8b0d386c110d8ffa5ae96f9629f1c20edfa0ccb00d4da60`.
The tracked `FlowAssertions` source, interface, and ABI fixture remain
byte-for-byte unchanged.

Run the focused DSC-54 suites with:

```sh
forge test --match-path 'test/unit/StaticCallUint256Assertions*.t.sol' -vvv
forge test --match-path 'test/fuzz/StaticCallUint256AssertionsFuzz.t.sol' -vvv
forge test --match-path 'test/integration/StaticCallUint256AssertionsBatchIntegration.t.sol' -vvv
forge test --match-path 'test/fork/BaseStaticCallUint256Assertions.t.sol' --fork-url "$BASE_RPC_URL" -vvv
```

### Validation commands

Run the focused verification layers with:

```sh
forge test --match-path 'test/fuzz/**/*.t.sol' -vvv
FOUNDRY_PROFILE=ci forge test --match-path 'test/fuzz/**/*.t.sol' -vvv
forge test --match-path 'test/integration/**/*.t.sol' -vvv
FOUNDRY_PROFILE=ci forge test --match-path 'test/integration/**/*.t.sol' -vvv
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
