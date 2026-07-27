#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.json"
readonly generated_manifest="$(mktemp)"

cleanup() {
  rm -f "$generated_manifest"
}
trap cleanup EXIT

./script/generate-base-v1-manifest.sh "$generated_manifest" >/dev/null

if ! diff -u "$manifest_path" "$generated_manifest"; then
  echo "Official Base v1 manifest is stale; regenerate it from the frozen artifacts and deployment evidence" >&2
  exit 1
fi

jq -e '
  .manifestStatus == "deployed"
  and .trustLevel == "official"
  and .releaseStatus == "released"
  and (has("intendedTrustLevel") | not)
  and .network.deploymentStatus == "deployed"
  and .security.status == "unaudited"
  and .security.experimental == true
  and .security.independentAuditPlanned == false
  and .security.securityGuarantee == false
  and .security.warranty == "none"
  and .security.totalLossRisk == true
  and .sdkIntegrationStatus == "not-integrated"
  and .scope.chain == "Base-only"
  and .scope.strategyClaims == "documented Base Aave proofs only"
  and (.deploymentSourceCommit | test("^(0x)?[0-9a-fA-F]{40}$"))
  and (.deployment.deployerAddress | test("^0x[0-9a-fA-F]{40}$"))
  and (.deployment.startedAt | test("Z$"))
  and (.deployment.completedAt | test("Z$"))
  and ([.artifacts[] |
    .deploymentStatus == "deployed"
    and .address == .expectedAddress
    and (.deploymentTransactionHash | test("^0x[0-9a-fA-F]{64}$"))
    and .deploymentBlockNumber > 0
    and (.deploymentTimestamp | test("Z$"))
    and (.deploymentTransactionUrl | startswith("https://basescan.org/tx/"))
    and .verificationStatus == "exact-match"
    and (.verificationUrl | startswith("https://basescan.org/address/"))
  ] | all)
  and (has("auditUrl") | not)
' "$manifest_path" >/dev/null || {
  echo "Official Base v1 manifest is missing deployed identity evidence or overstates release/security status" >&2
  exit 1
}

echo "Official Base v1 manifest reproduces deployed artifacts and preserves release/security limitations"
