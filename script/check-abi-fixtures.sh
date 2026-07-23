#!/usr/bin/env bash
set -euo pipefail

readonly account_fixture="abi/IDefiSimplify7702Account.json"
readonly assertions_fixture="abi/IFlowAssertions.json"
readonly generic_assertions_fixture="abi/IStaticCallUint256Assertions.json"
readonly generated_account="$(mktemp)"
readonly generated_assertions="$(mktemp)"
readonly generated_generic_assertions="$(mktemp)"

cleanup() {
  rm -f "$generated_account" "$generated_assertions" "$generated_generic_assertions"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect ABI fixtures" >&2
  exit 1
}

forge inspect IDefiSimplify7702Account abi --json \
  | jq -cS 'sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))' \
  > "$generated_account"

if ! diff -u "$account_fixture" "$generated_account"; then
  echo "IDefiSimplify7702Account ABI fixture is stale" >&2
  exit 1
fi

forge inspect IFlowAssertions abi --json \
  | jq -cS 'sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))' \
  > "$generated_assertions"

if ! diff -u "$assertions_fixture" "$generated_assertions"; then
  echo "IFlowAssertions ABI fixture is stale" >&2
  exit 1
fi

forge inspect IStaticCallUint256Assertions abi --json \
  | jq -cS 'sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))' \
  > "$generated_generic_assertions"

if ! diff -u "$generic_assertions_fixture" "$generated_generic_assertions"; then
  echo "IStaticCallUint256Assertions ABI fixture is stale" >&2
  exit 1
fi

echo "Checked-in account and assertion ABI fixtures match their Solidity interfaces"
