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
