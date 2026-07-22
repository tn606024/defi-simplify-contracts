#!/usr/bin/env bash
set -euo pipefail

readonly implementation_contract="FlowAssertions"
readonly interface_contract="IFlowAssertions"
readonly implementation_artifact="out/FlowAssertions.sol/FlowAssertions.json"
readonly implementation_abi="$(mktemp)"
readonly interface_abi="$(mktemp)"

cleanup() {
  rm -f "$implementation_abi" "$interface_abi"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect the FlowAssertions surface" >&2
  exit 1
}

readonly canonicalize_abi='sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))'

forge inspect "$implementation_contract" abi --json | jq -S "$canonicalize_abi" > "$implementation_abi"
forge inspect "$interface_contract" abi --json | jq -S "$canonicalize_abi" > "$interface_abi"

if ! diff -u "$interface_abi" "$implementation_abi"; then
  echo "FlowAssertions ABI contains a surface outside IFlowAssertions" >&2
  exit 1
fi

readonly storage_count="$(jq '(.storageLayout.storage // []) | length' "$implementation_artifact")"
if [[ "$storage_count" != "0" ]]; then
  echo "FlowAssertions defines $storage_count permanent storage entries" >&2
  exit 1
fi

echo "FlowAssertions exposes only IFlowAssertions and has no permanent storage"
