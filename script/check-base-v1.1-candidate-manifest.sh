#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1-candidate.json"
readonly generated_manifest="$(mktemp)"

cleanup() {
  rm -f "$generated_manifest"
}
trap cleanup EXIT

./script/generate-base-v1.1-candidate-manifest.sh "$generated_manifest" >/dev/null

if ! diff -u "$manifest_path" "$generated_manifest"; then
  echo "Base v1.1.0 candidate manifest is stale; regenerate it from the frozen active build" >&2
  exit 1
fi

jq -e '
  .manifestStatus == "candidate"
  and .releaseVersion == "v1.1.0"
  and .releaseStatus == "unreleased"
  and .intendedTrustLevel == "official"
  and (has("trustLevel") | not)
  and (has("deployment") | not)
  and .network.deploymentStatus == "not-broadcast"
  and .security.status == "unaudited"
  and .security.experimental == true
  and .security.independentAuditCompleted == false
  and .security.securityGuarantee == false
  and .security.warranty == "none"
  and .security.totalLossRisk == true
  and .sdkIntegrationStatus == "not-integrated"
  and .scope.chain == "Base-only"
  and .scope.strategyClaims == "documented Base Aave proofs only"
  and (.artifactSource.commit | test("^[0-9a-f]{40}$"))
  and (.artifactSource.tree | test("^[0-9a-f]{40}$"))
  and .build.optimizerRuns == 10000
  and ([.artifacts[] |
    .deploymentStatus == "not-broadcast"
    and (has("address") | not)
    and (has("deploymentTransactionHash") | not)
    and (has("deploymentTransactionUrl") | not)
    and (has("verificationStatus") | not)
    and (has("verificationUrl") | not)
    and (.expectedAddress | test("^0x[0-9a-fA-F]{40}$"))
    and (.abiJsonKeccak256 | test("^0x[0-9a-fA-F]{64}$"))
  ] | all)
  and ([.artifacts[].salt.value] | unique | length == 3)
  and (has("auditUrl") | not)
' "$manifest_path" >/dev/null || {
  echo "Base v1.1.0 candidate manifest overstates deployment, release, verification, trust, or security status" >&2
  exit 1
}

echo "Base v1.1.0 candidate manifest reproduces the active build without deployment or trust claims"
