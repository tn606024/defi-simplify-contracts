#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1-candidate.json"
readonly payload_path="out/deployment/base-v1.1/factory-payloads.json"
readonly gas_price_oracle="0x420000000000000000000000000000000000000F"
readonly transaction_envelope_allowance=256
readonly gas_limit_margin_bps=12500
readonly gas_price_margin_bps=20000
readonly total_safety_margin_bps=12000
readonly temporary_run_directory="$(
  mktemp -d "${TMPDIR:-/tmp}/base-v1.1-preflight.XXXXXX"
)"
trap 'rm -rf -- "$temporary_run_directory"' EXIT

for required_command in cast forge jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required for the Base v1.1.0 deployment preflight" >&2
    exit 1
  }
done

[[ -n "${BASE_RPC_URL:-}" ]] || {
  echo "BASE_RPC_URL is required for the Base v1.1.0 deployment preflight" >&2
  exit 1
}

[[ -n "${BASE_V1_1_DEPLOYER_ADDRESS:-}" ]] || {
  echo "BASE_V1_1_DEPLOYER_ADDRESS must identify the approved public deployment sender" >&2
  exit 1
}

readonly normalized_deployer_address="$(
  printf '%s' "$BASE_V1_1_DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]'
)"
if [[ ! "$BASE_V1_1_DEPLOYER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] \
  || [[ "$normalized_deployer_address" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "BASE_V1_1_DEPLOYER_ADDRESS is not a valid nonzero address" >&2
  exit 1
fi

./script/check-base-v1.1-candidate-manifest.sh
./script/check-base-v1.1-verification-inputs.sh
./script/check-base-v1.1-candidate-onchain.sh
./script/generate-base-v1.1-factory-payloads.sh "$payload_path"

readonly deployer_balance="$(cast balance --rpc-url "$BASE_RPC_URL" "$BASE_V1_1_DEPLOYER_ADDRESS")"
readonly gas_price="$(cast gas-price --rpc-url "$BASE_RPC_URL")"
readonly buffered_gas_price="$(( (gas_price * gas_price_margin_bps + 9999) / 10000 ))"
readonly factory="$(jq -er '.factory' "$payload_path")"

total_raw_execution_fee=0
total_buffered_execution_fee=0
total_l1_data_fee_upper_bound=0

echo "Approved public deployer: $BASE_V1_1_DEPLOYER_ADDRESS"
echo "Deployer balance (wei): $deployer_balance"
echo "Current RPC gas price (wei): $gas_price"
echo "Buffered gas price (wei): $buffered_gas_price ($gas_price_margin_bps bps of current)"
echo "Gas-limit margin: $gas_limit_margin_bps bps of eth_estimateGas"
echo "Final total-cost margin: $total_safety_margin_bps bps"
echo "L1 estimate method: GasPriceOracle.getL1FeeUpperBound(calldata bytes + $transaction_envelope_allowance bytes)"

for contract_name in DefiSimplify7702Account FlowAssertions StaticCallUint256Assertions; do
  artifact_root=".artifacts[\"$contract_name\"]"
  payload="$(jq -er "$artifact_root.calldata" "$payload_path")"
  calldata_size="$(jq -er "$artifact_root.calldataSize" "$payload_path")"
  unsigned_transaction_size="$((calldata_size + transaction_envelope_allowance))"
  gas_estimate="$(
    cast estimate \
      --rpc-url "$BASE_RPC_URL" \
      --from "$BASE_V1_1_DEPLOYER_ADDRESS" \
      "$factory" \
      "$payload"
  )"
  buffered_gas_limit="$(( (gas_estimate * gas_limit_margin_bps + 9999) / 10000 ))"
  raw_execution_fee="$((gas_estimate * gas_price))"
  buffered_execution_fee="$((buffered_gas_limit * buffered_gas_price))"
  l1_data_fee_upper_bound="$(
    cast call \
      --rpc-url "$BASE_RPC_URL" \
      "$gas_price_oracle" \
      'getL1FeeUpperBound(uint256)(uint256)' \
      "$unsigned_transaction_size" \
      --json \
      | jq -er '.[0]'
  )"

  total_raw_execution_fee="$((total_raw_execution_fee + raw_execution_fee))"
  total_buffered_execution_fee="$((total_buffered_execution_fee + buffered_execution_fee))"
  total_l1_data_fee_upper_bound="$((total_l1_data_fee_upper_bound + l1_data_fee_upper_bound))"

  echo "$contract_name:"
  echo "  salt: $(jq -er "$artifact_root.salt" "$payload_path")"
  echo "  initcode hash: $(jq -er "$artifact_root.initcodeHash" "$payload_path")"
  echo "  predicted address: $(jq -er "$artifact_root.expectedAddress" "$payload_path")"
  echo "  runtime hash: $(jq -er "$artifact_root.runtimeCodeHash" "$payload_path")"
  echo "  calldata hash: $(jq -er "$artifact_root.calldataKeccak256" "$payload_path")"
  echo "  calldata bytes: $calldata_size"
  echo "  L2 gas estimate: $gas_estimate"
  echo "  buffered L2 gas limit: $buffered_gas_limit"
  echo "  current L2 execution fee estimate (wei): $raw_execution_fee"
  echo "  buffered L2 execution fee (wei): $buffered_execution_fee"
  echo "  L1 data fee upper bound (wei): $l1_data_fee_upper_bound"
done

readonly total_current_fee_estimate="$((total_raw_execution_fee + total_l1_data_fee_upper_bound))"
readonly buffered_fee_estimate="$((total_buffered_execution_fee + total_l1_data_fee_upper_bound))"
readonly maximum_expected_spend="$(( (buffered_fee_estimate * total_safety_margin_bps + 9999) / 10000 ))"

echo "Total current L2 execution fee estimate (wei): $total_raw_execution_fee"
echo "Total buffered L2 execution fee (wei): $total_buffered_execution_fee"
echo "Total L1 data fee upper bound (wei): $total_l1_data_fee_upper_bound"
echo "Total current fee estimate (wei): $total_current_fee_estimate"
echo "Buffered fee estimate before final margin (wei): $buffered_fee_estimate"
echo "Maximum expected spend with safety margin (wei): $maximum_expected_spend"

if (( deployer_balance < maximum_expected_spend )); then
  echo "Deployer balance is below the required maximum expected spend" >&2
  exit 1
fi

echo "Deployer balance covers the estimated total cost and explicit safety margin"

BASE_V1_1_DEPLOYER_ADDRESS="$BASE_V1_1_DEPLOYER_ADDRESS" \
  FOUNDRY_BROADCAST="$temporary_run_directory/broadcast" \
  FOUNDRY_CACHE_PATH="$temporary_run_directory/cache" \
  forge script script/DeployBaseV1_1.s.sol:DeployBaseV1_1 \
    --rpc-url "$BASE_RPC_URL" \
    --sender "$BASE_V1_1_DEPLOYER_ADDRESS"

echo "Base v1.1.0 preflight completed without --broadcast; no Base state or BaseScan submission was changed"
