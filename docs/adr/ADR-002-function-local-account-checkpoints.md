# ADR-002: Keep Account Checkpoints in Function-Local Memory

Status: accepted
Date: 2026-07-15
Linear issues: IAN-47, IAN-48

## Context

`executeBatchDynamic` creates named ERC20 balance checkpoints immediately before
producer calls and consumes them from later calls in the same invocation. v1
does not expose checkpoint lookup to targets, does not support callback or
flash-loan receivers, and executes every target with `CALL`. A target therefore
runs in a different call frame and never needs access to account checkpoint
records.

The earlier draft stored presence, token, and balance in three EIP-1153 slots per
checkpoint and added a transient invocation namespace. That design provided the
required isolation, but it made function-local data cross-frame state. It also
required repeated key hashing, multiple `TSTORE`/`TLOAD` operations, a presence
slot, and an invocation counter or cleanup strategy.

EIP-1153's security considerations recommend memory when data does not need to
survive the current call frame. Weiroll provides a relevant executor precedent:
its command execution carries intermediate state in a memory array. This project
uses the same locality principle, but does not adopt Weiroll's return-data piping
or general virtual-machine semantics.

The dynamic reentrancy lock is different. It exists specifically so a new frame
that reenters the delegated account can observe active execution. Function-local
memory cannot provide that property.

## Decision

### Account checkpoint representation

The canonical `executeBatchDynamic` implementation keeps account checkpoints in
one function-local memory array.

1. Before executing calls, sum every `calls[i].checkpointsBefore.length`.
2. Allocate one fixed-capacity array of checkpoint records.
3. Track the number of populated records.
4. Store `id`, `token`, and `balance` in each populated record.
5. Scan only the populated prefix for duplicate-ID checks and checkpoint lookup.

The populated length is the presence marker. A recorded zero balance is valid
and needs no sentinel. IDs remain unique across one invocation regardless of
token.

The specification defines the observable lifecycle: an external target and a
later invocation cannot observe checkpoint records, and records disappear on
return or revert. The canonical implementation achieves this lifecycle with
memory, without checkpoint transient keys, an invocation counter, or a cleanup
list.

### Same-call balance cache

An implementation may cache the pre-call balance once per token across patch
resolution and checkpoint creation for one call. No external call occurs between
those phases. The cache never crosses a target `CALL`.

When the cached read fails or returns fewer than 32 bytes, error attribution
belongs to the first logical consumer that triggered the read:

- a patch uses
  `PatchBalanceReadFailed(callIndex, patchIndex, token, reason)`;
- a checkpoint uses
  `CheckpointBalanceReadFailed(callIndex, checkpointIndex, token, reason)`.

This rule makes caching an implementation choice without changing observable
error attribution.

### Transient state that remains

The dynamic execution reentrancy lock remains in one explicitly
domain-separated EIP-1153 transient slot. It is set after authorization, visible
to reentrant frames, cleared before successful return, and rolled back by a
revert.

`FlowAssertions` snapshots also remain transient. They intentionally survive
multiple assertion calls in one transaction and are scoped to
`(transaction, msg.sender)`. This ADR changes only account checkpoint records.

## Alternatives Considered

### Transient checkpoint slots with an invocation namespace

Rejected for v1. It works, but stores frame-local data in a cross-frame mechanism
and adds hashing, slot-domain, presence, invocation-counter, and cleanup
complexity without enabling a supported behavior.

### Transient checkpoint slots cleared at the end

Rejected. A cleanup list duplicates the checkpoint table, costs more gas, and
creates another path that must be correct on success and revert. Revert semantics
do not solve isolation between multiple successful invocations in one
transaction.

### Permanent storage

Rejected. It would create storage-layout collision risk under EIP-7702
delegation, require lifecycle cleanup, and violate the no-custom-permanent-state
rule.

### A general Weiroll-compatible VM

Rejected for v1. Weiroll is a useful precedent for memory-carried executor state,
but return-data registers, arbitrary command semantics, and general-purpose
composition exceed the balance-delta primitive and increase the audit surface.

## Consequences

- Invocation isolation is structural rather than dependent on key derivation or
  cleanup correctness.
- External targets cannot read or mutate checkpoint records.
- Account checkpoints no longer consume transient-storage keys and cannot
  collide with upstream or future delegated implementations.
- The implementation performs linear scans over the populated records. With the
  expected v1 plan size (normally no more than a handful of checkpoints), this is
  simpler and expected to be cheaper than repeated hashing and transient access.
- Gas snapshots must compare representative one- and multi-checkpoint plans. If
  future plan sizes make linear lookup material, changing the in-memory lookup
  structure does not require an ABI change as long as observable semantics stay
  identical.
- Sequential same-transaction and same-ID reuse tests remain required regression
  tests even though memory provides isolation naturally.
- Callback-capable future accounts must make a new architectural decision if a
  callback frame needs access to active flow state.

## References

- https://eips.ethereum.org/EIPS/eip-1153#security-considerations
- https://github.com/weiroll/weiroll
- `docs/SPECIFICATION.md` Sections 3, 5, 6, and 15
- `docs/ARCHITECTURE.md` Section 4.4
- `docs/SECURITY.md` Section 7
