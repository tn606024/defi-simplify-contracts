# Deployments

> [!WARNING]
> The contracts are experimental and unaudited by an independent third party.
> Repository-authored tests, analysis, fork proofs, deterministic addresses,
> source-verification inputs, deployment reproduction, and review evidence are
> not an independent audit or security guarantee. Total and irreversible loss
> is possible. No warranty is provided.

## Base v1.1.0 deployment candidate

[`base-v1.1-candidate.json`](base-v1.1-candidate.json) is the active,
machine-readable deployment candidate for the current 10,000-optimizer-run
build. It freezes the reviewed artifact source commit and tree, build and
dependency locks, ABI hashes, factory and EntryPoint identities, distinct
versioned salts, complete initcode hashes, predicted CREATE2 addresses, and
final direct-runtime hashes.

It is deliberately marked `candidate`, `unreleased`, and `not-broadcast`.
`intendedTrustLevel: "official"` records future intent only. The manifest does
not assign a trust level or contain deployed addresses, transaction evidence,
source-verification claims, or an audit URL.

| Artifact | Predicted Base address | Runtime code hash |
| --- | --- | --- |
| `DefiSimplify7702Account` | `0x9B1854c65Ce4656349d04e612260dFCEaf5B1d69` | `0x3ccebf2c563db0b2284a322ed5a53067ba4a561949973f375e267a3230babc00` |
| `FlowAssertions` | `0xEd66a41f7d87C6aC68c524075836B2F0DaD87a16` | `0xadbf11b88ce66db628549fa169006eb55e88c382708716ddb7c1c9c1d9b754c5` |
| `StaticCallUint256Assertions` | `0x28734029a24448cAA307D286823cA21DC57e8393` | `0xb6ed9520e6684c6b4342d03c92f4995ca2774ac909306f7876d8cdf047ecf9f6` |

These are predicted addresses, not deployments. Code existence must be checked
again immediately before any separately approved broadcast.

### Reproduce the candidate

Use the repository-pinned toolchain and dependency revisions:

```sh
export PATH="$HOME/.foundry/bin:$PATH"
make check
./script/generate-base-v1.1-candidate-manifest.sh
./script/check-base-v1.1-candidate-manifest.sh
./script/generate-base-v1.1-verification-inputs.sh
```

The generated Standard JSON inputs under
`out/verification/base-v1.1-candidate/` contain only each selected contract and
its metadata-derived transitive source closure. They exclude tests, scripts,
build output, and unrelated production contracts. They are preparation
artifacts only and must not be submitted to an explorer under this candidate
ticket.

With `BASE_RPC_URL`, verify the live prerequisites, candidate-address vacancy,
actual-factory behavior on a disposable fork, and the dry-run script:

```sh
make check-base-candidate

forge test \
  --match-path 'test/fork/BaseDeploymentCandidateFactory.t.sol' \
  --fork-url "$BASE_RPC_URL"
```

`DeployBaseV1_1Candidate.s.sol` rejects Forge broadcast and resume contexts.
A later live-deployment ticket must receive explicit maintainer approval and
review a separate change before that guard can be removed.

## Retired Base v1.0.0 deployment

[`base-v1.json`](base-v1.json) is the historical official manifest for three
direct, immutable Base deployments published as the experimental
[`v1.0.0`](https://github.com/tn606024/defi-simplify-contracts/releases/tag/v1.0.0)
release. That release is retired and unsupported. Its addresses, salts,
200-optimizer-run artifacts, and manifest must not be relabeled or reused as
the active build.

| Artifact | Retired Base address | Deployment transaction | Runtime code hash |
| --- | --- | --- | --- |
| `DefiSimplify7702Account` | [`0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA`](https://basescan.org/address/0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA#code) | [`0xa69ad7…f982d`](https://basescan.org/tx/0xa69ad7e56a4937966cf7d30dfcee4e5458e208ec2e87423db5f60e87726f982d) | `0xfa67c14b1dc7e1b822ef9f905bc20862750f03f0db40bed7f86e65df7a53067f` |
| `FlowAssertions` | [`0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5`](https://basescan.org/address/0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5#code) | [`0x720d38…d301`](https://basescan.org/tx/0x720d38a30f78acf37f5321f66eb421f84974830905da586b0623f33257add301) | `0xeb7361327bf94a7a05adb4a2f27d5203eb1c81356b1e4694bc9f1098ebc3882c` |
| `StaticCallUint256Assertions` | [`0x034ee940A644323463AB074DCA99504BF5a666EA`](https://basescan.org/address/0x034ee940A644323463AB074DCA99504BF5a666EA#code) | [`0x90278c…df0d`](https://basescan.org/tx/0x90278c7af9e0e2acffb61be6cc84118e1a86d500d440dcc33b2895b2b4acdf0d) | `0xc26f9f8ce08cbeb069a32ac005b6a6c26dd878cb085295381f52e8de0f7e10d8` |

The historical manifest records `official` only as a project-published
artifact and deployment identity. It does not mean audited, safe,
SDK-integrated, production-ready, or recommended for capital. Historical
generation and transaction-checking scripts remain for the tagged v1.0.0
source state and are outside active current-source validation.

The checked-in complete deployment ABIs are:

- `abi/DefiSimplify7702Account.json`;
- `abi/FlowAssertions.json`; and
- `abi/StaticCallUint256Assertions.json`.

The existing `I*.json` fixtures remain the smaller cross-repository interface
and error surfaces.
