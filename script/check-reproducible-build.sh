#!/usr/bin/env bash
set -euo pipefail

hash_artifacts() {
  find out -type f -name '*.json' -print0 \
    | LC_ALL=C sort -z \
    | while IFS= read -r -d '' artifact; do
        shasum -a 256 "$artifact" | sed 's#  out/#  #'
      done \
    | shasum -a 256 \
    | awk '{print $1}'
}

forge clean
forge build >/dev/null
readonly first_hash="$(hash_artifacts)"

forge clean
forge build >/dev/null
readonly second_hash="$(hash_artifacts)"

if [[ "$first_hash" != "$second_hash" ]]; then
  echo "Build artifacts are not reproducible:" >&2
  echo "first:  $first_hash" >&2
  echo "second: $second_hash" >&2
  exit 1
fi

echo "Reproducible artifact tree: $first_hash"
