#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_path="${1:-}"
shift || true

case "$test_path" in
  test/unit/BaseDeploymentManifest.t.sol|test/fork/BaseDeploymentFactory.t.sol)
    ;;
  *)
    echo "Unsupported historical Base v1 test path: $test_path" >&2
    exit 1
    ;;
esac

for required_command in forge git jq tar; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to run a historical Base v1 test" >&2
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
rm -rf "$historical_tree/lib" "$historical_tree/test"
ln -s "$repository_root/lib" "$historical_tree/lib"
mkdir -p "$historical_tree/$(dirname "$test_path")" "$historical_tree/deployments"
cp "$repository_root/$test_path" "$historical_tree/$test_path"
cp "$manifest_path" "$historical_tree/deployments/base-v1.json"

(
  cd "$historical_tree"
  forge test --match-path "$test_path" "$@"
)
