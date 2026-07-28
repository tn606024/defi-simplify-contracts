# Test suite guide

This guide separates the current reviewer map from historical issue evidence.
The current non-fork suite contains 325 tests; older counts and artifact hashes
in the appendix are merge-point records, not the present baseline.

## Contents

- [Current reviewer guide](#current-reviewer-guide)
  - [Canonical fixtures and builders](#canonical-fixtures-and-builders)
  - [Final v1 suite ownership](#final-v1-suite-ownership)
  - [Reviewer-readable test vocabulary](#reviewer-readable-test-vocabulary)
  - [Callback suite navigation](#callback-suite-navigation)
  - [Focused validation](#focused-validation)
- [Historical verification appendix](#historical-verification-appendix)

## Current reviewer guide

### Canonical fixtures and builders

`utils/DelegatedAccountFixture.sol` is the canonical EIP-7702 fixture for unit
and Base fork tests. It uses forge-std's Prague
`signAndAttachDelegation` cheatcode to install the requested implementation on a
real test EOA.

Calls made through the returned EOA addresses execute with the required account
context: `address(this)` is the EOA and inherited self-or-EntryPoint
authorization observes that EOA. Direct calls to an implementation contract and
`vm.etch` do not model delegation processing and must not replace this fixture
for authorization, signature, receiver, fallback, or protocol-accounting tests.

Ordinary DeFi Simplify tests deploy one `DelegatedDefiSimplifyAccount` named
`accountUnderTest`. Tests that genuinely compare inherited behavior deploy an
`UpstreamCompatibilityFixture` named `compatibilityFixture`; it contains
separate `upstream` and `defiSimplify` delegated EOAs. Use
`_upstreamAccountView`, `_defiSimplifyAccountView`, and
`_dynamicExecutionInterfaceView` instead of repeating delegated-address casts
or defining suite-local wrappers.

The static differential suite in `unit/UpstreamCompatibility.t.sol` intentionally
runs semantically identical operations through both delegated EOAs. Keep that
suite unchanged as a regression gate when dynamic execution is introduced; add
new cases only when the inherited upstream surface or a documented static
invariant expands.

`utils/DynamicCallTestBuilder.sol` owns mechanical construction of generic
dynamic calls, empty and singleton arrays, checkpoints, and balance patches.
Protocol fixtures keep the reviewer-visible strategy order, asset roles,
callback semantics, economic bounds, and final assertions.

### Final v1 suite ownership

DSC-83 consolidates the completed v1 suite without changing production source,
public ABI, transient layout, or runtime behavior. Generic dynamic-call
allocation belongs to `utils/DynamicCallTestBuilder.sol`; protocol fixtures
continue to own strategy order, asset roles, callback behavior, economic bounds,
and post-conditions.

The same invariant may intentionally appear in more than one layer when each
layer proves a different boundary:

| Layer | Canonical responsibility |
| --- | --- |
| Unit | One contract rule, validation order, indexed error, or state transition |
| Fuzz/property | The same rule over arbitrary bounded values or byte layouts |
| Stateful invariant | Behavior across randomized sequences, rollback, and repeated invocations |
| Integration | Atomic composition of the account and independent assertion contracts |
| Differential | Compatibility with the pinned upstream static account |
| Golden vector | Exact ABI, calldata, error, slot, and Go/Solidity boundary bytes |
| Base fork | Compatibility and rollback against immutable deployed protocol code |
| Gas snapshot | Deterministic regression evidence, not a behavioral substitute |

The concrete suite families own these final-v1 properties:

| Suite family | Property ownership |
| --- | --- |
| `DefiSimplify7702Account`, `UpstreamEntryPointCompilation`, `UpstreamCompatibility` | Minimal direct deployment and differential preservation of the pinned upstream static account |
| `DynamicExecution`, `DynamicEntryPointTarget`, `BaseDynamicEntryPoint` | Authorization, final-selector ABI decoding, target policy, call/value execution, failure attribution, rollback, lock, event surface, and EntryPoint-as-target behavior |
| `CheckpointEngine`, `CheckpointEntryPointBundle`, `DynamicCalldataPatching` | Invocation-scoped checkpoint records, validation order, balance sources, exact word patching, and same-account bundle isolation |
| `DynamicCalldataPatchingFuzz`, `DynamicExecutionAdversarialFuzz`, `DynamicEngineInvariant` | Arbitrary amount/offset/revert-data properties and stateful execution/rollback models |
| `DynamicGoldenVectors`, `DynamicEngineGas`, `BalanceCacheGas`, `BalanceCacheZeroCapacity`, `CheckpointRepresentationBenchmark` | Exact cross-repository bytes/slots/errors and deterministic checkpoint/patch/cache cost evidence |
| `AaveV3FlashLoanCallback`, `CallbackCommitmentState`, `TransientExecutionComponents` | Authenticated single-use Aave callback lifecycle, origin commitment, repayment, and low-level transient component transitions |
| `AaveV3FlashLoanAdversarial`, `AaveV3FlashLoanEntryPointBundle` | Malicious callback/reentry/repayment boundaries and same-account EntryPoint bundle isolation |
| `AaveV3FlashLoanCallbackFuzz`, `AaveV3FlashLoanCallbackInvariant` | Arbitrary patched origins, callback positions, repayment allowances, and stateful callback rollback/cleanup |
| `CallbackGoldenVectors`, `AaveV3FlashLoanGas` | Exact callback ABI/errors and deterministic callback-window cost evidence |
| `FlowAssertions`, `FlowAssertionsAaveV3`, `StaticCallUint256Assertions` | Caller-bound typed balance/Aave post-conditions and independent reviewed generic uint256 reads |
| Assertion fuzz, integration, golden-vector, and Base fork suites | Arithmetic properties, account/checker atomicity, exact SDK bytes, and deployed Base compatibility |
| Base Aave static, dynamic, and flash lifecycle suites | Pinned protocol identities, complete reference strategies, economic guard failures, atomic rollback, emitted protocol evidence, and gas |
| `BaseDeploymentManifest`, `BaseV1_1CandidateManifest`, `ArtifactDeploymentGasBenchmark` | Historical v1.0.0 identity, active v1.1.0 candidate identity/limit headroom, and deployment-cost comparison |
| `TransientTokenBalanceRecord`, `TransientNamespaceSeparation` | Canonical record shape and pairwise separation of every occupied transient namespace |
| `DelegatedAccountFixture`, `DynamicCallTestBuilder`, focused protocol fixtures and mocks | Canonical test construction and controlled dependencies; these support the properties above rather than claiming production behavior themselves |

Complex strategy fixtures document their complete ordered flow where calls are
built. In particular, the static Aave lifecycle, dynamic WETH/USDC loop, and
flash-assisted leverage-open, partial-deleverage, and full-close builders state
their starting assumptions, checkpoint/patch flow, native swap bounds, repayment
steps, and final assertions.

The following transition-only coverage was retired after mapping its behavior
to the final suites:

| Retired test | Preserved evidence |
| --- | --- |
| `unit/ProjectBootstrap.t.sol` | Pinned toolchain/build scripts and every compiled production suite |
| `fuzz/ProjectBootstrapFuzz.t.sol` | Production-specific fuzz properties under `fuzz/` |
| `unit/CallbackAbi.t.sol`: ordinary callback-free batch | `unit/DynamicExecution.t.sol` ordinary one/many-call execution |
| `unit/CallbackAbi.t.sol`: two outer callback flags | `unit/AaveV3FlashLoanCallback.t.sol` prevalidation before Pool or ordinary targets |
| `unit/CallbackAbi.t.sol`: direct malformed callback | `unit/AaveV3FlashLoanAdversarial.t.sol` authorization before params decoding |
| `unit/CallbackAbi.t.sol`: zero/one/many envelope encoding | `unit/CallbackGoldenVectors.t.sol` exact encoded fixtures |
| `unit/CallbackAbi.t.sol`: tuple missing `expectsCallback` | `unit/DynamicExecution.t.sol` black-box final-selector decoding failure through a delegated EOA |

`unit/DynamicExecutionScaffold.t.sol` was renamed
`unit/DynamicExecution.t.sol` because the implementation is no longer a
scaffold. After these removals and one relocated security regression, the final
non-fork suite contains 308 tests.

`.gas-snapshot` was regenerated because the names and test-only builder
construction changed. The resulting drift is test-harness allocation/inlining
cost, including refreshed Base dynamic/flash fixture construction; no production
source or runtime bytecode changed, and the static Base flow entries are
unchanged.

Run the consolidated local baseline with:

```sh
forge test --no-match-path 'test/fork/**'
forge snapshot --check --no-match-test 'testFuzz|invariant_' --no-match-path 'test/fork/**'
```

When `BASE_RPC_URL` is available, run the protocol reference flows with:

```sh
forge test --match-path 'test/fork/BaseAaveV3*.t.sol' --fork-url "$BASE_RPC_URL"
```

`mocks/CheckpointBalanceToken.sol` includes the test-only delegated checkpoint
harness. Its authorization-protected inspectors verify transient slot layout,
invocation isolation, rollback, and lookup cost without adding a getter to the
production account ABI. `unit/CheckpointEntryPointBundle.t.sol` uses the real
pinned EntryPoint source to prove that multiple same-account UserOperations in
one bundle receive isolated invocation scopes.

### Reviewer-readable test vocabulary

DSC-77 established one vocabulary across unit, fuzz, invariant, integration, and
Base fork tests. Names should expose the scenario without requiring a reviewer
to reverse-engineer helper code:

| Before | Use now | Meaning |
| --- | --- | --- |
| `pair` | `compatibilityFixture` | Two independent delegated EOAs used for upstream differential tests |
| `customAccount` | `accountUnderTest` or `defiSimplify` | The delegated DeFi Simplify EOA, not a separate account hidden behind an ABI cast |
| `target` | `recordingTarget`, `calldataCaptureTarget`, `aavePool`, etc. | The target's role in the scenario |
| `token` | `balanceToken`, `checkpointToken`, `producedToken`, etc. | The token's role in the scenario |
| `_call` / `_dynamicCall` | `_build...Call` or `_build...Batch` | A builder whose name says what scenario it constructs |
| `SUBJECT_OFFSET` / `SELECTED_RETURN_OFFSET` | `ACCOUNT_ARGUMENT_OFFSET` / `ACCOUNT_VALUE_RETURN_OFFSET` | The exact ABI word and byte sequence being indexed |

Test names read as executable specifications: subject or action, condition when
needed, and observable result. Gas, golden-vector, fuzz, and invariant tests
retain their conventional prefixes. Generic ABI field names such as `target`,
`value`, `data`, and `token` remain appropriate inside the ABI structs and
small generic builders where the surrounding scope already supplies their
meaning.

This refactor intentionally changed only test code, fixture topology, names, and
deterministic test gas. Production source, public ABI fixtures, runtime bytecode,
and contract behavior remained unchanged. At the DSC-77 merge point, the
non-fork regression suite contained 210 tests.

### Callback suite navigation

| Reviewer question | Start here |
| --- | --- |
| Does the ordinary callback state machine enforce origin, lifecycle, repayment, and cleanup? | `unit/AaveV3FlashLoanCallback.t.sol`, whose section boundaries follow those four concerns |
| What happens at malicious reentry, malformed calldata, wrapper, repayment, and outer-failure boundaries? | `unit/AaveV3FlashLoanAdversarial.t.sol` |
| Are outer and callback scopes isolated across same-account EntryPoint operations? | `unit/AaveV3FlashLoanEntryPointBundle.t.sol` |
| Do arbitrary patches, positions, flags, premiums, and allowances preserve the rules? | `fuzz/AaveV3FlashLoanCallbackFuzz.t.sol` |
| Do randomized success and expected-failure sequences preserve rollback and cleanup? | `invariant/AaveV3FlashLoanCallbackInvariant.t.sol` |
| Which test dependency injects each callback fault? | `mocks/AaveV3FlashLoanMocks.sol`, grouped by origin, lifecycle, repayment, receiver, and outer failure |

The invariant handler treats expected protocol reverts as modeled outcomes and
checks their rollback locally. Any handler revert is unexpected and remains
fatal under `fail_on_revert = true`. Its expected-success counters are the
reference model; target state is observed telemetry, and the sticky
postcondition verdict covers commitment cleanup, lock release, and zero Pool
allowance.

### Focused validation

Run the canonical repository gate:

```sh
make check
```

Use these focused layers while reviewing a test-only change:

```sh
forge test --no-match-path 'test/fork/**'
forge test --match-path 'test/unit/AaveV3FlashLoan*.t.sol' -vvv
forge test --match-path 'test/fuzz/**/*.t.sol' -vvv
forge test --match-path 'test/invariant/**/*.t.sol' -vvv
forge snapshot --check --no-match-test 'testFuzz|invariant_' \
  --no-match-contract 'BaseDeploymentManifestTest|BaseV1_1CandidateManifestTest' \
  --no-match-path 'test/fork/**'
```

Base protocol suites remain a separate `BASE_RPC_URL`-dependent gate. The root
`Makefile`, CI workflows, and repository instructions are canonical when a
historical command below differs from current validation.

## Historical verification appendix

The following reports preserve what each completed DSC issue proved at its merge
point. Their suite counts, gas values, runtime sizes, artifact hashes, and
commands are intentionally historical; use the current reviewer guide above for
present ownership and validation.

### DSC-51 dynamic-engine verification report

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

#### Gas evidence

| Scenario | Test gas |
| --- | ---: |
| One-call `CurrentBalance` patch | 145,118 |
| Two-call `CheckpointDelta` producer/consumer | 153,511 |
| Three same-token cached patches | 173,262 |
| Two same-account sequential invocations | 159,014 |

The existing production checkpoint-delta matrix remains:

| Checkpoint-delta patches | Test gas |
| ---: | ---: |
| 1 | 87,534 |
| 4 | 111,539 |
| 8 | 142,335 |
| 16 | 206,037 |
| 32 | 333,085 |

The incremental cost remains approximately linear as checkpoint/patch count
grows. These figures are regression evidence for table complexity, not
protocol-flow estimates or permission to weaken validation.

DSC-77 refreshed these figures after ordinary custom-account suites stopped
deploying an unused upstream comparison account. The changes measure fixture
construction and renamed test harnesses; production runtime bytecode is
unchanged.

The snapshot command excludes `invariant_` functions because their reported
run/call totals intentionally differ between the default and CI profiles. The
deterministic tests in the invariant suite remain in `.gas-snapshot`.

#### Findings and accepted gaps

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

### DSC-53 balance assertions

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

### DSC-76 shared transient token-balance records

`src/libraries/TransientTokenBalanceRecord.sol` is the canonical production
accessor for the shared physical record shape used by account checkpoints and
assertion snapshots: presence at offset zero, token at offset one, and balance
at offset two. The internal-only library is compiler-inlined and introduces no
creation-time or runtime link references. Each consumer continues to own its
scope, lifecycle, validation order, balance reads, and custom errors; semantic
table libraries own the frozen roots and record-root derivation.

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

### DSC-55 Aave V3 health-factor assertion

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

### DSC-54 independent generic uint256 staticcall checker

`StaticCallUint256Assertions` is deployed and reviewed independently from the
typed `FlowAssertions` checker. It supports an account-binding mode that
replaces exactly one selector-relative ABI word with `msg.sender`, and an
explicit `type(uint32).max` global-read mode that leaves calldata unchanged.
Both paths select one aligned fixed-width returndata word and apply either a
minimum or maximum uint256 bound.

`unit/StaticCallUint256Assertions.t.sol` covers validation order, account-word
byte isolation, account-binding evidence, both comparison directions, adjacent
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
`8552f847e4c0fe8849649d531bba31030f32acdd4fba99e042033226ee642e1f`.
The tracked `FlowAssertions` source, interface, and ABI fixture remain
byte-for-byte unchanged.

Run the focused DSC-54 suites with:

```sh
forge test --match-path 'test/unit/StaticCallUint256Assertions*.t.sol' -vvv
forge test --match-path 'test/fuzz/StaticCallUint256AssertionsFuzz.t.sol' -vvv
forge test --match-path 'test/integration/StaticCallUint256AssertionsBatchIntegration.t.sol' -vvv
forge test --match-path 'test/fork/BaseStaticCallUint256Assertions.t.sol' --fork-url "$BASE_RPC_URL" -vvv
```

### DSC-78 authenticated Aave V3 callback path

`unit/AaveV3FlashLoanCallback.t.sol` exercises the complete direct
`flashLoanSimple` round trip through a delegated EOA. It covers callback-enabled
calls at first, middle, and last outer indices; zero, one, and many callback
calls; rejection of two outer callback flags before any target; commitment to
patched calldata; separate callback checkpoint scope with
outer-scope resumption; exact zero-first repayment; wrong sender, initiator, and
origin; missing, replayed, nested, and reentrant callbacks; premium and
arithmetic bounds; callback target failure with dual indices; malformed token
reads and approvals; failed Pool pulls; residual allowance; and atomic rollback.
`unit/CallbackCommitmentState.t.sol` directly proves that a new commitment
cannot overwrite a non-idle callback lifecycle.
`unit/TransientExecutionComponents.t.sol` directly verifies lock transitions,
checked nonzero invocation allocation, callback field publication, and cleanup.
`integration/TransientNamespaceSeparation.t.sol` independently reproduces the
full ERC-7201 derivation and checks every occupied scalar, record, and table slot
for cross-component collisions.

`unit/CallbackGoldenVectors.t.sol` verifies
`abi/CallbackExecution.golden.json`: the final selectors, final ERC-165 interface
ID, both boolean encodings, zero/one/many-call callback envelopes, and every
callback error encoding. `unit/DynamicGoldenVectors.t.sol` updates the existing
plan fixture to version 3 for the semantic ERC-7201 transient roots and
five-field callback commitment layout.

DSC-83 later retired the transition-only `unit/CallbackAbi.t.sol`; the final
unit, adversarial, and golden-vector suites listed above preserve its supported
properties. DSC-84 restores one black-box decoding regression through a real
delegated EOA: calldata uses the final selector but encodes a tuple without
`expectsCallback`, and must fail before fallback, target execution, or value
transfer. The pre-release tuple remains unsupported and is not a compatibility
surface.

DSC-79 and DSC-80 were folded into DSC-78 before release so reviewers see one
complete behavior instead of a sequence of temporary fail-closed artifacts.
The DSC-78 implementation baseline had 263 passing non-fork tests. DSC-81 is
the separate audit-grade fuzz and invariant hardening gate.

Run the focused DSC-78 suites with:

```sh
forge test --match-path 'test/unit/Callback*.t.sol' -vvv
forge test --match-path 'test/unit/AaveV3FlashLoanCallback.t.sol' -vvv
./script/check-minimal-account-surface.sh
./script/check-abi-fixtures.sh
```

### DSC-81 callback adversarial, fuzz, and invariant proof

DSC-81 does not expand the callback ABI or supported provider set. It stresses
the completed Aave V3 callback path as a security boundary:

- `unit/AaveV3FlashLoanAdversarial.t.sol` covers callback attempts before,
  during, and after a window; wrapper-mediated callbacks; different same-Pool
  replay; truncated callback calldata; self, inherited static, and public
  dynamic reentry; outer/callback checkpoint isolation in both directions;
  Pool failure before callback, after callback, and after repayment; too little,
  too much, and no repayment pull; fee-on-transfer and reentrant approval
  tokens; bounded 4 KiB revert-data preservation; and zero permanent account
  writes;
- `unit/AaveV3FlashLoanEntryPointBundle.t.sol` uses the real pinned EntryPoint
  source to execute multiple same-account UserOperations in one bundle. It
  proves that a failed callback operation between two successes rolls back both
  tentative invocation scopes while EntryPoint continues to the next nonce,
  and that a callback plan cannot start nested `handleOps`;
- `fuzz/AaveV3FlashLoanCallbackFuzz.t.sol` covers patched principal and actual
  calldata commitment, callback position, bounded plan length, every nested
  flag index, premium and starting allowance, and origin-field mutation across
  512 default cases per property;
- `invariant/AaveV3FlashLoanCallbackInvariant.t.sol` repeatedly interleaves
  success, missing callback, reverting callback plans, and a
  success/failure/success same-transaction sequence. Successful completion must
  restore `Idle`, clear every commitment field, unlock execution, leave zero
  Pool allowance, and update persistent target state only for successful
  callback plans; and
- `unit/AaveV3FlashLoanGas.t.sol` adds deterministic callback-window and exact
  repayment snapshots.

The final callback gas scenarios are:

| Scenario | Test gas |
| --- | ---: |
| Empty callback plan and exact repayment | 162,241 |
| One ordinary callback call | 261,875 |
| Four ordinary callback calls | 294,180 |
| Exact repayment with preexisting allowance | 182,647 |

The repository has 299 passing non-fork tests under the default profile. Each
callback invariant property runs 256 sequences at depth 128, for 32,768
generated handler calls per campaign, with zero handler reverts.
The CI profile passes 10,000 runs for every fuzz property and 512 invariant
sequences at depth 256, for 131,072 generated calls per callback campaign.

All production contracts and semantic transient libraries retain 100% line,
statement, branch, and function coverage. The final account runtime is 9,315
bytes. The reproducible artifact tree is
`0d8533533daf11398c20c85029dcd85f10b52c0a8cb928f5f181be17b7ae42d6`.
Dependency-inclusive Slither reports 71 results for manual review; 17 remain
after filtering pinned libraries, and the project-owned high-severity gate
reports zero high findings. The remaining project results are the intentional
checked low-level token/protocol calls, their loop reachability, and reviewed
assembly word reads/writes.

#### Explicit limits of the proof

- A callback outer-call index is not supplied by the Pool and cannot be changed
  by a production caller independently from the committed call. First, middle,
  and last placement plus retained-index error attribution are tested; arbitrary
  internal slot corruption is only meaningful in the dedicated transient
  harness, not as a production attack path.
- Keccak-256 collision resistance is a cryptographic assumption. Fuzzing proves
  that mutated receiver, asset, amount, params, selector, referral code, and
  calldata length do not execute a plan; tests cannot exhaustively prove that
  no hash collision exists.
- v1 still preserves complete target revert data. The suite proves byte-for-byte
  preservation for bounded 4 KiB data and retains the existing deliberate OOG
  characterization for an unbounded returndata bomb. It does not claim indexed
  attribution survives memory-exhaustion OOG.
- Fee-on-transfer and reentrant tokens are adversarially characterized, not
  admitted as generally supported assets. The fee-on-transfer fixture fails
  repayment coverage atomically; a token callback during approval observes
  `ExecutingCallback` and cannot consume the active callback again.
- Base protocol behavior and a complete flash-assisted lifecycle remain the
  separate DSC-82 fork proof. DSC-81 proves the local account boundary and does
  not claim production readiness or an external audit.

Run the focused DSC-81 suites with:

```sh
forge test --match-path 'test/unit/AaveV3FlashLoanAdversarial.t.sol' -vvv
forge test --match-path 'test/unit/AaveV3FlashLoanEntryPointBundle.t.sol' -vvv
forge test --match-path 'test/fuzz/AaveV3FlashLoanCallbackFuzz.t.sol' -vvv
forge test --match-path 'test/invariant/AaveV3FlashLoanCallbackInvariant.t.sol' -vvv
forge test --match-path 'test/unit/AaveV3FlashLoanGas.t.sol' -vvv
```

#### Validation commands used at the DSC-81 merge point

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
make coverage
./script/check-reproducible-build.sh
slither . --fail-none
slither . --filter-paths 'lib/' --fail-high
```

The repository-wide commands in the root `README.md` remain the release gate.

### DSC-68 SDK/signer-only no-code target policy

`unit/DynamicNoCodeTargetPolicy.t.sol` locks the accepted contract-side half of
ADR-007 without changing production Solidity. It proves that:

- nonempty calldata to a nonzero no-code target retains generic EVM `CALL`
  success; and
- a no-code call carrying value transfers the declared native ETH.

These tests deliberately characterize the unsafe primitive that DS-55 must
reject before signing except for an explicit typed and bounded EOA transfer.
They do not claim receipt success, code existence, or simulation establishes
target identity.

Run the focused suite with:

```sh
forge test --match-path 'test/unit/DynamicNoCodeTargetPolicy.t.sol' -vvv
```

### DSC-84 post-review test and coverage hardening

DSC-84 adds evidence without changing production Solidity, ABI, storage,
metadata, or the deployed artifact identity:

- `unit/DynamicExecution.t.sol` sends the final selector with a tuple that omits
  `expectsCallback` through a real delegated EOA and proves ABI decoding fails
  before the inherited fallback can report success or a target can execute;
- the callback origin-mutation fuzz property now checks the complete nested
  `CallbackOriginMismatch` wrapped by `DynamicCallFailed`, while the truncated
  callback regression checks the exact outer wrapper with empty decoder revert
  data; both retain explicit plan non-execution and asset rollback assertions;
- `unit/BalanceCacheGas.t.sol` verifies that patches and checkpoints share one
  pre-call cache read per token and records the 1/4/8/16/32 distinct-token
  matrix; and
- `make coverage` reports only authored `src/` contracts and libraries and
  rejects any line, statement, branch, or function regression below 100%.

For `N` distinct tokens, the benchmark inserts each token during patch
resolution and reuses it during checkpoint creation. The current linear lookup
therefore performs `N` unavoidable external `balanceOf` static calls and
`N²` address comparisons in this deliberately lookup-heavy shape:
`N(N-1)/2` comparisons while inserting misses plus `N(N+1)/2` comparisons for
checkpoint hits. The arrays reserve `2N` entries because capacity follows the
number of patches plus checkpoints, although only `N` distinct values are
stored.

| Distinct tokens | Deterministic test gas |
| ---: | ---: |
| 1 | 33,005 |
| 4 | 74,754 |
| 8 | 135,707 |
| 16 | 275,847 |
| 32 | 629,884 |

These cases intentionally characterize the current implementation rather than
establish a production plan recommendation. External token calls and calldata,
memory, and checkpoint work remain part of the end-to-end totals. Every reviewed
Base v1 reference strategy currently uses at most one distinct balance token
within any one `DynamicCall`, so the linear cache is acceptable for the frozen
v1 plan shapes. This is an observed plan bound, not a new on-chain maximum or a
claim that arbitrary large plans are cheap. DSC-87 owns any production cache
redesign after comparing this matrix with actual SDK strategy distributions.

The coverage gate uses Foundry's countable source anchors. No production source,
line, statement, branch, function, or assembly block is manually excluded.
Foundry warnings for inline assembly and compiler-generated or inlined code stay
visible in CI; the gate does not pretend such unmappable anchors are measured.
Passing 100% coverage is regression evidence, not a security proof.

Run the focused gate with:

```sh
forge test --match-path 'test/unit/BalanceCacheGas.t.sol' -vvv
forge test --match-test 'test_ExecuteBatchDynamic_WhenTupleOmitsExpectsCallback_RevertsWithoutFallbackOrTargetExecution' -vvv
forge test --match-test 'testFuzz_OriginFieldMutationNeverExecutesCallbackPlan' -vvv
forge test --match-test 'test_TruncatedCallbackCalldataCannotReachCallbackPlan' -vvv
make snapshot
make coverage
```

The final local suite contains 315 non-fork tests and 283 deterministic
gas-snapshot tests.

### DSC-87 v1.1 artifact and gas decision

DSC-87 creates an unreleased, unbroadcast v1.1.0 artifact family. It preserves
the official Base v1.0.0 manifest and rebuilds that identity from its exact
deployment source commit with 200 optimizer runs. The active candidate uses
10,000 runs and leaves the two `BalanceCache` arrays unallocated when a call
contains no patches or checkpoints.

The isolated 200-run source comparison reproduced the expected allocation
effect:

| Path | Released source | Empty-cache fast path | Delta |
| --- | ---: | ---: | ---: |
| Zero-capacity ordinary call | 20,056 | 19,461 | -595 |
| Empty callback plan | 162,654 | 162,059 | -595 |
| One ordinary callback call | 262,921 | 261,730 | -1,191 |
| Four ordinary callback calls | 297,195 | 294,213 | -2,982 |
| Exact repayment | 183,060 | 182,465 | -595 |

Balance-aware dynamic paths add 39–80 gas under the isolated source change
because they take the nonzero-capacity branch. The complete 10,000-run candidate
more than offsets that branch cost in the measured paths:

| Representative path | Official v1.0.0 / 200 runs | v1.1.0 candidate / 10,000 runs | Delta |
| --- | ---: | ---: | ---: |
| One current-balance patch | 146,920 | 146,363 | -557 |
| Two-call checkpoint delta | 157,122 | 156,156 | -966 |
| Empty callback plan | 162,654 | 160,228 | -2,426 |
| One ordinary callback call | 262,921 | 259,876 | -3,045 |
| Four ordinary callback calls | 297,195 | 291,807 | -5,388 |
| Exact repayment | 183,060 | 180,736 | -2,324 |

Deployment becomes more expensive because higher optimizer runs trade bytecode
size for repeated runtime execution:

| Artifact | Runtime bytes, v1.0.0 → v1.1.0 | Benchmark deployment gas, v1.0.0 → v1.1.0 |
| --- | ---: | ---: |
| `DefiSimplify7702Account` | 9,315 → 12,158 | 1,900,100 → 2,470,166 |
| `FlowAssertions` | 1,451 → 2,209 | 323,163 → 475,099 |
| `StaticCallUint256Assertions` | 1,082 → 1,609 | 249,160 → 354,802 |

The account deployment premium amortizes after roughly 106–1,024 measured
executions depending on plan shape. The representative typed balance assertion
amortizes after about 512 calls; the generic uint256 checker needs roughly
1,030 calls. This project expects immutable delegation/checker artifacts to be
reused across many accounts and transactions, so the runtime-biased candidate
is accepted before the audit freeze.

The distinct-token cache remains linear. Every reviewed Base reference strategy
uses at most one distinct balance token per `DynamicCall`; a mapping or
transient-table redesign would add initialization, bytecode, collision policy,
and audit surface for synthetic shapes outside that observed bound. The
10,000-run build also reduces the 1/4/8/16/32 matrix to
32,408 / 73,040 / 131,565 / 263,681 / 588,998 gas without changing cache
semantics.

All seven pinned-block Base gas flows also decrease:

| Base flow | v1.0.0 / 200 runs | v1.1.0 candidate / 10,000 runs | Delta |
| --- | ---: | ---: | ---: |
| Static approve and supply | 182,769 | 182,344 | -425 |
| Static supply and borrow | 381,138 | 380,623 | -515 |
| Static repay and withdraw | 69,934 | 69,557 | -377 |
| Guarded dynamic loop | 621,217 | 615,319 | -5,898 |
| Flash leverage open | 688,723 | 679,433 | -9,290 |
| Flash partial deleverage | 414,017 | 404,797 | -9,220 |
| Flash full close | 300,587 | 294,774 | -5,813 |

Run the focused evidence with:

```sh
forge test --match-path 'test/unit/BalanceCache*.t.sol' -vvv
forge test --match-path 'test/benchmark/ArtifactDeploymentGasBenchmark.t.sol' -vvv
forge test --match-contract BaseV1_1CandidateManifestTest -vvv
./script/check-base-v1-1-candidate-manifest.sh
./script/check-base-v1-manifest.sh
```

The post-DSC-87 local suite contains 325 non-fork tests. The deterministic
non-fork snapshot contains 288 tests, plus seven separately measured Base fork
gas tests; JSON/build identity tests remain excluded because their compiler and
manifest work is not product execution gas.
