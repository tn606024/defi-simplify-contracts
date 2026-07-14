#!/usr/bin/env bash
set -euo pipefail

readonly custom_contract="DefiSimplify7702Account"
readonly upstream_contract="Simple7702Account"
readonly custom_abi="$(mktemp)"
readonly upstream_abi="$(mktemp)"

cleanup() {
  rm -f "$custom_abi" "$upstream_abi"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect the minimal account surface" >&2
  exit 1
}

readonly canonicalize_abi='sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))'

forge inspect "$custom_contract" abi --json | jq -S "$canonicalize_abi" > "$custom_abi"
forge inspect "$upstream_contract" abi --json | jq -S "$canonicalize_abi" > "$upstream_abi"

if ! diff -u "$upstream_abi" "$custom_abi"; then
  echo "DefiSimplify7702Account ABI differs from pinned Simple7702Account" >&2
  exit 1
fi

readonly storage_count="$(forge inspect "$custom_contract" storage-layout --json | jq '.storage | length')"
if [[ "$storage_count" != "0" ]]; then
  echo "DefiSimplify7702Account defines $storage_count permanent storage entries" >&2
  exit 1
fi

echo "Minimal account ABI matches pinned upstream and permanent storage layout is empty"
