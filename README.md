# defi-simplify-contracts

Minimal EIP-7702 execution primitives for the `defi-simplify` Go SDK.

> [!WARNING]
> **Experimental and unaudited.** v1 has not undergone, and is not currently
> planned to undergo, an independent security audit before publication. Tests,
> fuzzing, invariant campaigns, static analysis, Base fork proofs, source
> verification, and deterministic deployment are engineering evidence—not an
> audit or a security guarantee. Smart-contract, EIP-7702, protocol, signer, or
> automation failures can cause total and irreversible loss of funds. Use only
> at your own risk, never with funds you cannot afford to lose. No warranty or
> security guarantee is provided.

## Start here

This repository publishes the contracts that will be used by the
`defi-simplify` SDK. The contracts are deployed on Base so their addresses and
bytecode can be reviewed and integrated reproducibly, but they are not yet a
finished end-user product.

| Question | Current answer |
| --- | --- |
| Which chain is supported? | Base only |
| Are the contracts deployed? | Yes; they have no proxy or upgrade path |
| Are the deployed sources verified? | Yes; BaseScan reproduced the deployed bytecode from source |
| Is there an independent audit? | No |
| Is this version released? | No |
| Can the Go SDK use it end to end? | Not yet |
| Is it recommended for production funds? | No |

Until the Go SDK integration and signer-policy gates are complete, users should
not manually construct calldata, install the delegation, or operate these
contracts with funds. A verified deployment proves which source and build
produced the bytecode; it does not prove that a strategy is safe.

## How the contracts fit together

| Contract | What it does | How a user interacts with it |
| --- | --- | --- |
| `DefiSimplify7702Account` | Adds guarded DeFi batch execution and the authenticated Aave V3 flash-loan callback to an EIP-7702 account | The user's EOA—their normal wallet address—delegates code to this implementation; users should not send assets to or call the implementation address as if it were their wallet |
| `FlowAssertions` | Checks caller-bound ERC20 balances and Aave V3 health factor at the end of a flow | The SDK appends reviewed final safety conditions to a batch so a failed condition reverts the execution |
| `StaticCallUint256Assertions` | Checks a reviewed fixed `uint256` return word for integrations without a typed assertion | This is an advanced SDK adapter, not a general-purpose safety check |

The intended future user flow is:

1. the SDK constructs protocol calldata, amount patches, and final assertions;
2. the signer shows the targets, amounts, bounds, and expected outcome for
   review;
3. the user authorizes their EOA to delegate to the official account
   implementation;
4. execution runs in the user's delegated EOA context, where the assets remain;
5. a failed target call or assertion reverts execution-time asset and protocol
   changes, although gas and nonce are still consumed.

The three deployments have no owner, admin, proxy, or upgrade function. The
deployer cannot operate a user's delegated EOA or replace the deployed code.

## Official Base v1 contracts

`official` means that this repository publishes and reproduces the exact
artifact and deployment identity. It does not mean audited, released,
SDK-integrated, safe, or recommended for capital.

| Contract | Purpose | Base address |
| --- | --- | --- |
| `DefiSimplify7702Account` | EIP-7702 delegation implementation | [`0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA`](https://basescan.org/address/0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA#code) |
| `FlowAssertions` | Typed balance and Aave V3 post-conditions | [`0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5`](https://basescan.org/address/0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5#code) |
| `StaticCallUint256Assertions` | Reviewed fixed-word assertion adapter | [`0x034ee940A644323463AB074DCA99504BF5a666EA`](https://basescan.org/address/0x034ee940A644323463AB074DCA99504BF5a666EA#code) |

The machine-readable deployment identity, transaction links, code hashes, and
independent reproduction commands are in
[`deployments/base-v1.json`](deployments/base-v1.json) and
[`deployments/README.md`](deployments/README.md).

## Implementation scope

The v1 implementation targets Base, inherits the pinned account-abstraction
v0.9.0 `Simple7702Account`, adds checkpoint-based ERC20 amount patching, and
provides independent post-condition assertions. The public contract surface is
defined by the checked-in Solidity interfaces and implementation.

The account also implements the final v1 direct Aave V3
`flashLoanSimple` callback path. A callback-enabled call commits its fully
patched calldata and direct Pool target in transient storage; `executeOperation`
authenticates that origin, executes an isolated callback plan, installs an exact
zero-first-compatible repayment allowance, and requires the Pool to consume the
allowance completely before the outer batch continues.

`FlowAssertions` provides typed ERC20 balance and Aave V3 health-factor checks.
`StaticCallUint256Assertions` is a lower-level adapter with explicit
account-binding and global-read modes. Binding is not an authorization
boundary; the SDK and signer must authenticate the exact checker, target,
selector, offsets, and bound semantics.

## v1 security analysis boundary

Any security analysis must cover the combined deployed bytecode, including the
pinned inherited account:

```text
Simple7702Account v0.9.0 (pinned upstream commit)
  └── DefiSimplify7702Account
        ├── inherited execute / executeBatch and ERC-4337 behavior
        ├── executeBatchDynamic checkpoint and patch engine
        └── authenticated Aave V3 executeOperation callback

FlowAssertions
  └── caller-bound balance and Aave V3 post-conditions

StaticCallUint256Assertions
  └── independent fixed-word STATICCALL bridge
```

The account's final v1 `executeBatchDynamic` selector is `0xecadebe3`; its
custom ERC-165 interface ID, including `executeOperation`, is `0xf7bc3b1c`.
All three artifacts are direct and immutable, require no linked deployed
libraries, define no permanent storage, and expose no custom events, owner,
admin, proxy, or upgrade path. The account has one immutable constructor input:
the pinned EntryPoint. The two checkers are constructor-free.

## Pinned bootstrap toolchain

- Foundry: `v1.7.1`
- Solidity: `0.8.36`
- EVM: `prague`
- optimizer: enabled, 200 runs
- IR pipeline: enabled
- forge-std: `v1.16.2`,
  `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b`

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
./script/check-forge-std-revision.sh
```

This project does not claim the v0.9.0 baseline is audited.

Install the pinned Foundry release, then run:

```sh
make check
```

`make check` runs the pinned toolchain and dependency checks, formatting,
contract build and surface gates, ABI and deployment identity checks, non-fork
tests, gas snapshots, coverage, reproducibility, and both Slither passes. Use
`make help` to list the individual targets.

The first Slither run keeps pinned dependency findings visible for manual
review. The second run gates high-severity findings owned by this repository;
it does not replace review of inherited risk.

Coverage recompiles without the release optimizer and `viaIR`, so the
production-bytecode deployment identity test is intentionally excluded from
that one command and is run by the normal test suite instead. Its JSON/build
verification gas is also excluded from `.gas-snapshot` because it is not a
product execution baseline. Deployment scripts are omitted from the coverage
denominator; production contracts and transient libraries retain their
explicit coverage evidence.

Base fork tests are intentionally separate from the default suite and require
`BASE_RPC_URL`:

```sh
make check-base
```

GitHub Actions runs the separate Base fork workflow automatically for pull
requests whose head branch belongs to this repository, using the repository
`BASE_RPC_URL` secret. The workflow remains manually dispatchable; pull requests
from external forks skip it because repository secrets are not exposed to them.
The same workflow checks the pinned Base Aave static, guarded
WETH-collateral/USDC-debt loop, and flash-assisted cbETH/WETH lifecycle gas
baselines stored in `.gas-snapshot`. It also verifies the live Arachnid factory
and independently reconstructs the three official deployment payloads, runtime
identities, and historical factory transactions without broadcasting.

The guarded WETH-collateral/USDC-debt loop proof at Base block `48,961,870`
supplies WETH, checkpoints and borrows USDC, swaps only the observed USDC delta
through the official Uniswap V3 `SwapRouter02`, supplies only the observed WETH
output, and finishes with an Aave V3 health-factor assertion. Existing WETH,
USDC, and native inventory act as sentinels. The direct Base
`exactInputSingle` entrypoint provides `amountOutMinimum` and
`sqrtPriceLimitX96` but no deadline; fresh simulation and short-lived
submission do not create an on-chain expiry guarantee.

The flash-assisted proof at the same pinned block covers a cbETH/WETH
correlated E-Mode leverage open, partial deleverage, and full close through
Aave V3 `flashLoanSimple` and the direct Uniswap V3 cbETH/WETH 0.05% pool. It
checks exact premium-aware repayment, zero residual Aave Pool and Router
allowances, final health-factor or zero-debt assertions, delegated-EOA
ownership, and atomic rollback under forced failures. The full-close flow
patches Aave's visible variable-debt-token balance into both the flash
principal and callback repayment approval. The direct swap calls provide
router-native amount and price bounds but no deadline.

Generated build output and RPC credentials are ignored. `.gas-snapshot`, source
code, deployment manifests, compiler configuration, and dependency locks are
expected to be committed.

## DSC-58 security evidence

The deployed-but-unreleased v1 implementation is backed by these reproducible gates:

| Gate | Evidence |
| --- | --- |
| Non-fork regression | 308 tests pass under the CI profile |
| Fuzz/property | Every fuzz property runs 10,000 cases, including exact patch byte isolation and full-precision `mulDiv` agreement |
| Stateful invariants | Both dynamic-engine and callback campaigns run 512 sequences at depth 256, up to 131,072 generated calls per invariant, with zero unexpected reverts |
| Production coverage | 100% line, statement, branch, and function coverage for all three contracts and all transient libraries |
| Static compatibility | A 12-test upstream-compatibility suite combines differential execution/error/receiver checks with authorization and EntryPoint boundary regressions against the pinned account |
| Transient state | Independent ERC-7201 derivation, pairwise occupied-slot separation, adjacent record fields, invocation reuse/isolation, stale-scope rejection, rollback, and same-account EntryPoint bundles are executable tests |
| Callback safety | Exact patched-origin commitment, state transitions, nested/replayed/wrong-origin rejection, separate invocation ownership, exact repayment, allowance cleanup, adversarial tokens, rollback, and EntryPoint bundles are covered by unit, fuzz, and invariant suites |
| Generic checker | Binding/global modes, selected and adjacent words, account replacement, offset bounds, explicit sentinel, and the documented padding bypass are covered by unit, fuzz, integration, golden, and Base fork tests |
| Base reference flows | 35 pinned-block tests cover static Aave, guarded Aave/Uniswap dynamic execution, flash leverage open, partial deleverage, full close, forced failures, protocol identities, custom-event absence, and gas |
| Static analysis | Slither 0.11.4 reports 71 dependency-inclusive findings; every category is triaged below, and the project-owned high-severity gate reports zero high findings |
| Artifact identity | ABI fixtures, exact compiler/dependency settings, direct-artifact checks, and two clean artifact builds are compared deterministically |

The Base workflow intentionally runs behavioral fork tests and gas tests in
separate non-overlapping commands. This avoids executing the seven RPC-heavy
gas tests twice while retaining the committed gas regression gate.

### Representative gas baselines

Gas values are deterministic test regressions from `.gas-snapshot`, not
profitability estimates or permission to weaken validation.

| Base reference flow | Gas |
| --- | ---: |
| Static approve + supply | 182,769 |
| Static supply + borrow | 381,138 |
| Static repay + withdraw | 69,934 |
| Guarded WETH/USDC dynamic loop | 621,217 |
| Flash-assisted cbETH/WETH leverage open | 688,723 |
| Flash-assisted partial deleverage | 414,017 |
| Flash-assisted full close | 300,587 |

ADR-004's integrated checkpoint evidence remains approximately linear:

| Records | Create only | Lookup heavy | Production checkpoint-delta patches |
| ---: | ---: | ---: | ---: |
| 1 | 146,749 | 151,543 | 91,054 |
| 4 | 154,378 | 167,906 | 116,507 |
| 8 | 164,797 | 190,083 | 149,243 |
| 16 | 184,929 | 235,055 | 216,859 |
| 32 | 225,774 | 323,028 | 351,860 |

### Slither triage

- The inherited high-severity arbitrary-ETH-send report is
  `BaseAccount._payPrefund`, which may pay only the already-authorized
  EntryPoint caller and is required by ERC-4337 prefunding.
- The OpenZeppelin high-severity XOR report is a false positive: the expression
  intentionally seeds Newton-Raphson modular inversion in the reviewed
  `Math.mulDiv` implementation.
- Nine OpenZeppelin medium divide-before-multiply reports are intentional steps
  in the pinned full-precision math implementation, not truncating application
  arithmetic.
- Four project-owned low `calls-loop` reports are the checked balance and
  allowance reads required by user-supplied dynamic plans. Their results and
  complete malformed/revert data are validated, and the dynamic lock and
  callback state protect reentry.
- Seven project-owned assembly reports are bounded word reads/writes after
  explicit length, alignment, or ABI-tuple validation.
- Six project-owned low-level-call reports are intentional checked ERC20,
  Aave, and generic `STATICCALL`/approval operations that preserve raw
  returndata for indexed errors and non-standard token compatibility.
- The remaining findings are pinned dependency assembly, unused upstream
  helpers, mixed compatible pragma ranges, and a version-range warning. The
  repository compiles every source with exact Solidity 0.8.36 and verifies that
  lock before every build.

No Slither finding is treated as an audit substitute. No independent v1 audit
is currently planned; the published evidence must not be described as one.

## Accepted risks and unresolved assumptions

- Execution-time asset and protocol changes revert atomically on failure, but
  gas and nonce are consumed. A newly processed EIP-7702 delegation may remain
  installed even when execution reverts.
- Simulation is required operationally but is not an on-chain proof; state,
  quotes, rates, liquidity, proxy implementations, and oracle output can change
  before inclusion.
- Callback authentication proves the authorized direct call instance, not that
  an arbitrary ABI-compatible target is the official Aave Pool. The SDK and
  signer must pin and monitor the governed Pool and its implementation.
- The Aave assertion inherits the supplied Pool and oracle trust. Generic
  account binding is an adapter guardrail, not authorization.
- Dynamic patch offsets describe reviewed ABI words, but the account cannot
  distinguish an amount from a pointer or length. Structured ABI derivation,
  golden vectors, signer policy, and exact simulation are required.
- Inherited static execution and custom dynamic execution retain generic EVM
  `CALL` behavior: a nonzero no-code target can return success, and a call with
  value can transfer native ETH. The frozen v1 policy deliberately adds no
  partial on-chain code-existence guard. The SDK/signer must recursively admit
  static, dynamic, and callback targets by chain, reviewed manifest, runtime
  identity, and selector policy. Code existence and simulation success alone
  are insufficient; pure EOA transfers must be explicit and bounded.
- Conventional ERC20 `balanceOf`, `allowance`, and `approve` behavior is
  assumed. Fee-on-transfer, rebasing, blocklisted, callback-enabled, malformed,
  or unusual approval tokens require separate admission evidence.
- Complete revert and malformed returndata is preserved. A malicious target can
  cause memory-expansion or returndata-copy out-of-gas before an indexed custom
  error is encoded; atomic rollback still holds.
- Base `SwapRouter02` direct swap entrypoints used by the reference flows have
  native amount and price bounds but no deadline. Fresh, short-lived
  submission does not create on-chain expiry.
- Native-balance patching, return-data piping, multi-asset Aave flash loans,
  nested callbacks, and non-Aave callback providers are outside v1.
- DS-55 must implement recursive SDK/signer target admission, and DS-54 must
  prove the callback envelope and fully patched origin bytes against committed
  Solidity vectors before this deployment is presented as SDK-integrated.
- The custom account remains high risk. The project does not require an
  independent audit before the explicitly unaudited experimental v1 release;
  the warning above, controlled canary operation, and real-world maturity do
  not eliminate the possibility of total loss.
