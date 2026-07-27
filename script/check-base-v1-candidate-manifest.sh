#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.candidate.json"
readonly generated_manifest="$(mktemp)"

cleanup() {
  rm -f "$generated_manifest"
}
trap cleanup EXIT

./script/generate-base-v1-candidate-manifest.sh "$generated_manifest" >/dev/null

if ! diff -u "$manifest_path" "$generated_manifest"; then
  echo "Base v1 candidate manifest is stale; regenerate it from the frozen artifacts" >&2
  exit 1
fi

jq -e '
  .manifestStatus == "candidate"
  and .intendedTrustLevel == "official"
  and (has("trustLevel") | not)
  and .network.deploymentStatus == "not-broadcast"
  and .security.status == "unaudited"
  and .security.experimental == true
  and .security.independentAuditPlanned == false
  and .sdkIntegrationStatus == "not-integrated"
  and ([.artifacts[] | .deploymentStatus == "not-broadcast"] | all)
  and (has("auditUrl") | not)
  and (has("deploymentTransactions") | not)
  and (has("verificationUrls") | not)
  and ([.artifacts[] | has("deploymentTransactionHash") | not] | all)
  and ([.artifacts[] | has("verificationUrl") | not] | all)
' "$manifest_path" >/dev/null || {
  echo "Candidate manifest contains misleading release, audit, or deployment metadata" >&2
  exit 1
}

echo "Base v1 candidate manifest reproduces the frozen artifacts without release placeholders"
