#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.json"

for required_command in cast jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to verify the official Base deployment" >&2
    exit 1
  }
done

[[ -n "${BASE_RPC_URL:-}" ]] || {
  echo "BASE_RPC_URL is required to verify the official Base deployment" >&2
  exit 1
}

[[ -f "$manifest_path" ]] || {
  echo "Missing official Base manifest at $manifest_path" >&2
  exit 1
}

lowercase() {
  tr '[:upper:]' '[:lower:]'
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

readonly expected_deployer="$(
  jq -er '.deployment.deployerAddress' "$manifest_path" | lowercase
)"
readonly expected_factory="$(
  jq -er '.factory.address' "$manifest_path" | lowercase
)"

verify_artifact() {
  local contract_name="$1"
  local artifact_root=".artifacts[\"$contract_name\"]"
  local address expected_runtime_hash transaction_hash expected_block
  local expected_salt expected_initcode_hash transaction receipt
  local actual_sender actual_factory factory_payload actual_salt initcode
  local actual_transaction_hash actual_receipt_hash
  local actual_transaction_block actual_receipt_block

  address="$(jq -er "$artifact_root.address" "$manifest_path")"
  expected_runtime_hash="$(jq -er "$artifact_root.runtimeCodeHash" "$manifest_path")"
  transaction_hash="$(jq -er "$artifact_root.deploymentTransactionHash" "$manifest_path")"
  expected_block="$(jq -er "$artifact_root.deploymentBlockNumber" "$manifest_path")"
  expected_salt="$(jq -er "$artifact_root.salt.value" "$manifest_path")"
  expected_initcode_hash="$(jq -er "$artifact_root.initcodeHash" "$manifest_path")"

  require_runtime_hash "$contract_name" "$address" "$expected_runtime_hash"

  transaction="$(
    cast rpc --rpc-url "$BASE_RPC_URL" eth_getTransactionByHash "$transaction_hash"
  )"
  receipt="$(
    cast rpc --rpc-url "$BASE_RPC_URL" eth_getTransactionReceipt "$transaction_hash"
  )"
  [[ "$transaction" != "null" && "$receipt" != "null" ]] || {
    echo "$contract_name deployment transaction or receipt is unavailable" >&2
    exit 1
  }

  actual_transaction_hash="$(jq -er '.hash' <<<"$transaction" | lowercase)"
  actual_receipt_hash="$(jq -er '.transactionHash' <<<"$receipt" | lowercase)"
  require_equal \
    "$contract_name transaction hash" \
    "$(printf '%s' "$transaction_hash" | lowercase)" \
    "$actual_transaction_hash"
  require_equal \
    "$contract_name receipt transaction hash" \
    "$actual_transaction_hash" \
    "$actual_receipt_hash"

  actual_sender="$(jq -er '.from' <<<"$transaction" | lowercase)"
  actual_factory="$(jq -er '.to' <<<"$transaction" | lowercase)"
  require_equal "$contract_name deployment sender" "$expected_deployer" "$actual_sender"
  require_equal "$contract_name deployment factory" "$expected_factory" "$actual_factory"

  factory_payload="$(jq -er '.input' <<<"$transaction")"
  if [[ ! "$factory_payload" =~ ^0x[0-9a-fA-F]{66,}$ ]]; then
    echo "$contract_name factory payload is too short or malformed" >&2
    exit 1
  fi
  actual_salt="0x${factory_payload:2:64}"
  initcode="0x${factory_payload:66}"
  require_equal "$contract_name deployment salt" "$expected_salt" "$actual_salt"
  require_equal \
    "$contract_name deployment initcode hash" \
    "$expected_initcode_hash" \
    "$(cast keccak "$initcode")"

  require_equal "$contract_name receipt status" "0x1" "$(jq -er '.status' <<<"$receipt")"
  actual_transaction_block="$(cast to-dec "$(jq -er '.blockNumber' <<<"$transaction")")"
  actual_receipt_block="$(cast to-dec "$(jq -er '.blockNumber' <<<"$receipt")")"
  require_equal "$contract_name transaction block" "$expected_block" "$actual_transaction_block"
  require_equal "$contract_name receipt block" "$expected_block" "$actual_receipt_block"
}

verify_artifact "DefiSimplify7702Account"
verify_artifact "FlowAssertions"
verify_artifact "StaticCallUint256Assertions"

echo "Official Base v1 deployment transactions and runtimes match the manifest"
