#!/usr/bin/env bash
set -euo pipefail

readonly lock_file="config/account-abstraction-v0.9.0.json"
readonly base_test="test/fork/BaseEntryPoint.t.sol"

check_dependency() {
  local key="$1"
  local path expected actual gitlink

  path="$(jq -r ".${key}.path" "$lock_file")"
  expected="$(jq -r ".${key}.commit" "$lock_file")"

  if [[ ! -d "$path" ]]; then
    echo "Missing dependency at $path; initialize Git submodules first." >&2
    exit 1
  fi

  actual="$(git -C "$path" rev-parse HEAD)"
  gitlink="$(git ls-files --stage "$path" | awk '{print $2}')"

  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected $key checkout: expected $expected, got $actual" >&2
    exit 1
  fi

  if [[ "$gitlink" != "$expected" ]]; then
    echo "Unexpected $key gitlink: expected $expected, got ${gitlink:-missing}" >&2
    exit 1
  fi

  if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet; then
    echo "Dependency $key contains local source modifications." >&2
    exit 1
  fi

  echo "Verified $key at $expected"
}

command -v jq >/dev/null || {
  echo "jq is required to validate $lock_file" >&2
  exit 1
}

check_dependency "accountAbstraction"
check_dependency "openzeppelinContracts"

readonly entry_point="$(jq -r '.base.entryPointAddress' "$lock_file")"
readonly runtime_hash="$(jq -r '.base.entryPointRuntimeCodeHash' "$lock_file")"

grep -Fq "$entry_point" "$base_test" || {
  echo "Base fork test does not use locked EntryPoint $entry_point" >&2
  exit 1
}

grep -Fq "$runtime_hash" "$base_test" || {
  echo "Base fork test does not use locked runtime hash $runtime_hash" >&2
  exit 1
}

echo "Verified Base EntryPoint test constants"
