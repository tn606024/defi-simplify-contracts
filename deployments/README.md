# Deployments

> [!WARNING]
> The v1 contracts are experimental and unaudited. Reproducible bytecode,
> deterministic addresses, source verification, and tests are not an audit or
> a security guarantee. Total and irreversible loss is possible. No warranty is
> provided.

## Base v1 official deployment

`base-v1.json` is the official machine-readable manifest for three direct,
immutable Base deployments published as the experimental
[`v1.0.0`](https://github.com/tn606024/defi-simplify-contracts/releases/tag/v1.0.0)
release. `official` means that this repository publishes and reproduces their
exact artifact and deployment identities. It does **not** mean audited, safe,
SDK-integrated, production-ready, or recommended for capital.

The manifest deliberately records `released`, `unaudited`, `experimental`,
`not-integrated`, no independent audit plan, no security guarantee, no warranty,
and total-loss risk.

| Artifact | Base address | Deployment transaction | Runtime code hash |
| --- | --- | --- | --- |
| `DefiSimplify7702Account` | [`0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA`](https://basescan.org/address/0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA#code) | [`0xa69ad7…f982d`](https://basescan.org/tx/0xa69ad7e56a4937966cf7d30dfcee4e5458e208ec2e87423db5f60e87726f982d) | `0xfa67c14b1dc7e1b822ef9f905bc20862750f03f0db40bed7f86e65df7a53067f` |
| `FlowAssertions` | [`0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5`](https://basescan.org/address/0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5#code) | [`0x720d38…d301`](https://basescan.org/tx/0x720d38a30f78acf37f5321f66eb421f84974830905da586b0623f33257add301) | `0xeb7361327bf94a7a05adb4a2f27d5203eb1c81356b1e4694bc9f1098ebc3882c` |
| `StaticCallUint256Assertions` | [`0x034ee940A644323463AB074DCA99504BF5a666EA`](https://basescan.org/address/0x034ee940A644323463AB074DCA99504BF5a666EA#code) | [`0x90278c…df0d`](https://basescan.org/tx/0x90278c7af9e0e2acffb61be6cc84118e1a86d500d440dcc33b2895b2b4acdf0d) | `0xc26f9f8ce08cbeb069a32ac005b6a6c26dd878cb085295381f52e8de0f7e10d8` |

The deployments were submitted from
`0xb5FD9f60Fc6ca7662Ff22D09ec7832CD221fbcdD` through the Arachnid
Deterministic Deployment Proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. They were mined in Base
blocks `49,170,979` through `49,170,981`. BaseScan reports exact compiler-input
source verification for each direct artifact and reports no proxy
implementation.

## Reproduce the manifest

Use the repository-pinned toolchain and dependency revisions:

```sh
export PATH="$HOME/.foundry/bin:$PATH"
./script/check-foundry-version.sh
./script/check-account-abstraction-revision.sh
./script/check-forge-std-revision.sh
./script/check-base-v1-manifest.sh
./script/run-base-v1-historical-test.sh \
  test/unit/BaseDeploymentManifest.t.sol -vvv
```

The generator reads `config/base-v1-deployment.json`, checks out the exact
source commit recorded by the deployed manifest, validates the locked
account-abstraction revision, Base EntryPoint, and historical 200-run settings,
then reconstructs creation code, complete initcode, runtime code, hashes, and
CREATE2 addresses. The checker rejects any difference from the checked-in
manifest or any overstatement of audit, release, SDK, warranty, or security
status. Active ABI and direct-artifact checks belong to the separate v1.1
candidate build and run through `make check`.

Generate explorer verification inputs separately for each direct artifact:

```sh
./script/generate-base-v1-verification-inputs.sh
```

The generated Standard JSON files under `out/verification/base-v1/` contain
only the selected contract and its actual transitive imports, as recorded in
that contract's compiler metadata. They deliberately exclude `test/`,
`script/`, build output, and unrelated production contracts. Do not submit a
repository-wide Foundry build-info file to an explorer.

The checked-in complete deployment ABIs are:

- `abi/DefiSimplify7702Account.json`, including inherited and custom account
  functions;
- `abi/FlowAssertions.json`; and
- `abi/StaticCallUint256Assertions.json`.

The existing `I*.json` fixtures remain the smaller cross-repository interface
and error surfaces.

## Base v1.1 unbroadcast candidate

`base-v1.1-candidate.json` records the next direct immutable artifact family.
It is compiled with 10,000 optimizer runs and includes the account's
zero-capacity balance-cache allocation fast path. It is **unreleased,
unbroadcast, unverified, not SDK-integrated, experimental, and unaudited**.
DSC-86 owns the planned independent audit of the exact candidate commit.
`intendedTrustLevel: "official"` records intent only; no trust level has been
assigned and none of the predicted addresses is an official deployment.

| Artifact | Predicted address | Runtime size | Runtime code hash |
| --- | --- | ---: | --- |
| `DefiSimplify7702Account` | `0x92fE0373d4684a7428B6d723a93427e4D152DF6d` | 12,158 bytes | `0x3ccebf2c563db0b2284a322ed5a53067ba4a561949973f375e267a3230babc00` |
| `FlowAssertions` | `0xBDD175f69C799efFeD30192B49D8421d29CA2167` | 2,209 bytes | `0xadbf11b88ce66db628549fa169006eb55e88c382708716ddb7c1c9c1d9b754c5` |
| `StaticCallUint256Assertions` | `0x4BCdFef3B0aa0B4FF857E1557f2669870C57c77D` | 1,609 bytes | `0xb6ed9520e6684c6b4342d03c92f4995ca2774ac909306f7876d8cdf047ecf9f6` |

Reproduce both the active candidate and the historical official identity:

```sh
forge build
./script/check-base-v1-1-candidate-manifest.sh
./script/check-base-v1-manifest.sh
./script/run-base-v1-historical-test.sh \
  test/unit/BaseDeploymentManifest.t.sol -vvv
```

The historical checks build the exact source commit recorded by
`deployments/base-v1.json` with its original 200-run settings. CI fetches full
Git history so this build remains available after the repository default moves
to 10,000 runs.

## Independently verify Base evidence

The deployment script is idempotent. Against current Base state it reconstructs
all three identities and verifies the already-deployed runtimes without sending
a factory transaction:

```sh
./script/run-base-v1-historical-script.sh \
  script/DeployBaseV1.s.sol:DeployBaseV1 \
  --rpc-url "$BASE_RPC_URL"
```

The on-chain checker fetches the historical transactions and receipts through
the active RPC. It proves their sender, factory destination, salt, complete
initcode hash, successful receipt, mined block, and current runtime identity
against the official manifest:

```sh
./script/check-base-v1-onchain-deployment.sh

./script/run-base-v1-historical-test.sh \
  test/fork/BaseDeploymentFactory.t.sol \
  --fork-url "$BASE_RPC_URL"
```

The fork test independently reconstructs the official payloads and checks the
factory, EntryPoint, and current artifact runtimes from Solidity. None of these
commands broadcasts. Do not add `--broadcast`: the official addresses are
already occupied by the exact expected runtimes.
