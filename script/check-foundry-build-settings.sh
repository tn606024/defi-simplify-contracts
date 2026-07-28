#!/usr/bin/env bash
set -euo pipefail

readonly lock_file="${1:-config/account-abstraction-v0.9.0.json}"

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required to validate the local compatibility build" >&2
    exit 1
  }
}

for required_command in forge jq; do
  require_command "$required_command"
done

[[ -f "$lock_file" ]] || {
  echo "Missing dependency lock at $lock_file" >&2
  exit 1
}

readonly foundry_config="$(forge config --json)"

check_build_field() {
  local label="$1"
  local lock_query="$2"
  local foundry_query="$3"
  local expected actual

  expected="$(
    jq -er "($lock_query) | if . == null then error(\"missing build-lock field\") else tostring end" "$lock_file"
  )"
  actual="$(
    jq -er "($foundry_query) | if . == null then error(\"missing Foundry field\") else tostring end" \
      <<<"$foundry_config"
  )"
  if [[ "$actual" != "$expected" ]]; then
    echo "Local $label mismatch: lock requires $expected, Foundry reports $actual" >&2
    exit 1
  fi
}

check_build_field "Solidity version" '.localCompatibilityBuild.solidity' '.solc'
check_build_field "EVM version" '.localCompatibilityBuild.evmVersion' '.evm_version'
check_build_field "optimizer setting" '.localCompatibilityBuild.optimizer' '.optimizer'
check_build_field "optimizer runs" '.localCompatibilityBuild.optimizerRuns' '.optimizer_runs'
check_build_field "viaIR setting" '.localCompatibilityBuild.viaIR' '.via_ir'

echo "Verified complete local compatibility build settings"
