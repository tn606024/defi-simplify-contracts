# Contract Specification

Status: normative v1 draft
Date: 2026-07-13

The key words MUST, MUST NOT, REQUIRED, SHOULD, SHOULD NOT, and MAY are to be
interpreted as normative requirements.

## Reference Sources

The contract design is derived from the `defi-simplify` SDK and product
architecture:

- Project source: https://github.com/tn606024/defi-simplify
- Upstream account baseline: eth-infinitism account-abstraction v0.9.0
  `Simple7702Account.sol` at
  `b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`.
- Dependency and Base EntryPoint lock:
  `config/account-abstraction-v0.9.0.json`.
- Architectural decision and audit evidence: ADR-001.

Implementations MUST use that exact unmodified upstream commit for
`Simple7702Account.sol`, `BaseAccount.sol`, EntryPoint interfaces, compiler
compatibility tests, and reproducible deployment artifacts. A later revision
requires a superseding ADR and a new deployment identity.

## 1. Build and Platform Requirements

- Solidity MUST be pinned to an exact 0.8.x compiler compatible with the pinned
  upstream account-abstraction release. The initial target is 0.8.28.
- The EVM target MUST support EIP-1153 transient storage.
- Chains used for delegated execution MUST support EIP-7702.
- Foundry, dependency revisions, optimizer runs, `via_ir`, and EVM version MUST
  be committed and reproducible.
- Base v1 MUST configure EntryPoint v0.9.0 at
  `0x433709009B8330FDa32311DF1C2AFA402eD8D009` and verify runtime code hash
  `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`
  before ERC-4337 use.
- Production deployments MUST use verified source and publish runtime code hash.
- Official v1 deployments MUST use Foundry's default Arachnid Deterministic
  Deployment Proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
  Its runtime code hash MUST be pinned by ADR and verified on every target chain
  before deployment.
- The deployment manifest MUST record the factory address, factory code hash,
  address-family identifier, salt, complete initcode hash, constructor
  arguments, expected address, and deployed runtime code hash.
- Because constructor arguments are part of initcode, a cross-chain identical
  address requires the same EntryPoint constructor argument as well as the same
  factory, salt, and initcode.
- A chain MUST NOT be advertised as sharing the official deterministic address
  until the selected factory is already installed with the expected code, or
  its canonical deployment transaction has been proven usable on that chain.
  A chain that requires another factory belongs to a separate address family.

### SDK Integration Requirements (Cross-Repo)

These requirements apply to the separate `defi-simplify` Go SDK. They are not
part of the Solidity ABI freeze:

- The v1 SDK MUST reject EIP-7702 authorizations whose authorization `chain_id`
  is zero. Universal authorizations are out of scope for v1; normal
  authorizations MUST use the active chain ID.
- The SDK MUST support custom deployment manifests. A custom manifest MUST pin
  both address and runtime code hash and MUST distinguish a reproducibly built,
  direct immutable artifact from user-trusted unknown code. Unknown code MUST
  NOT be presented as specification-compliant or project-verified.
- The SDK MUST generate unique assertion snapshot IDs within
  `(transaction, account)` when composing multiple logical flows.
- Protocol adapters MUST derive calldata, account-binding, and return offsets
  from structured ABIs and provide distinct-sentinel golden tests.
- The cross-repo integration suite MUST test universal-authorization rejection,
  custom manifest trust levels, both generic assertion modes, and exact
  Go/Solidity offset agreement.

## 2. IDefiSimplify7702Account

The public interface is conceptually:

```solidity
interface IDefiSimplify7702Account {
    enum BalanceSource {
        CurrentBalance,
        CheckpointDelta
    }

    struct BalanceCheckpoint {
        address token;
        bytes32 id;
    }

    struct BalancePatch {
        address token;
        bytes32 checkpointId;
        uint32 offset;
        uint16 bps;
        BalanceSource source;
    }

    struct DynamicCall {
        address target;
        uint256 value;
        bytes data;
        BalanceCheckpoint[] checkpointsBefore;
        BalancePatch[] patches;
    }

    function executeBatchDynamic(DynamicCall[] calldata calls) external payable;
}
```

The implementation MUST advertise the custom interface through ERC-165 in
addition to every interface supported by the inherited account.

## 3. Construction and State

The account MUST inherit the pinned `Simple7702Account` without editing upstream
source.

For the v0.9.0 baseline, construction is conceptually:

```solidity
constructor(IEntryPoint entryPoint) Simple7702Account(entryPoint) {}
```

The implementation MUST NOT define permanent storage variables. Constants and
immutables are allowed. Checkpoint state and the execution lock MUST use
transient storage with domain-separated keys.

The contract MUST NOT be upgradeable and MUST NOT have an owner, admin,
withdrawal function, protocol registry, or protocol allowlist.

The deployed account and `FlowAssertions` targets MUST be direct immutable
contracts, not proxies. A runtime code-hash match alone does not prove that a
target is not a proxy; official manifests MUST bind the hash to a reproducible
direct-deployment artifact and verified source.

## 4. Authorization

`executeBatchDynamic` MUST call inherited `_requireForExecute()` before reading
or changing execution state.

This allows only:

- a call where `msg.sender == address(this)`, which is the normal EOA-to-self
  delegated transaction path; or
- the immutable EntryPoint selected at deployment.

The custom function MUST NOT introduce a second signature scheme, nonce, role,
session key, or relayer authorization in v1.

## 5. Dynamic Execution Lock

`executeBatchDynamic` MUST use a transient reentrancy lock.

- Entering while the lock is set MUST revert `DynamicExecutionReentered()`.
- The lock MUST be set after authorization and before processing calls.
- The lock MUST be cleared before successful return.
- A revert naturally rolls back the lock write.
- A dynamic call whose `target == address(this)` MUST revert. This prevents
  authorized but malformed plans from creating nested self-execution paths.

The inherited static `execute` and `executeBatch` behavior remains upstream
behavior and is not modified by this requirement.

## 6. Checkpoint Model

Each `BalanceCheckpoint` records an ERC20 balance after its containing call's
patches are resolved and immediately before the target is called. Resolving
patches does not change chain state.

Requirements:

- `token` MUST NOT be the zero address.
- `id` MUST NOT be zero.
- An ID MUST be unique within one `executeBatchDynamic` invocation, independent
  of token.
- A patch MUST NOT consume a checkpoint declared on the same call; only
  checkpoints created by earlier calls are visible while patches are resolved.
- Duplicate IDs MUST revert `CheckpointAlreadyExists(callIndex, checkpointIndex, id)`.
- The token balance MUST be read with `STATICCALL balanceOf(address(this))`.
- A failed call or return value shorter than 32 bytes MUST revert
  `BalanceReadFailed(token, reason)`.
- The implementation MUST store checkpoint presence, token, and value in
  separate domain-separated transient slots.
- A later invocation in the same transaction MUST NOT be able to observe
  checkpoint state from an earlier invocation. Implementations MAY clear
  checkpoint slots or include a transient invocation counter in checkpoint key
  derivation. This is an observable isolation requirement, not a required
  cleanup mechanism.

Checkpoint IDs are opaque SDK-generated identifiers. They have no global or
cross-transaction meaning.

## 7. Patch Model

### 7.1 Offset

`offset` is a byte offset from the beginning of `DynamicCall.data`, including
the function selector.

For every patch:

- `offset` MUST be at least 4;
- `(offset - 4) % 32` MUST equal zero;
- `uint256(offset) + 32` MUST be less than or equal to `data.length`;
- patches in one call MUST be strictly increasing by offset.

Violations MUST revert with indexed custom errors. Strict ordering rejects
duplicates without an O(n squared) duplicate scan. The SDK is responsible for
sorting patches before encoding.

The contract MUST copy `data` to memory before patching. Solidity calldata MUST
not be treated as writable memory.

### 7.2 Basis Points

`bps` MUST be in the inclusive range 1 through 10,000. Any other value MUST
revert `InvalidBps(callIndex, patchIndex, bps)`.

The resolved amount is:

```text
floor(base * bps / 10_000)
```

The implementation MUST use a full-precision `mulDiv` operation so intermediate
multiplication cannot overflow.

Percentages are resolved from the balance visible at each patch time. Across
different calls, an earlier call that actually consumes tokens reduces the base
seen by a later patch. For example, splitting a delta equally across two
consumer calls uses 5,000 bps for the first call and 10,000 bps for the second
call's remaining delta. Multiple patches on the same call see the same
pre-call balance because no token consumption occurs between patch resolutions.

### 7.3 CurrentBalance

For `CurrentBalance`:

- `checkpointId` MUST be zero;
- `base` is `IERC20(token).balanceOf(address(this))` at patch time.

This mode explicitly includes all pre-existing account inventory.

### 7.4 CheckpointDelta

For `CheckpointDelta`:

- `checkpointId` MUST be non-zero and already created earlier in the current
  invocation;
- the checkpoint token MUST equal `patch.token`;
- `base` is `currentBalance - checkpointBalance`;
- if current balance is lower than checkpoint balance, execution MUST revert
  `BalanceBelowCheckpoint(token, checkpointId, current, checkpoint)`.

Missing or token-mismatched checkpoints MUST have distinct custom errors.
The implementation MUST NOT silently clamp a negative delta to zero.

### 7.5 Patched Word

The resolved unsigned integer MUST replace exactly 32 bytes beginning at
`offset`. No other calldata byte may change.

The contract MAY resolve a zero amount. Protocol calls or explicit assertions
decide whether zero is acceptable; v1 does not add a generic non-zero policy.

## 8. Call Execution

Calls MUST execute in array order and MUST use EVM `CALL`, forwarding the
declared `value` and remaining gas.

Each `calls[i].value` is paid from the delegated account's native balance. The
implementation MUST NOT require `sum(calls[i].value) <= msg.value`; `msg.value`
does not define a per-batch spending budget. Insufficient account balance is
handled by the underlying failed call and atomic revert.

Before each call, the implementation MUST:

1. reject a zero target;
2. reject `target == address(this)`;
3. validate and apply patches in array order using earlier checkpoints;
4. create that call's checkpoints in array order;
5. call the target with patched memory.

The return data of successful calls is discarded in v1.

Any failed call MUST revert:

```solidity
error DynamicCallFailed(uint256 index, address target, bytes reason);
```

`reason` MUST contain the target's complete revert data. The wrapper is used
even for a one-call dynamic batch so SDK decoding is consistent.

An empty batch MUST revert `EmptyDynamicBatch()`.

## 9. Required Account Errors

Exact names may change once before implementation freezes the ABI, but the
final contract MUST provide equivalent indexed information:

```solidity
error EmptyDynamicBatch();
error DynamicExecutionReentered();
error InvalidTarget(uint256 callIndex, address target);
error InvalidCheckpointToken(uint256 callIndex, uint256 checkpointIndex);
error InvalidCheckpointId(uint256 callIndex, uint256 checkpointIndex);
error CheckpointAlreadyExists(uint256 callIndex, uint256 checkpointIndex, bytes32 id);
error CheckpointNotFound(uint256 callIndex, uint256 patchIndex, bytes32 id);
error CheckpointTokenMismatch(uint256 callIndex, uint256 patchIndex, bytes32 id, address expected, address actual);
error InvalidPatchToken(uint256 callIndex, uint256 patchIndex);
error InvalidPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 offset, uint256 dataLength);
error UnsortedPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 previous, uint256 current);
error InvalidBps(uint256 callIndex, uint256 patchIndex, uint256 bps);
error UnexpectedCheckpointId(uint256 callIndex, uint256 patchIndex, bytes32 id);
error BalanceReadFailed(address token, bytes reason);
error BalanceBelowCheckpoint(address token, bytes32 id, uint256 current, uint256 checkpoint);
error DynamicCallFailed(uint256 index, address target, bytes reason);
```

Errors from inherited static execution remain unchanged.

## 10. IFlowAssertions

The v1 interface is conceptually:

```solidity
interface IFlowAssertions {
    function snapshotBalance(address token, bytes32 checkpointId) external;

    function assertBalanceAtLeast(
        address token,
        uint256 minimum
    ) external view;

    function assertBalanceIncreaseAtLeast(
        address token,
        bytes32 checkpointId,
        uint256 minimumDelta
    ) external view;

    function assertBalanceDecreaseAtMost(
        address token,
        bytes32 checkpointId,
        uint256 maximumDelta
    ) external view;

    function assertAaveHealthFactorAtLeast(
        address pool,
        uint256 minimumHealthFactor
    ) external view;

    function assertStaticCallUint256AtLeast(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 minimum
    ) external view;

    function assertStaticCallUint256AtMost(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 maximum
    ) external view;
}
```

### 10.1 Assertion Identity

All balance reads MUST check `msg.sender`. The API MUST NOT accept an arbitrary
account parameter. This prevents the SDK from accidentally asserting the wrong
account.

Snapshot keys MUST include `msg.sender` and checkpoint ID. A snapshot stores
presence, token, and value separately in transient storage.

`snapshotBalance` MUST reject a zero token, zero checkpoint ID, or duplicate ID
for the same sender in the current transaction. Snapshot IDs are sender-scoped;
different accounts may use the same ID safely.

Assertion snapshots are intentionally transaction-scoped and are not consumed
or cleared by successful assertions. Cross-repo SDK namespacing requirements are
defined in the integration subsection of Section 1. This lifecycle is
intentionally different from account checkpoint invocation isolation so one
snapshot can support multiple assertions.

### 10.2 Balance Assertions

- `assertBalanceAtLeast` passes when current balance is greater than or equal to
  `minimum`.
- `assertBalanceIncreaseAtLeast` computes a saturating increase: if current is
  below checkpoint, actual increase is zero. It passes when actual increase is
  at least `minimumDelta`.
- `assertBalanceDecreaseAtMost` computes a saturating decrease: if current is
  above checkpoint, actual decrease is zero. It passes when actual decrease is
  at most `maximumDelta`.
- A missing checkpoint or token mismatch MUST revert before evaluating the
  threshold.

Failure errors MUST include token, actual value or delta, and required bound.

### 10.3 Aave Health Factor

`assertAaveHealthFactorAtLeast` MUST call the supplied Aave-compatible Pool's
`getUserAccountData(msg.sender)` and compare the returned health factor against
`minimumHealthFactor`.

The function MUST NOT use an independent oracle. Its result intentionally uses
the Pool's own account and oracle view.

Failure MUST include pool, actual health factor, and minimum health factor.

### 10.4 Generic Uint256 Assertions with Optional Account Binding

The generic assertions are a narrow bridge for protocol reads that return a
fixed-position `uint256`. `accountOffset` selects one of two explicit modes:

- `accountOffset == type(uint32).max` means global-read mode. The input calldata
  is not modified.
- Any other value means account-binding mode. The designated ABI word is
  overwritten with `msg.sender` before `STATICCALL`.

For both generic functions, the implementation MUST:

1. reject a zero target and `target == address(this)`;
2. require at least four bytes of call data;
3. when `accountOffset != type(uint32).max`, require `accountOffset >= 4`,
   `(accountOffset - 4) % 32 == 0`, and
   `uint256(accountOffset) + 32 <= data.length`;
4. copy `data` to memory and, in account-binding mode only, replace exactly the
   word at `accountOffset` with zero-left-padded `msg.sender`;
5. perform `STATICCALL` with the patched data;
6. require `returnOffset % 32 == 0` and
   `returnOffset + 32 <= returndata.length`;
7. interpret exactly that return word as `uint256` and apply the selected bound.

Account binding is an adapter-safety guardrail, not an authorization boundary.
For Solidity targets whose ABI decoder ignores trailing calldata, a caller can
append an unused word and point `accountOffset` to it while the target reads its
real arguments unchanged. Global reads are therefore a supported capability,
but compliant adapters MUST express them with the explicit
`type(uint32).max` sentinel rather than a padding bypass. Account-bound adapter
tests MUST prove that changing the bound subject changes the selected result.

Protocol adapters follow the cross-repo ABI and golden-test requirements in
Section 1. Binding-mode fixtures use distinct values for the real account word,
appended padding, selected return word, and adjacent return words. Global-mode
fixtures cover rates and account-independent conversion or quote reads.

Generic assertion failures MUST include target, selector, offsets, actual
value, and bound where applicable. The SDK is responsible for mapping this
low-level context back to protocol language.

### 10.5 Required Assertion Errors

The final ABI MUST provide equivalent information to:

```solidity
error InvalidAssertionToken(address token);
error InvalidAssertionCheckpointId(bytes32 id);
error AssertionCheckpointAlreadyExists(address account, bytes32 id);
error AssertionCheckpointNotFound(address account, bytes32 id);
error AssertionCheckpointTokenMismatch(address account, bytes32 id, address expected, address actual);
error AssertionBalanceReadFailed(address token, bytes reason);
error BalanceBelowMinimum(address token, uint256 actual, uint256 minimum);
error BalanceIncreaseTooSmall(address token, bytes32 id, uint256 actualDelta, uint256 minimumDelta);
error BalanceDecreaseTooLarge(address token, bytes32 id, uint256 actualDelta, uint256 maximumDelta);
error AaveAccountDataReadFailed(address pool, bytes reason);
error AaveHealthFactorTooLow(address pool, uint256 actual, uint256 minimum);
error InvalidAssertionTarget(address target);
error InvalidAssertionCallData(uint256 dataLength);
error InvalidAssertionAccountOffset(uint256 offset, uint256 dataLength);
error InvalidAssertionReturnOffset(uint256 offset, uint256 returnDataLength);
error AssertionStaticCallFailed(address target, bytes4 selector, uint256 accountOffset, bytes reason);
error StaticCallUint256BelowMinimum(address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 minimum);
error StaticCallUint256AboveMaximum(address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 maximum);
```

## 11. FlowAssertions State and Authority

`FlowAssertions` MUST:

- have no owner or admin;
- have no upgrade path;
- have no permanent storage;
- have no payable asset-moving method;
- be callable by any account;
- use only transient state for snapshots;
- expose custom errors rather than string reverts.

## 12. Event Policy

`DefiSimplify7702Account` v1 and `FlowAssertions` v1 MUST NOT emit custom
execution or assertion events. Transaction receipts, target protocol events,
token events, and traces are the v1 observability surface.

## 13. Static Compatibility

The following inherited behavior MUST remain byte-for-byte ABI compatible with
the pinned upstream release:

- `execute(address,uint256,bytes)`;
- `executeBatch(BaseAccount.Call[])`;
- `validateUserOp`;
- `isValidSignature`;
- `supportsInterface` for upstream interfaces;
- token receiver callbacks;
- fallback and receive behavior.

The test suite MUST execute identical static call arrays through the upstream
account and custom account and compare final state and failure attribution.

## 14. Explicit v1 Non-Requirements

v1 does not support:

- dynamic native-asset balance or call-value patching;
- patching from return data;
- arbitrary arithmetic expressions;
- signed integers or negative deltas;
- callback or flash-loan receivers;
- delegatecall targets;
- protocol allowlists or policy engines;
- session keys;
- batch deadlines at account level;
- oracle assertions other than protocol-native reads;
- EIP-7702 universal authorization with authorization `chain_id == 0`;
- upgradeability.

Protocol calldata may still contain its own deadlines, slippage limits, price
bounds, referral codes, receiver addresses, and protocol-specific safeguards.

## 15. Acceptance Tests

At minimum, the implementation MUST pass:

- authorization tests for self, configured EntryPoint, random callers, and
  malicious callback callers;
- static compatibility tests against pinned upstream;
- one and many call success tests;
- call failure index and nested revert decode tests;
- checkpoint create, consume, duplicate, missing, token mismatch, invocation
  isolation, and same-token multi-checkpoint tests;
- same-call checkpoint references failing before target execution;
- existing-inventory tests where a token is spent before being received again;
- current-balance explicit sweep tests;
- bps boundary and `mulDiv` property tests;
- offset lower-bound, alignment, upper-bound, sorting, and byte-for-byte golden
  tests against Go-generated calldata;
- malformed and reverting ERC20 `balanceOf` tests;
- self-target and dynamic reentrancy tests;
- FlowAssertions success and forced-failure tests;
- assertion snapshot zero, duplicate, missing, and token-mismatch tests;
- two logical assertion flows in one transaction using namespaced snapshot IDs;
- generic assertion bound and global modes, account-word replacement, explicit
  no-binding sentinel, documented padding bypass, input and return offset
  bounds, adjacent sentinel return words, staticcall failure, and both
  comparison directions;
- deterministic deployment address calculation, factory code-hash validation,
  manifest reproduction, direct-artifact verification, and custom manifest
  tests;
- confirmation that successful v1 execution emits no custom account or
  assertion events;
- Aave plus Uniswap fork flow with final health-factor failure rollback;
- Morpho and Pendle adapter-level fork tests before claiming compatibility;
- gas snapshots for representative static and dynamic batches.
