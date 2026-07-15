# Security Model

Status: pre-implementation threat model
Date: 2026-07-15

## 1. Security Boundary

Delegating an EOA to an implementation gives that implementation the ability to
execute in the EOA's context. A defect in the account can affect every native
asset, token approval, and protocol position controlled by that address.

The primary boundary is therefore `DefiSimplify7702Account`, not the Go SDK.
Simulation and SDK validation reduce mistakes but cannot compensate for an
authorization or arbitrary-call vulnerability in delegated code.

`FlowAssertions` is outside the account authority boundary because it cannot
move assets. It remains security-sensitive because an incorrect assertion can
allow an unsafe flow or reject a safe one.

## 2. Protected Properties

The implementation must preserve these invariants:

1. Only the delegated EOA itself or the configured EntryPoint can enter an
   execution function.
2. An untrusted target cannot reenter dynamic execution.
3. A patch changes exactly one validated 32-byte calldata word.
4. Checkpoint delta never includes inventory from before the named checkpoint.
5. Missing, mismatched, or negative deltas never silently become valid amounts.
6. Any target or assertion failure reverts every protocol and asset change made
   by the execution portion.
7. The custom account and checker write no permanent storage.
8. Static inherited behavior remains compatible with pinned upstream behavior.
9. Account checkpoint records remain function-local and cannot be observed by
   external target frames or later dynamic invocations.

## 3. Important Non-Guarantees

### Delegation Persists After Revert

EIP-7702 authorization processing occurs before transaction execution. A valid
delegation indicator is not rolled back when execution later fails. On the
first transaction, a flow can revert while the EOA remains delegated.

The project must never describe its guarantee simply as "only gas is lost."
The accurate statement is:

> Asset and protocol-state changes made by execution revert atomically. Gas and
> nonces are consumed, and a newly processed delegation may remain installed.

The SDK must show the delegation target and persistence before signing a first
authorization and must provide a tested redelegation or clearing path.

### Simulation Is Not a Proof

State can change between simulation and inclusion. RPC state override and trace
support vary by provider. A malicious or incorrect implementation could also
behave differently under unusual environment conditions.

Critical economic bounds must be enforced by protocol-native limits and final
on-chain assertions, not only simulation output.

### Failure Attribution Is Not Guaranteed Under Gas Exhaustion

`DynamicCallFailed` preserves complete target revert data and v1 does not
silently truncate it. A malicious target can return enough data to make copying
and wrapping it exhaust the caller's remaining gas. Atomic rollback still
holds, but the transaction may fail without the indexed wrapper. This is an
accepted v1 gas-griefing risk because authorized target code and calldata can
already consume forwarded gas. A future cap must use an explicit truncated-data
error with original length metadata; it must not silently change the current
ABI promise.

### Assertions Inherit Protocol Trust

The Aave health-factor assertion trusts the supplied Pool and Aave's oracle
view. It does not protect against oracle design risk, governance changes, slow
depegs, or a wrong Pool address supplied by the SDK.

Generic assertion account binding is a defense against accidental adapter
misconfiguration, not a hard security boundary. Solidity targets may ignore
trailing calldata, allowing a deliberately padded call to leave the real target
arguments unmodified. Global reads are supported through the explicit
`type(uint32).max` no-binding sentinel; reviewed adapters must not use padding
as an implicit bypass.

### Universal Authorization Is Not a Chain Allowlist

An EIP-7702 authorization with `chain_id == 0` is replayable on any chain where
the authorization is otherwise valid. Deterministic deployment does not narrow
that replay scope. A chain where the delegation target has no code may execute
the delegated call as a successful no-op, leaving a persistent but unusable
delegation. v1 therefore rejects universal authorization and signs only for the
active chain ID.

## 4. Threats and Mitigations

| Threat | Required mitigation |
| --- | --- |
| Random caller invokes account execution | Inherited `_requireForExecute()` on every custom entrypoint |
| Malicious protocol calls back into account | Authorization check plus transient dynamic lock |
| Nested self-call corrupts checkpoints | Reject `target == address(this)` in dynamic calls |
| Patch writes selector, pointer, length, or unrelated bytes | Selector-relative alignment, bounds, sorted offsets, Go/Solidity golden tests |
| Same token spent then received gives wrong delta | Named checkpoints placed immediately before the producer call |
| Existing inventory is swept | CheckpointDelta as safe SDK default; CurrentBalance requires explicit API |
| Checkpoint ID collision or overwrite | Invocation-unique nonzero IDs, populated-memory-prefix presence, duplicate rejection, function-local isolation |
| ERC20 returns malformed balance data | Low-level staticcall with success and returndata-length validation |
| Multiplication overflow | Full-precision `mulDiv` |
| Underflow hidden as zero | `BalanceBelowCheckpoint` revert |
| Target revert loses attribution | `DynamicCallFailed(index, target, reason)` |
| Huge target revert data exhausts wrapper gas | Accepted v1 non-guarantee; bounded preservation and OOG characterization tests; no silent truncation |
| Router pulls less than an exact patched approval | SDK option appends `approve(spender, 0)` cleanup; adapters preserve zero-first token sequencing |
| Upstream storage layout changes | No permanent custom storage; pin and review every upstream revision |
| Implementation address is replaced in SDK config | Verify delegation target and runtime code hash against signed/reviewed manifest |
| Proxy code hash stays stable while logic changes | Official manifests bind to reproducible direct immutable artifacts; proxies and upgrade admins are forbidden |
| Wrong typed assertion account | Typed checkers derive the subject from `msg.sender` |
| Generic assertion accidentally encodes another account | Binding mode overwrites the selected ABI word; subject-change golden tests verify the target reads it |
| Generic assertion deliberately uses ignored trailing padding | Binding is documented as a guardrail, not authorization; compliant global reads use the no-binding sentinel |
| Generic assertion reads an adjacent uint word | ABI alignment and bounds checks plus distinct sentinel return-word tests |
| Universal authorization is replayed cross-chain | v1 SDK rejects authorization `chain_id == 0` |
| Deterministic deployment metadata is substituted | Verify factory address/code hash, salt, full initcode hash, constructor args, expected address, and runtime code hash |
| First authorization flow reverts | UI/SDK explains persistent delegation and supports clear/redelegate |

## 5. Token Assumptions

The generic balance model assumes `balanceOf(address)` returns a conventional
32-byte unsigned balance.

Fee-on-transfer, rebasing, callback-enabled, blocklisted, pausable, or zero-first
approval tokens may have surprising behavior. Balance patching often improves
fee-on-transfer compatibility because it uses observed balances, but it is not
a blanket compatibility guarantee.

Protocol adapters must document token assumptions and add fork tests before a
token or market is presented as supported. The SDK should generate zero-first
approval sequences for tokens that require them and should avoid unlimited
approval by default. An exact patched approval can still leave residual
allowance when a router pulls less than the approved amount. The SDK should
offer an explicit cleanup option that appends `approve(spender, 0)` after the
flow and handles zero-first tokens correctly. The contract itself does not
guarantee allowance cleanup.

## 6. Calldata Patching Risk

The account deliberately does not know protocol ABIs. Therefore it cannot know
whether an aligned word is semantically an amount, an offset, a length, or a
receiver encoded as 32 bytes.

Safety depends on four layers:

1. the SDK derives offsets from structured ABI encoding, never byte-pattern
   search;
2. the contract enforces alignment, bounds, order, source, and bps validity;
3. golden tests compare the Go offset and Solidity patched bytes exactly;
4. the exact delegated transaction is simulated before submission.

Any adapter that hand-codes an offset without a golden test is incomplete.

## 7. Ephemeral State Risk

Account checkpoints are function-local memory records. External targets cannot
observe them, and later invocations receive fresh memory even within the same
transaction. Tests must retain sequential invocations, same-ID reuse, reverted
targets, duplicate IDs, and stale-checkpoint attempts as regression coverage of
this observable isolation.

The execution lock and FlowAssertions snapshots have different lifecycles and
remain in transient storage. Their keys must be domain-separated from upstream
and future custom features. The lock is cleared on successful return, and revert
semantics roll it back on failure. Tests must prove authorized reentrant frames
see the lock and that neither successful nor reverted execution leaves a stale
lock. See ADR-002.

## 8. EntryPoint and Signature Risk

The selected EntryPoint is immutable in the v0.9.0 upstream account. Every
deployment must verify its address and code hash. ERC-4337 is optional transport
for this project, but an incorrect EntryPoint selection affects the inherited
authorization path.

Base v1 pins EntryPoint `0x433709009B8330FDa32311DF1C2AFA402eD8D009` and
runtime code hash
`0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`.
The Base fork suite must fail if the address has no code, the chain ID is not
8453, or the hash changes.

The custom contract must not alter upstream signature validation. Changes to
the pinned account-abstraction release require a new review and deployment, not
an automatic dependency update.

The EntryPoint address is not prohibited as a dynamic target: inherited
`depositTo` is a valid account-funding operation. A dynamic call from the
delegated account to the pinned v0.9 EntryPoint's `handleOps` is rejected first
by EntryPoint's own `Reentrancy()` modifier because the caller is a code-bearing
delegated account. That real-path test does not exercise the account lock. A
separate configured mock EntryPoint must reenter through the authorized path to
prove the account's transient lock returns `DynamicExecutionReentered()`.

The March 2025 Spearbit report in the pinned repository predates the v0.9
implementation commit. No v0.9-specific audit evidence was found, and BaseScan
lists no submitted audit for the selected EntryPoint. The project therefore
does not label the v0.9 baseline audited. See ADR-001 for commit comparison,
license obligations, release-note risks, and the update rule.

Official v1 deployments use Foundry's default Arachnid factory at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, but factory, salt, and complete
initcode are all part of the security identity. Since initcode contains the
immutable EntryPoint constructor argument, cross-chain address equality also
requires the same EntryPoint argument. The EntryPoint address and code hash must
both be verified.

Factory availability is a chain-level prerequisite. The original keyless
deployment transaction may be unusable on chains that require EIP-155 replay
protection. Until the factory code or a usable canonical installation path is
verified, the project must not promise the official address on that chain. A
Safe Singleton Factory deployment is an alternate address family, not a way to
preserve the Arachnid-derived address.

Runtime code-hash verification does not by itself prove that a target is not a
proxy. Official manifests must identify a reproducibly built direct immutable
artifact. A custom manifest may pin user-deployed code, but the SDK must label
unknown code separately from a verified project artifact.

## 9. Operational Guidance

Before an audit and production maturity:

- use a dedicated operation EOA with limited funds;
- test on a fork and testnet, then use small real amounts;
- verify implementation address and runtime code hash independently;
- avoid keeping unrelated valuable approvals or assets on the delegated EOA;
- set protocol deadlines, slippage bounds, and final assertions;
- use private order flow for leverage and other MEV-sensitive transactions when
  the selected chain and provider support it, while documenting the provider's
  trust and inclusion assumptions;
- monitor delegation state and implementation availability;
- keep a tested transaction path for redelegation to zero or a known-safe
  implementation.

Self-deployment is supported when the user pins a custom manifest. Using the
same deterministic factory, salt, and initcode reproduces the same address;
deploying the same direct artifact by another method may reproduce runtime code
without reproducing the address. Self-deployment changes who performs the
deployment, not the requirement for immutable verified code.

## 10. Verification Gates

No production-ready claim may be made until all are complete:

- full unit, fuzz, invariant, adversarial, and fork suite;
- Slither with reviewed findings;
- property tests for patch byte isolation and amount math;
- differential static tests against upstream;
- source verification and reproducible deployment;
- deterministic deployment manifest reproduction and factory code-hash checks;
- direct-artifact and no-proxy verification for account and assertions;
- generic assertion bound/global-mode and padding-bypass golden tests with
  distinct sentinels;
- cross-repo SDK tests proving universal authorization is rejected;
- independent security review of combined inherited and custom bytecode;
- public disclosure of unresolved assumptions and accepted risks.

An upstream audit does not audit this extension. Until independent review is
complete, the repository must label the custom account unaudited.

## 11. Security References

- Reference project: https://github.com/tn606024/defi-simplify
- Simple7702Account v0.9.0 pinned source: https://github.com/eth-infinitism/account-abstraction/blob/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410/contracts/accounts/Simple7702Account.sol
- Base EntryPoint v0.9.0 verification: https://basescan.org/address/0x433709009B8330FDa32311DF1C2AFA402eD8D009#code
- EIP-7702 security considerations: https://eips.ethereum.org/EIPS/eip-7702#security-considerations
- EIP-1153 security considerations: https://eips.ethereum.org/EIPS/eip-1153#security-considerations
- Foundry `cast create2` default deployer: https://getfoundry.sh/cast/reference/cast-create2
- Arachnid Deterministic Deployment Proxy: https://github.com/Arachnid/deterministic-deployment-proxy
- Safe Singleton Factory: https://github.com/safe-fndn/safe-singleton-factory
- Solidity transient-storage guidance: https://docs.soliditylang.org/en/latest/contracts.html#transient-storage
- account-abstraction releases: https://github.com/eth-infinitism/account-abstraction/releases
