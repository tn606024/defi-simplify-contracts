#!/usr/bin/env bash
set -euo pipefail

readonly config_path="config/base-v1.1-deployment.json"
readonly candidate_path="deployments/base-v1.1-candidate.json"
readonly output_path="${1:-deployments/base-v1.1.json}"
readonly payload_path="$(mktemp)"

cleanup() {
  rm -f "$payload_path"
}
trap cleanup EXIT

for required_command in cast jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to generate the Base v1.1.0 deployed manifest" >&2
    exit 1
  }
done

for required_path in "$config_path" "$candidate_path"; do
  [[ -f "$required_path" ]] || {
    echo "Missing Base v1.1.0 deployment input at $required_path" >&2
    exit 1
  }
done

./script/check-base-v1.1-candidate-manifest.sh >/dev/null
./script/generate-base-v1.1-factory-payloads.sh "$payload_path" >/dev/null

readonly expected_candidate_hash="$(
  jq -er '.candidateManifest.keccak256' "$config_path"
)"
readonly actual_candidate_hash="$(cast keccak "$(jq -cS '.' "$candidate_path")")"
if [[ "$actual_candidate_hash" != "$expected_candidate_hash" ]]; then
  echo "Base v1.1.0 deployment evidence does not bind the frozen candidate manifest" >&2
  exit 1
fi

jq -e '
  .schemaVersion == 1
  and .candidateManifest.path == "deployments/base-v1.1-candidate.json"
  and .manifestStatus == "deployed"
  and .releaseStatus == "unreleased"
  and .verificationStatus == "exact-match"
  and (.deployment.deployerAddress | test("^0x[0-9a-fA-F]{40}$"))
  and (.deployment.startedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.deployment.completedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and ([.deployment.artifacts[].nonce] == [44, 45, 46])
  and (([.deployment.artifacts[].observedTotalFeeWei] | add) == .deployment.totalObservedFeeWei)
  and ([.deployment.artifacts[] |
    (.address | test("^0x[0-9a-fA-F]{40}$"))
    and (.transactionHash | test("^0x[0-9a-f]{64}$"))
    and .transactionUrl == ("https://basescan.org/tx/" + .transactionHash)
    and (.blockNumber > 0)
    and (.blockHash | test("^0x[0-9a-f]{64}$"))
    and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.calldataKeccak256 | test("^0x[0-9a-f]{64}$"))
    and .receiptStatus == 1
    and (.gasUsed > 0)
    and (.effectiveGasPriceWei > 0)
    and (.l1FeeWei >= 0)
    and .observedTotalFeeWei == (.gasUsed * .effectiveGasPriceWei + .l1FeeWei)
    and .verificationStatus == "exact-match"
    and .verificationUrl == ("https://basescan.org/address/" + .address + "#code")
  ] | all)
' "$config_path" >/dev/null || {
  echo "Base v1.1.0 deployment or exact-match verification evidence is malformed" >&2
  exit 1
}

for contract_name in DefiSimplify7702Account FlowAssertions StaticCallUint256Assertions; do
  expected_address="$(
    jq -er --arg name "$contract_name" '.artifacts[$name].expectedAddress' "$candidate_path"
  )"
  observed_address="$(
    jq -er --arg name "$contract_name" '.deployment.artifacts[$name].address' "$config_path"
  )"
  [[ "$(printf '%s' "$observed_address" | tr '[:upper:]' '[:lower:]')" \
    == "$(printf '%s' "$expected_address" | tr '[:upper:]' '[:lower:]')" ]] || {
    echo "$contract_name deployed address does not match the frozen candidate" >&2
    exit 1
  }

  expected_calldata_hash="$(
    jq -er --arg name "$contract_name" '.artifacts[$name].calldataKeccak256' "$payload_path"
  )"
  observed_calldata_hash="$(
    jq -er --arg name "$contract_name" '.deployment.artifacts[$name].calldataKeccak256' "$config_path"
  )"
  [[ "$observed_calldata_hash" == "$expected_calldata_hash" ]] || {
    echo "$contract_name deployment calldata does not match the reviewed factory payload" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$output_path")"
jq -nS \
  --slurpfile candidate "$candidate_path" \
  --slurpfile config "$config_path" \
  '
    $candidate[0] as $candidateManifest
    | $config[0] as $deploymentConfig
    | $candidateManifest
    | .manifestStatus = $deploymentConfig.manifestStatus
    | .releaseStatus = $deploymentConfig.releaseStatus
    | .verificationStatus = $deploymentConfig.verificationStatus
    | .candidateManifest = $deploymentConfig.candidateManifest
    | .network.deploymentStatus = "deployed"
    | .deployment = ($deploymentConfig.deployment | del(.artifacts))
    | .artifacts |= with_entries(
        .key as $contractName
        | .value as $artifact
        | $deploymentConfig.deployment.artifacts[$contractName] as $evidence
        | .value = (
            $artifact
            + {
                address: $evidence.address,
                deploymentStatus: "deployed",
                deploymentTransactionHash: $evidence.transactionHash,
                deploymentTransactionUrl: $evidence.transactionUrl,
                deploymentBlockNumber: $evidence.blockNumber,
                deploymentBlockHash: $evidence.blockHash,
                deploymentTimestamp: $evidence.timestamp,
                deploymentNonce: $evidence.nonce,
                deploymentCalldataKeccak256: $evidence.calldataKeccak256,
                receiptStatus: $evidence.receiptStatus,
                gasUsed: $evidence.gasUsed,
                effectiveGasPriceWei: $evidence.effectiveGasPriceWei,
                l1FeeWei: $evidence.l1FeeWei,
                observedTotalFeeWei: $evidence.observedTotalFeeWei,
                verificationStatus: $evidence.verificationStatus,
                verificationUrl: $evidence.verificationUrl
              }
          )
      )
  ' > "$output_path"

echo "Generated Base v1.1.0 deployed, exact-match verified, unreleased manifest at $output_path"
