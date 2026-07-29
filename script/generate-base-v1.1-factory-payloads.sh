#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1-candidate.json"
readonly output_path="${1:-out/deployment/base-v1.1/factory-payloads.json}"

for required_command in cast forge jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to generate Base v1.1.0 factory payloads" >&2
    exit 1
  }
done

./script/check-base-v1.1-candidate-manifest.sh >/dev/null

artifact_payload() {
  local contract_name="$1"
  local artifact_path="$2"
  local artifact_root=".artifacts[\"$contract_name\"]"
  local creation_code constructor_arguments initcode salt payload
  local initcode_hash calldata_hash calldata_size

  creation_code="$(jq -er '.bytecode.object' "$artifact_path")"
  constructor_arguments="$(jq -er "$artifact_root.constructor.arguments" "$manifest_path")"
  initcode="${creation_code}${constructor_arguments#0x}"
  salt="$(jq -er "$artifact_root.salt.value" "$manifest_path")"
  payload="${salt}${initcode#0x}"
  initcode_hash="$(cast keccak "$initcode")"

  if [[ "$initcode_hash" != "$(jq -er "$artifact_root.initcodeHash" "$manifest_path")" ]]; then
    echo "$contract_name generated initcode does not match the frozen candidate" >&2
    exit 1
  fi

  calldata_hash="$(cast keccak "$payload")"
  calldata_size="$(( (${#payload} - 2) / 2 ))"

  jq -n \
    --arg contractName "$contract_name" \
    --arg salt "$salt" \
    --arg initcodeHash "$initcode_hash" \
    --arg expectedAddress "$(jq -er "$artifact_root.expectedAddress" "$manifest_path")" \
    --arg runtimeCodeHash "$(jq -er "$artifact_root.runtimeCodeHash" "$manifest_path")" \
    --arg calldata "$payload" \
    --arg calldataKeccak256 "$calldata_hash" \
    --argjson calldataSize "$calldata_size" \
    '{
      contractName: $contractName,
      salt: $salt,
      initcodeHash: $initcodeHash,
      expectedAddress: $expectedAddress,
      runtimeCodeHash: $runtimeCodeHash,
      calldata: $calldata,
      calldataKeccak256: $calldataKeccak256,
      calldataSize: $calldataSize
    }'
}

readonly account_payload="$(
  artifact_payload \
    "DefiSimplify7702Account" \
    "out/DefiSimplify7702Account.sol/DefiSimplify7702Account.json"
)"
readonly flow_assertions_payload="$(
  artifact_payload \
    "FlowAssertions" \
    "out/FlowAssertions.sol/FlowAssertions.json"
)"
readonly static_assertions_payload="$(
  artifact_payload \
    "StaticCallUint256Assertions" \
    "out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"
)"

mkdir -p "$(dirname "$output_path")"
jq -nS \
  --argjson schemaVersion 1 \
  --arg network "Base" \
  --argjson chainId "$(jq -er '.network.chainId' "$manifest_path")" \
  --arg factory "$(jq -er '.factory.address' "$manifest_path")" \
  --arg encoding "$(jq -er '.factory.calldataEncoding' "$manifest_path")" \
  --argjson account "$account_payload" \
  --argjson flowAssertions "$flow_assertions_payload" \
  --argjson staticAssertions "$static_assertions_payload" \
  '{
    schemaVersion: $schemaVersion,
    network: $network,
    chainId: $chainId,
    factory: $factory,
    calldataEncoding: $encoding,
    artifacts: {
      DefiSimplify7702Account: $account,
      FlowAssertions: $flowAssertions,
      StaticCallUint256Assertions: $staticAssertions
    }
  }' >"$output_path"

echo "Generated exact Base v1.1.0 factory payloads at $output_path"
