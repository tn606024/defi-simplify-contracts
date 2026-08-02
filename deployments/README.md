# Deployments

> [!WARNING]
> The contracts are experimental and unaudited by an independent third party.
> Repository-authored tests, analysis, fork proofs, deterministic addresses,
> source-verification inputs, deployment reproduction, and review evidence are
> not an independent audit or security guarantee. Total and irreversible loss
> is possible. No warranty is provided.

## Base v1.1.0 deployment

[`base-v1.1.json`](base-v1.1.json) is the active machine-readable deployment
record for the current 10,000-optimizer-run build. It derives every build and
CREATE2 identity from the unchanged
[`base-v1.1-candidate.json`](base-v1.1-candidate.json), then adds only observed
Base transactions, receipts, block hashes, fees, deployed addresses, and
runtime evidence.

| Artifact | Base address | Deployment transaction | Runtime code hash |
| --- | --- | --- | --- |
| `DefiSimplify7702Account` | [`0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69`](https://basescan.org/address/0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69#code) | [`0x9256cd…80855`](https://basescan.org/tx/0x9256cd73512476ad7ec3e955bbeb91d9b9f8d34d2c26aaafec0d18f4d4c80855) | `0x3ccebf2c563db0b2284a322ed5a53067ba4a561949973f375e267a3230babc00` |
| `FlowAssertions` | [`0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16`](https://basescan.org/address/0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16#code) | [`0x936043…d22c6`](https://basescan.org/tx/0x93604354100fef930e19b8924b624c8b1044d2360cbf62cd28aadba6437d22c6) | `0xadbf11b88ce66db628549fa169006eb55e88c382708716ddb7c1c9c1d9b754c5` |
| `StaticCallUint256Assertions` | [`0x28734029a24448cAA307D286823cA21DC57e8393`](https://basescan.org/address/0x28734029a24448cAA307D286823cA21DC57e8393#code) | [`0x944c82…b9900`](https://basescan.org/tx/0x944c827a13313750bd6ee282c2424a576b57bce73026bf31abcac34b7fbb9900) | `0xb6ed9520e6684c6b4342d03c92f4995ca2774ac909306f7876d8cdf047ecf9f6` |

The three canonical receipts have status `1`; their exact factory calldata and
deployed runtime hashes match the reviewed candidate. The account immutable
resolves to the frozen Base EntryPoint, and all three contracts are direct,
immutable, non-proxy artifacts.

All three direct contracts have exact-match BaseScan source verification from
the metadata-derived production source closures linked in the table. The
released manifest assigns `trustLevel: "official"` only as the
project-published artifact and deployment identity. It does not mean audited,
safe, SDK-integrated, production-ready, or recommended for capital. At the
v1.1.0 publication commit, the contracts remained independently unaudited,
experimental, and `not-integrated`; the manifest preserves that exact
release-time state.

The public [`defi-simplify` Go SDK](https://github.com/tn606024/defi-simplify)
later adopted this v1.1.0 deployment identity and supports inherited static and
custom dynamic account execution. That later compatibility fact does not
rewrite the tagged manifest. Full public SDK parity for typed assertions,
callback-plan construction, and every documented Base strategy remains
separate ongoing work.

### Reproduce the deployment record

Use the repository-pinned toolchain and dependency revisions:

```sh
export PATH="$HOME/.foundry/bin:$PATH"
make check
./script/generate-base-v1.1-candidate-manifest.sh
./script/check-base-v1.1-candidate-manifest.sh
./script/generate-base-v1.1-manifest.sh
./script/check-base-v1.1-manifest.sh
./script/generate-base-v1.1-verification-inputs.sh
./script/check-base-v1.1-verification-inputs.sh
./script/generate-base-v1.1-factory-payloads.sh
```

With `BASE_RPC_URL`, independently re-read the deployed transactions, receipts,
calldata, direct runtimes, EIP-1967 proxy slots, and account immutable:

```sh
./script/check-base-v1.1-onchain-deployment.sh
```

The generated Standard JSON inputs under
`out/verification/base-v1.1-candidate/` contain only each selected contract and
its metadata-derived transitive source closure. They exclude tests, scripts,
build output, and unrelated production contracts. They remain preparation
artifacts and reproducible submission evidence; generation alone does not
authorize another explorer submission.

The frozen candidate and its pre-broadcast factory proof remain reproducible at
the documented pre-deployment block:

```sh
forge test \
  --match-path 'test/fork/BaseDeploymentCandidateFactory.t.sol' \
  --fork-url "$BASE_RPC_URL"
```

`DeployBaseV1_1Candidate.s.sol` permanently rejects Forge broadcast and resume
contexts. DSC-91 used the separate reviewed `DeployBaseV1_1.s.sol` live path.
Both are thin version adapters over the reusable
`BaseDeployment.sol` engine and internal-only
`libraries/DeterministicDeployment.sol` identity primitives, so later versions
reuse the deployment and safety logic while retaining separate manifests,
salts, addresses, and evidence.

The preflight and vacancy checker are retained as historical pre-broadcast
evidence. They are expected to reject the now-occupied addresses and are not
active post-deployment gates.

The reviewed signer mechanism is a local encrypted Foundry keystore selected
by a named `--account`; the repository stores only the matching public
`BASE_V1_1_DEPLOYER_ADDRESS`. The broadcast was separately approved after the
final command, account name, address, preflight evidence, and clean commit were
reviewed. The live command remains outside `make check`.

The separately approved BaseScan submissions used one generated Standard JSON
file per contract. Each submitted file contained only that selected production
contract and its metadata-derived transitive source closure. No `test/`,
`script/`, `out/`, `cache/`, `broadcast/`, build-info, fixture, harness, or
unrelated production contract was submitted.

The checked-in complete deployment ABIs are:

- `abi/DefiSimplify7702Account.json`;
- `abi/FlowAssertions.json`; and
- `abi/StaticCallUint256Assertions.json`.

The existing `I*.json` fixtures remain the smaller cross-repository interface
and error surfaces.
