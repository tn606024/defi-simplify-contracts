#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly script_target="${1:-}"
shift || true

if [[ "$script_target" != "script/DeployBaseV1.s.sol:DeployBaseV1" ]]; then
  echo "Unsupported historical Base v1 script target: $script_target" >&2
  exit 1
fi

for required_command in forge git jq tar; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to run a historical Base v1 script" >&2
    exit 1
  }
done

readonly manifest_path="$repository_root/deployments/base-v1.json"
readonly deployment_source_commit="$(jq -er '.deploymentSourceCommit' "$manifest_path")"
readonly historical_tree="$(mktemp -d /tmp/defi-simplify-base-v1.XXXXXX)"

cleanup() {
  rm -rf "$historical_tree"
}
trap cleanup EXIT

git -C "$repository_root" cat-file -e "$deployment_source_commit^{commit}" || {
  echo "Historical Base v1 source commit is unavailable: $deployment_source_commit" >&2
  exit 1
}
git -C "$repository_root" archive "$deployment_source_commit" | tar -x -C "$historical_tree"
rm -rf "$historical_tree/lib"
ln -s "$repository_root/lib" "$historical_tree/lib"
mkdir -p "$historical_tree/deployments"
cp "$manifest_path" "$historical_tree/deployments/base-v1.json"
# The recorded deployment source predates the final manifest rename and its
# script still reads the candidate filename. Both paths receive the same frozen
# official manifest; the historical script consumes only deployment identities.
cp "$manifest_path" "$historical_tree/deployments/base-v1.candidate.json"

(
  cd "$historical_tree"
  forge script "$script_target" "$@"
)
