# Deployments

> [!WARNING]
> The v1 contracts are experimental and unaudited. Reproducible bytecode,
> deterministic addresses, source verification, and tests are not an audit or
> a security guarantee. Total and irreversible loss is possible. No warranty is
> provided.

## Base v1 official deployment

`base-v1.json` is the official machine-readable manifest for three direct,
immutable Base deployments. `official` means that this repository publishes and
reproduces their exact artifact and deployment identities. It does **not** mean
audited, safe, released, SDK-integrated, or production-ready.

The manifest deliberately records `unreleased`, `unaudited`, `experimental`,
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
forge build
./script/generate-base-v1-manifest.sh
./script/check-base-v1-manifest.sh
./script/check-abi-fixtures.sh
./script/check-direct-immutable-artifacts.sh
```

The generator reads `config/base-v1-deployment.json`, validates the locked
account-abstraction revision, Base EntryPoint, and effective Foundry settings,
then reconstructs creation code, complete initcode, runtime code, hashes, and
CREATE2 addresses. The checker rejects any difference from the checked-in
manifest or any overstatement of audit, release, SDK, warranty, or security
status.

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

## Independently verify Base evidence

The deployment script is idempotent. Against current Base state it reconstructs
all three identities and verifies the already-deployed runtimes without sending
a factory transaction:

```sh
forge script script/DeployBaseV1.s.sol:DeployBaseV1 \
  --rpc-url "$BASE_RPC_URL"
```

The on-chain checker fetches the historical transactions and receipts through
the active RPC. It proves their sender, factory destination, salt, complete
initcode hash, successful receipt, mined block, and current runtime identity
against the official manifest:

```sh
./script/check-base-v1-onchain-deployment.sh

forge test \
  --match-path 'test/fork/BaseDeploymentFactory.t.sol' \
  --fork-url "$BASE_RPC_URL"
```

The fork test independently reconstructs the official payloads and checks the
factory, EntryPoint, and current artifact runtimes from Solidity. None of these
commands broadcasts. Do not add `--broadcast`: the official addresses are
already occupied by the exact expected runtimes.
