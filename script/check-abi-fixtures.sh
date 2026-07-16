#!/usr/bin/env bash
set -euo pipefail

readonly fixture="abi/IDefiSimplify7702Account.json"
readonly generated="$(mktemp)"

cleanup() {
  rm -f "$generated"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect ABI fixtures" >&2
  exit 1
}

forge inspect IDefiSimplify7702Account abi --json \
  | jq -cS 'sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))' \
  > "$generated"

if ! diff -u "$fixture" "$generated"; then
  echo "IDefiSimplify7702Account ABI fixture is stale" >&2
  exit 1
fi

echo "Frozen dynamic account ABI fixture matches the Solidity interface"
