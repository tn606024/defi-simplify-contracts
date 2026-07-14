#!/usr/bin/env bash
set -euo pipefail

readonly lock_file="foundry.lock"
readonly path="lib/forge-std"

command -v jq >/dev/null || {
  echo "jq is required to validate $lock_file" >&2
  exit 1
}

if [[ ! -d "$path" ]]; then
  echo "Missing forge-std at $path; initialize Git submodules first." >&2
  exit 1
fi

readonly version="$(jq -r '.["lib/forge-std"].tag.name' "$lock_file")"
readonly expected="$(jq -r '.["lib/forge-std"].tag.rev' "$lock_file")"
readonly actual="$(git -C "$path" rev-parse HEAD)"
readonly gitlink="$(git ls-files --stage "$path" | awk '{print $2}')"

if [[ -z "$version" || "$version" == "null" || -z "$expected" || "$expected" == "null" ]]; then
  echo "Missing pinned forge-std tag or revision in $lock_file" >&2
  exit 1
fi

if [[ "$actual" != "$expected" ]]; then
  echo "Unexpected forge-std checkout: expected $expected, got $actual" >&2
  exit 1
fi

if [[ "$gitlink" != "$expected" ]]; then
  echo "Unexpected forge-std gitlink: expected $expected, got ${gitlink:-missing}" >&2
  exit 1
fi

if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet; then
  echo "forge-std contains local source modifications." >&2
  exit 1
fi

echo "Verified forge-std $version at $expected"
