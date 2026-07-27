#!/usr/bin/env bash
set -euo pipefail

readonly contracts=(
  "IDefiSimplify7702Account"
  "IFlowAssertions"
  "IStaticCallUint256Assertions"
  "DefiSimplify7702Account"
  "FlowAssertions"
  "StaticCallUint256Assertions"
)
readonly fixtures=(
  "abi/IDefiSimplify7702Account.json"
  "abi/IFlowAssertions.json"
  "abi/IStaticCallUint256Assertions.json"
  "abi/DefiSimplify7702Account.json"
  "abi/FlowAssertions.json"
  "abi/StaticCallUint256Assertions.json"
)
readonly generated_directory="$(mktemp -d)"

cleanup() {
  rm -rf "$generated_directory"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect ABI fixtures" >&2
  exit 1
}

for index in "${!contracts[@]}"; do
  contract="${contracts[$index]}"
  fixture="${fixtures[$index]}"
  generated_fixture="$generated_directory/$contract.json"

  forge inspect "$contract" abi --json \
    | jq -cS '
        sort_by(
          .type
          + ":"
          + (.name // "")
          + ":"
          + ((.inputs // []) | map(.type) | join(","))
        )
      ' \
    > "$generated_fixture"

  if ! diff -u "$fixture" "$generated_fixture"; then
    echo "$contract ABI fixture is stale" >&2
    exit 1
  fi
done

echo "Checked-in interface and complete deployment ABI fixtures match Solidity"
