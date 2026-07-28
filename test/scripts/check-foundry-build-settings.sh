#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly canonical_lock="$repository_root/config/account-abstraction-v0.9.0.json"
readonly checker="$repository_root/script/check-foundry-build-settings.sh"
readonly temporary_directory="$(mktemp -d)"
readonly temporary_lock="$temporary_directory/account-abstraction-v0.9.0.json"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

cd "$repository_root"

"$checker" "$canonical_lock" >/dev/null

expect_mismatch() {
  local jq_filter="$1"
  local expected_error="$2"
  local output

  jq "$jq_filter" "$canonical_lock" > "$temporary_lock"
  if output="$("$checker" "$temporary_lock" 2>&1)"; then
    echo "Expected build-setting mismatch containing: $expected_error" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_error" <<<"$output"; then
    echo "Unexpected mismatch error; expected '$expected_error', got:" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_mismatch \
  '.localCompatibilityBuild.solidity = "0.8.35"' \
  'Local Solidity version mismatch'
expect_mismatch \
  '.localCompatibilityBuild.evmVersion = "cancun"' \
  'Local EVM version mismatch'
expect_mismatch \
  '.localCompatibilityBuild.optimizer = false' \
  'Local optimizer setting mismatch'
expect_mismatch \
  '.localCompatibilityBuild.optimizerRuns = 9999' \
  'Local optimizer runs mismatch'
expect_mismatch \
  '.localCompatibilityBuild.viaIR = false' \
  'Local viaIR setting mismatch'

echo "Verified each local compatibility build mismatch is rejected"
