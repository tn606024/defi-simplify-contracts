#!/usr/bin/env bash
set -euo pipefail

readonly manifest_path="deployments/base-v1.1.json"
readonly generated_manifest="$(mktemp)"

cleanup() {
  rm -f "$generated_manifest"
}
trap cleanup EXIT

./script/generate-base-v1.1-manifest.sh "$generated_manifest" >/dev/null

if ! diff -u "$manifest_path" "$generated_manifest"; then
  echo "Base v1.1.0 deployed manifest is stale; regenerate it from the frozen candidate and observed evidence" >&2
  exit 1
fi

jq -e '
  .manifestStatus == "deployed"
  and .releaseVersion == "v1.1.0"
  and .releaseStatus == "unreleased"
  and .verificationStatus == "not-submitted"
  and .intendedTrustLevel == "official"
  and (has("trustLevel") | not)
  and .network.deploymentStatus == "deployed"
  and .security.status == "unaudited"
  and .security.experimental == true
  and .security.independentAuditCompleted == false
  and .security.securityGuarantee == false
  and .security.warranty == "none"
  and .security.totalLossRisk == true
  and .sdkIntegrationStatus == "not-integrated"
  and (.candidateManifest.keccak256 | test("^0x[0-9a-f]{64}$"))
  and (.deployment.deployerAddress | test("^0x[0-9a-fA-F]{40}$"))
  and .deployment.totalObservedFeeWei == ([.artifacts[].observedTotalFeeWei] | add)
  and ([.artifacts[] |
    .deploymentStatus == "deployed"
    and .address == .expectedAddress
    and (.deploymentTransactionHash | test("^0x[0-9a-f]{64}$"))
    and (.deploymentTransactionUrl == ("https://basescan.org/tx/" + .deploymentTransactionHash))
    and (.deploymentBlockNumber > 0)
    and (.deploymentBlockHash | test("^0x[0-9a-f]{64}$"))
    and (.deploymentCalldataKeccak256 | test("^0x[0-9a-f]{64}$"))
    and .receiptStatus == 1
    and (.gasUsed > 0)
    and (.effectiveGasPriceWei > 0)
    and (.l1FeeWei >= 0)
    and .observedTotalFeeWei == (.gasUsed * .effectiveGasPriceWei + .l1FeeWei)
    and .verificationStatus == "not-submitted"
    and (has("verificationUrl") | not)
  ] | all)
  and (has("auditUrl") | not)
' "$manifest_path" >/dev/null || {
  echo "Base v1.1.0 manifest overstates verification, trust, release, SDK, or security status" >&2
  exit 1
}

echo "Base v1.1.0 deployed manifest reproduces exact broadcast evidence without verification or trust overclaims"
