#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1-candidate.json"

for required_command in cast jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to check the Base v1.1.0 deployment candidate" >&2
    exit 1
  }
done

[[ -n "${BASE_RPC_URL:-}" ]] || {
  echo "BASE_RPC_URL is required to check the Base v1.1.0 deployment candidate" >&2
  exit 1
}

require_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label mismatch: expected $expected, observed $actual" >&2
    exit 1
  fi
}

require_equal \
  "Base chain ID" \
  "$(jq -er '.network.chainId' "$manifest_path")" \
  "$(cast chain-id --rpc-url "$BASE_RPC_URL")"

require_runtime_hash() {
  local label="$1"
  local address="$2"
  local expected_hash="$3"
  local runtime

  runtime="$(cast code --rpc-url "$BASE_RPC_URL" "$address")"
  [[ "$runtime" != "0x" ]] || {
    echo "$label has no runtime code at $address" >&2
    exit 1
  }
  require_equal "$label runtime code hash" "$expected_hash" "$(cast keccak "$runtime")"
}

require_runtime_hash \
  "Arachnid factory" \
  "$(jq -er '.factory.address' "$manifest_path")" \
  "$(jq -er '.factory.runtimeCodeHash' "$manifest_path")"
require_runtime_hash \
  "Base EntryPoint" \
  "$(jq -er '.entryPoint.address' "$manifest_path")" \
  "$(jq -er '.entryPoint.runtimeCodeHash' "$manifest_path")"

for contract_name in DefiSimplify7702Account FlowAssertions StaticCallUint256Assertions; do
  expected_address="$(
    jq -er --arg name "$contract_name" '.artifacts[$name].expectedAddress' "$manifest_path"
  )"
  runtime="$(cast code --rpc-url "$BASE_RPC_URL" "$expected_address")"
  if [[ "$runtime" != "0x" ]]; then
    echo "$contract_name candidate address $expected_address is no longer vacant" >&2
    exit 1
  fi
done

echo "Base v1.1.0 factory and EntryPoint match; all candidate addresses are vacant"
