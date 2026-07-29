#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1.json"
readonly zero_word="0x0000000000000000000000000000000000000000000000000000000000000000"
readonly implementation_slot="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
readonly admin_slot="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
readonly beacon_slot="0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"

for required_command in cast jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to verify the Base v1.1.0 deployment" >&2
    exit 1
  }
done

[[ -n "${BASE_RPC_URL:-}" ]] || {
  echo "BASE_RPC_URL is required to verify the Base v1.1.0 deployment" >&2
  exit 1
}

[[ -f "$manifest_path" ]] || {
  echo "Missing Base v1.1.0 deployed manifest at $manifest_path" >&2
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

require_direct_non_proxy_slots() {
  local contract_name="$1"
  local address="$2"
  local slot_name slot_value

  for slot_name in implementation admin beacon; do
    case "$slot_name" in
      implementation) slot_value="$implementation_slot" ;;
      admin) slot_value="$admin_slot" ;;
      beacon) slot_value="$beacon_slot" ;;
    esac
    require_equal \
      "$contract_name EIP-1967 $slot_name slot" \
      "$zero_word" \
      "$(cast storage --rpc-url "$BASE_RPC_URL" "$address" "$slot_value")"
  done
}

verify_artifact() {
  local contract_name="$1"
  local artifact_root=".artifacts[\"$contract_name\"]"
  local address expected_runtime_hash transaction_hash expected_block expected_block_hash
  local expected_nonce expected_calldata_hash expected_salt expected_initcode_hash
  local expected_gas_used expected_effective_gas_price expected_l1_fee
  local transaction receipt factory_payload actual_salt initcode
  local actual_transaction_hash actual_receipt_hash actual_sender actual_factory

  address="$(jq -er "$artifact_root.address" "$manifest_path")"
  expected_runtime_hash="$(jq -er "$artifact_root.runtimeCodeHash" "$manifest_path")"
  transaction_hash="$(jq -er "$artifact_root.deploymentTransactionHash" "$manifest_path")"
  expected_block="$(jq -er "$artifact_root.deploymentBlockNumber" "$manifest_path")"
  expected_block_hash="$(jq -er "$artifact_root.deploymentBlockHash" "$manifest_path" | lowercase)"
  expected_nonce="$(jq -er "$artifact_root.deploymentNonce" "$manifest_path")"
  expected_calldata_hash="$(jq -er "$artifact_root.deploymentCalldataKeccak256" "$manifest_path")"
  expected_salt="$(jq -er "$artifact_root.salt.value" "$manifest_path")"
  expected_initcode_hash="$(jq -er "$artifact_root.initcodeHash" "$manifest_path")"
  expected_gas_used="$(jq -er "$artifact_root.gasUsed" "$manifest_path")"
  expected_effective_gas_price="$(jq -er "$artifact_root.effectiveGasPriceWei" "$manifest_path")"
  expected_l1_fee="$(jq -er "$artifact_root.l1FeeWei" "$manifest_path")"

  require_runtime_hash "$contract_name" "$address" "$expected_runtime_hash"
  require_direct_non_proxy_slots "$contract_name" "$address"

  transaction="$(cast rpc --rpc-url "$BASE_RPC_URL" eth_getTransactionByHash "$transaction_hash")"
  receipt="$(cast rpc --rpc-url "$BASE_RPC_URL" eth_getTransactionReceipt "$transaction_hash")"
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
  require_equal "$contract_name receipt transaction hash" "$actual_transaction_hash" "$actual_receipt_hash"

  actual_sender="$(jq -er '.from' <<<"$transaction" | lowercase)"
  actual_factory="$(jq -er '.to' <<<"$transaction" | lowercase)"
  require_equal "$contract_name deployment sender" "$expected_deployer" "$actual_sender"
  require_equal "$contract_name deployment factory" "$expected_factory" "$actual_factory"
  require_equal "$contract_name deployment value" "0" "$(cast to-dec "$(jq -er '.value' <<<"$transaction")")"
  require_equal "$contract_name deployment nonce" "$expected_nonce" "$(cast to-dec "$(jq -er '.nonce' <<<"$transaction")")"

  factory_payload="$(jq -er '.input' <<<"$transaction")"
  if [[ ! "$factory_payload" =~ ^0x[0-9a-fA-F]{66,}$ ]]; then
    echo "$contract_name factory payload is too short or malformed" >&2
    exit 1
  fi
  require_equal "$contract_name factory calldata hash" "$expected_calldata_hash" "$(cast keccak "$factory_payload")"
  actual_salt="0x${factory_payload:2:64}"
  initcode="0x${factory_payload:66}"
  require_equal "$contract_name deployment salt" "$expected_salt" "$actual_salt"
  require_equal "$contract_name deployment initcode hash" "$expected_initcode_hash" "$(cast keccak "$initcode")"

  require_equal "$contract_name receipt status" "0x1" "$(jq -er '.status' <<<"$receipt")"
  require_equal \
    "$contract_name transaction block" \
    "$expected_block" \
    "$(cast to-dec "$(jq -er '.blockNumber' <<<"$transaction")")"
  require_equal \
    "$contract_name receipt block" \
    "$expected_block" \
    "$(cast to-dec "$(jq -er '.blockNumber' <<<"$receipt")")"
  require_equal \
    "$contract_name transaction block hash" \
    "$expected_block_hash" \
    "$(jq -er '.blockHash' <<<"$transaction" | lowercase)"
  require_equal \
    "$contract_name receipt block hash" \
    "$expected_block_hash" \
    "$(jq -er '.blockHash' <<<"$receipt" | lowercase)"
  require_equal "$contract_name receipt gas used" "$expected_gas_used" "$(cast to-dec "$(jq -er '.gasUsed' <<<"$receipt")")"
  require_equal \
    "$contract_name effective gas price" \
    "$expected_effective_gas_price" \
    "$(cast to-dec "$(jq -er '.effectiveGasPrice' <<<"$receipt")")"
  require_equal "$contract_name L1 fee" "$expected_l1_fee" "$(cast to-dec "$(jq -er '.l1Fee' <<<"$receipt")")"
}

verify_artifact "DefiSimplify7702Account"
verify_artifact "FlowAssertions"
verify_artifact "StaticCallUint256Assertions"

readonly account_address="$(jq -er '.artifacts.DefiSimplify7702Account.address' "$manifest_path")"
require_equal \
  "DefiSimplify7702Account EntryPoint immutable" \
  "$(jq -er '.entryPoint.address' "$manifest_path" | lowercase)" \
  "$(cast call --rpc-url "$BASE_RPC_URL" "$account_address" 'entryPoint()(address)' | lowercase)"

echo "Base v1.1.0 deployment transactions, receipts, direct runtimes, proxy slots, and EntryPoint immutable match"
