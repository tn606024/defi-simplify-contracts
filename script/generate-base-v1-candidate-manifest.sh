#!/usr/bin/env bash
set -euo pipefail

readonly config_path="config/base-v1-deployment.json"
readonly output_path="${1:-deployments/base-v1.candidate.json}"
readonly account_artifact="out/DefiSimplify7702Account.sol/DefiSimplify7702Account.json"
readonly flow_assertions_artifact="out/FlowAssertions.sol/FlowAssertions.json"
readonly static_assertions_artifact="out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required to generate the Base v1 candidate manifest" >&2
    exit 1
  }
}

for required_command in forge cast jq; do
  require_command "$required_command"
done

[[ -f "$config_path" ]] || {
  echo "Missing deployment config at $config_path" >&2
  exit 1
}

readonly configured_foundry_version="$(jq -er '.build.foundryVersion' "$config_path")"
readonly pinned_foundry_version="$(tr -d '[:space:]' < .foundry-version)"
if [[ "$configured_foundry_version" != "$pinned_foundry_version" ]]; then
  echo "Deployment config Foundry version does not match .foundry-version" >&2
  exit 1
fi

readonly expected_build_settings="$(
  jq -c '.build | {
      solidityVersion,
      evmVersion,
      optimizer,
      optimizerRuns,
      viaIR,
      bytecodeHash,
      useLiteralContent
    }' "$config_path"
)"
readonly actual_build_settings="$(
  forge config --json | jq -c '{
    solidityVersion: .solc,
    evmVersion: .evm_version,
    optimizer: .optimizer,
    optimizerRuns: .optimizer_runs,
    viaIR: .via_ir,
    bytecodeHash: .bytecode_hash,
    useLiteralContent: .use_literal_content
  }'
)"
if [[ "$expected_build_settings" != "$actual_build_settings" ]]; then
  echo "Deployment config does not match the active pinned Foundry build settings" >&2
  exit 1
fi

readonly dependency_lock="config/account-abstraction-v0.9.0.json"
if [[ "$(jq -r '.upstreamAccount.commit' "$config_path")" \
  != "$(jq -r '.accountAbstraction.commit' "$dependency_lock")" ]] \
  || [[ "$(jq -r '.entryPoint.address' "$config_path")" \
  != "$(jq -r '.base.entryPointAddress' "$dependency_lock")" ]] \
  || [[ "$(jq -r '.entryPoint.runtimeCodeHash' "$config_path")" \
  != "$(jq -r '.base.entryPointRuntimeCodeHash' "$dependency_lock")" ]]; then
  echo "Deployment config does not match the account-abstraction and EntryPoint lock" >&2
  exit 1
fi

forge build >/dev/null

readonly factory_address="$(jq -er '.factory.address' "$config_path")"
readonly entry_point_address="$(jq -er '.entryPoint.address' "$config_path")"
readonly encoded_entry_point_constructor="$(
  cast abi-encode 'constructor(address)' "$entry_point_address"
)"

hash_bytes() {
  cast keccak "$1"
}

byte_length() {
  local encoded_bytes="${1#0x}"
  echo "$(( ${#encoded_bytes} / 2 ))"
}

salt_value() {
  local contract_name="$1"
  local salt_preimage configured_salt computed_salt

  salt_preimage="$(jq -er --arg name "$contract_name" '.salts[$name].preimage' "$config_path")"
  configured_salt="$(jq -er --arg name "$contract_name" '.salts[$name].value' "$config_path")"
  computed_salt="$(cast keccak "$salt_preimage")"
  if [[ "$configured_salt" != "$computed_salt" ]]; then
    echo "$contract_name salt does not match its documented preimage" >&2
    exit 1
  fi
  echo "$configured_salt"
}

predict_address() {
  local salt="$1"
  local initcode_hash="$2"
  cast create2 \
    --deployer "$factory_address" \
    --salt "$salt" \
    --init-code-hash "$initcode_hash"
}

account_runtime_bytecode() {
  local runtime replacement start length character_start character_length

  if [[ "$(jq '.deployedBytecode.immutableReferences | length' "$account_artifact")" != "1" ]]; then
    echo "Account artifact must contain exactly one immutable identity" >&2
    exit 1
  fi

  runtime="$(jq -er '.deployedBytecode.object' "$account_artifact")"
  runtime="${runtime#0x}"
  replacement="000000000000000000000000${entry_point_address#0x}"

  if [[ "${#replacement}" != 64 ]]; then
    echo "EntryPoint immutable replacement is not one ABI word" >&2
    exit 1
  fi

  while read -r start length; do
    if [[ "$length" != "32" ]]; then
      echo "Unsupported account immutable length $length at byte $start" >&2
      exit 1
    fi
    character_start="$((start * 2))"
    character_length="$((length * 2))"
    runtime="${runtime:0:character_start}${replacement}${runtime:character_start+character_length}"
  done < <(
    jq -r '
      .deployedBytecode.immutableReferences
      | to_entries[]
      | .value[]
      | "\(.start) \(.length)"
    ' "$account_artifact"
  )

  echo "0x$runtime"
}

artifact_manifest() {
  local contract_name="$1"
  local source_path="$2"
  local abi_path="$3"
  local artifact_path="$4"
  local constructor_signature="$5"
  local constructor_arguments="$6"
  local creation_code runtime_code initcode
  local creation_code_hash runtime_code_hash initcode_hash
  local salt expected_address

  creation_code="$(jq -er '.bytecode.object' "$artifact_path")"
  if [[ "$contract_name" == "DefiSimplify7702Account" ]]; then
    runtime_code="$(account_runtime_bytecode)"
  else
    runtime_code="$(jq -er '.deployedBytecode.object' "$artifact_path")"
  fi
  initcode="${creation_code}${constructor_arguments#0x}"

  creation_code_hash="$(hash_bytes "$creation_code")"
  initcode_hash="$(hash_bytes "$initcode")"
  runtime_code_hash="$(hash_bytes "$runtime_code")"
  salt="$(salt_value "$contract_name")"
  expected_address="$(predict_address "$salt" "$initcode_hash")"

  jq -n \
    --arg contractName "$contract_name" \
    --arg sourcePath "$source_path" \
    --arg abiPath "$abi_path" \
    --arg constructorSignature "$constructor_signature" \
    --arg constructorArguments "$constructor_arguments" \
    --arg creationCodeHash "$creation_code_hash" \
    --arg initcodeHash "$initcode_hash" \
    --arg runtimeCodeHash "$runtime_code_hash" \
    --arg saltPreimage "$(
      jq -er --arg name "$contract_name" '.salts[$name].preimage' "$config_path"
    )" \
    --arg salt "$salt" \
    --arg expectedAddress "$expected_address" \
    --argjson creationCodeSize "$(byte_length "$creation_code")" \
    --argjson initcodeSize "$(byte_length "$initcode")" \
    --argjson runtimeCodeSize "$(byte_length "$runtime_code")" \
    '{
      contractName: $contractName,
      sourcePath: $sourcePath,
      abiPath: $abiPath,
      constructor: {
        signature: $constructorSignature,
        arguments: $constructorArguments
      },
      salt: {
        preimage: $saltPreimage,
        value: $salt
      },
      creationCodeHash: $creationCodeHash,
      creationCodeSize: $creationCodeSize,
      initcodeHash: $initcodeHash,
      initcodeSize: $initcodeSize,
      expectedAddress: $expectedAddress,
      runtimeCodeHash: $runtimeCodeHash,
      runtimeCodeSize: $runtimeCodeSize,
      deploymentStatus: "not-broadcast"
    }'
}

readonly account_manifest="$(
  artifact_manifest \
    "DefiSimplify7702Account" \
    "src/DefiSimplify7702Account.sol" \
    "abi/DefiSimplify7702Account.json" \
    "$account_artifact" \
    "constructor(address)" \
    "$encoded_entry_point_constructor"
)"
readonly flow_assertions_manifest="$(
  artifact_manifest \
    "FlowAssertions" \
    "src/FlowAssertions.sol" \
    "abi/FlowAssertions.json" \
    "$flow_assertions_artifact" \
    "constructor()" \
    "0x"
)"
readonly static_assertions_manifest="$(
  artifact_manifest \
    "StaticCallUint256Assertions" \
    "src/StaticCallUint256Assertions.sol" \
    "abi/StaticCallUint256Assertions.json" \
    "$static_assertions_artifact" \
    "constructor()" \
    "0x"
)"

mkdir -p "$(dirname "$output_path")"
jq -nS \
  --argjson schemaVersion "$(jq -er '.schemaVersion' "$config_path")" \
  --arg manifestStatus "$(jq -er '.manifestStatus' "$config_path")" \
  --arg intendedTrustLevel "$(jq -er '.intendedTrustLevel' "$config_path")" \
  --arg addressFamilyId "$(jq -er '.addressFamilyId' "$config_path")" \
  --arg sourceRepository "$(jq -er '.sourceRepository' "$config_path")" \
  --argjson network "$(jq -ec '.network + {deploymentStatus: "not-broadcast"}' "$config_path")" \
  --argjson factory "$(jq -ec '.factory' "$config_path")" \
  --argjson entryPoint "$(jq -ec '.entryPoint' "$config_path")" \
  --argjson upstreamAccount "$(jq -ec '.upstreamAccount' "$config_path")" \
  --argjson build "$(jq -ec '.build' "$config_path")" \
  --argjson security "$(
    jq -ec '.security + {
      notice: "Experimental and unaudited; tests and reproducibility are not a security guarantee."
    }' "$config_path"
  )" \
  --argjson account "$account_manifest" \
  --argjson flowAssertions "$flow_assertions_manifest" \
  --argjson staticAssertions "$static_assertions_manifest" \
  '{
    schemaVersion: $schemaVersion,
    manifestStatus: $manifestStatus,
    intendedTrustLevel: $intendedTrustLevel,
    security: $security,
    sdkIntegrationStatus: "not-integrated",
    addressFamilyId: $addressFamilyId,
    sourceRepository: $sourceRepository,
    network: $network,
    factory: $factory,
    entryPoint: $entryPoint,
    upstreamAccount: $upstreamAccount,
    build: $build,
    artifacts: {
      DefiSimplify7702Account: $account,
      FlowAssertions: $flowAssertions,
      StaticCallUint256Assertions: $staticAssertions
    }
  }' > "$output_path"

echo "Generated Base v1 candidate manifest at $output_path"
