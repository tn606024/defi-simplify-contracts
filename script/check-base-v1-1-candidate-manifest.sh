#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1-candidate.json"
readonly generated_manifest="$(mktemp)"

cleanup() {
  rm -f "$generated_manifest"
}
trap cleanup EXIT

./script/generate-base-v1-1-candidate-manifest.sh "$generated_manifest" >/dev/null

if ! diff -u "$manifest_path" "$generated_manifest"; then
  echo "Base v1.1 candidate manifest is stale; regenerate it from the pinned candidate build" >&2
  exit 1
fi

jq -e '
  .artifactVersion == "v1.1.0"
  and .manifestStatus == "candidate"
  and .intendedTrustLevel == "official"
  and .releaseStatus == "unreleased"
  and (has("trustLevel") | not)
  and (has("deployment") | not)
  and (has("deploymentSourceCommit") | not)
  and .network.deploymentStatus == "not-broadcast"
  and .security.status == "unaudited"
  and .security.experimental == true
  and .security.independentAuditPlanned == true
  and .security.securityGuarantee == false
  and .security.warranty == "none"
  and .security.totalLossRisk == true
  and .sdkIntegrationStatus == "not-integrated"
  and .build.optimizer == true
  and .build.optimizerRuns == 10000
  and .build.viaIR == true
  and ([.artifacts[] |
    .deploymentStatus == "not-broadcast"
    and .verificationStatus == "not-submitted"
    and (.expectedAddress | test("^0x[0-9a-fA-F]{40}$"))
    and (.creationCodeHash | test("^0x[0-9a-fA-F]{64}$"))
    and (.initcodeHash | test("^0x[0-9a-fA-F]{64}$"))
    and (.runtimeCodeHash | test("^0x[0-9a-fA-F]{64}$"))
    and .limits.runtimeCodeHeadroom > 0
    and .limits.initcodeHeadroom > 0
    and (has("address") | not)
    and (has("deploymentTransactionHash") | not)
    and (has("verificationUrl") | not)
  ] | all)
  and (has("auditUrl") | not)
' "$manifest_path" >/dev/null || {
  echo "Base v1.1 candidate manifest overstates deployment, trust, release, or security status" >&2
  exit 1
}

echo "Base v1.1 candidate manifest reproduces the unbroadcast artifacts and preserves security limitations"
