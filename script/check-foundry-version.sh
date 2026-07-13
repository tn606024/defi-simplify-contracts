#!/usr/bin/env bash
set -euo pipefail

readonly expected="$(tr -d '[:space:]' < .foundry-version)"
readonly actual="$(forge --version | head -n 1)"

if [[ "$actual" != *"${expected#v}"* ]]; then
  echo "Expected Foundry $expected, got: $actual" >&2
  exit 1
fi

echo "Using pinned Foundry $expected"
