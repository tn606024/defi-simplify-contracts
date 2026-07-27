# Deployments

> [!WARNING]
> The v1 contracts are experimental and unaudited. Reproducible bytecode,
> deterministic addresses, source verification, and tests are not an audit or
> a security guarantee. Total and irreversible loss is possible.

## Base v1 candidate

`base-v1.candidate.json` is a reproducible deployment candidate, not an
on-chain deployment manifest. No transaction has been broadcast and none of
the addresses below should be treated as deployed until a later manifest
records actual transaction hashes, source-verification URLs, and matching
on-chain runtime code.

| Artifact | Candidate CREATE2 address | Runtime code hash |
| --- | --- | --- |
| `DefiSimplify7702Account` | `0xf5e7cAAdAb81B4d585432f860a161e64F10Ab2CA` | `0xfa67c14b1dc7e1b822ef9f905bc20862750f03f0db40bed7f86e65df7a53067f` |
| `FlowAssertions` | `0x2D59990485A0a71619b8b16B70e11Cdc91b20FB5` | `0xeb7361327bf94a7a05adb4a2f27d5203eb1c81356b1e4694bc9f1098ebc3882c` |
| `StaticCallUint256Assertions` | `0x034ee940A644323463AB074DCA99504BF5a666EA` | `0xc26f9f8ce08cbeb069a32ac005b6a6c26dd878cb085295381f52e8de0f7e10d8` |

The candidate intentionally has no `trustLevel`, deployment transaction,
verification URL, or audit URL. `intendedTrustLevel: "official"` describes the
planned classification only after the project has broadcast and independently
verified the exact artifacts. `official` means project-published artifact and
deployment identity; it does not mean audited, safe, SDK-integrated, or
production-ready.

## Reproduce the candidate

Use the repository-pinned toolchain and dependency revisions:

```sh
export PATH="$HOME/.foundry/bin:$PATH"
./script/check-foundry-version.sh
./script/check-account-abstraction-revision.sh
./script/check-forge-std-revision.sh
forge build
./script/generate-base-v1-candidate-manifest.sh
./script/check-base-v1-candidate-manifest.sh
./script/check-abi-fixtures.sh
./script/check-direct-immutable-artifacts.sh
```

The generator reads `config/base-v1-deployment.json`, validates it against the
account-abstraction lock and effective Foundry settings, then derives creation,
initcode, and runtime hashes from a clean build. The account runtime hash
includes the immutable Base EntryPoint substitution. The two checker contracts
are constructor-free.

The checked-in complete deployment ABIs are:

- `abi/DefiSimplify7702Account.json`, including inherited and custom account
  functions;
- `abi/FlowAssertions.json`; and
- `abi/StaticCallUint256Assertions.json`.

The existing `I*.json` fixtures remain the smaller cross-repository interface
and error surfaces.

## Base-only dry run

The deployment script rechecks the active chain ID, Arachnid factory code hash,
EntryPoint code hash, complete initcode, CREATE2 prediction, and final runtime
code for all three artifacts:

```sh
forge script script/DeployBaseV1.s.sol:DeployBaseV1 \
  --rpc-url "$BASE_RPC_URL"
```

Without `--broadcast`, Foundry only simulates the three deployments. The Base
fork regression calls the actual factory inside a disposable local fork and
likewise sends no Base transaction:

```sh
forge test \
  --match-path 'test/fork/BaseDeploymentFactory.t.sol' \
  --fork-url "$BASE_RPC_URL"
```

Broadcasting is a separate maintainer action. Before adding `--broadcast`,
review the candidate diff, verify the deployer wallet and Base balance, repeat
the dry run, and obtain explicit approval for the external write and gas spend.
After mining, replace the candidate status with a deployed manifest that
records all three transaction hashes and direct source-verification URLs,
rechecks on-chain runtime hashes, assigns `trustLevel: "official"`, and removes
the candidate-only `intendedTrustLevel`.
