#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="${1:-out/verification/base-v1}"
if [[ "$output_directory" != /* ]]; then
  output_directory="$repository_root/$output_directory"
fi
readonly output_directory

readonly config_path="config/base-v1-deployment.json"
readonly expected_build_settings="$(
  jq -c '.build | {
      solidityVersion,
      evmVersion,
      optimizer,
      optimizerRuns,
      viaIR,
      bytecodeHash,
      useLiteralContent
    }' "$config_path"
)"
readonly actual_build_settings="$(
  forge config --json | jq -c '{
    solidityVersion: .solc,
    evmVersion: .evm_version,
    optimizer: .optimizer,
    optimizerRuns: .optimizer_runs,
    viaIR: .via_ir,
    bytecodeHash: .bytecode_hash,
    useLiteralContent: .use_literal_content
  }'
)"
if [[ "$expected_build_settings" != "$actual_build_settings" ]]; then
  readonly deployment_source_commit="$(jq -er '.deploymentSourceCommit' "$config_path")"
  readonly historical_tree="$(mktemp -d /tmp/defi-simplify-base-v1.XXXXXX)"

  cleanup_historical_tree() {
    rm -rf "$historical_tree"
  }
  trap cleanup_historical_tree EXIT

  git -C "$repository_root" cat-file -e "$deployment_source_commit^{commit}" || {
    echo "Historical Base v1 source commit is unavailable: $deployment_source_commit" >&2
    exit 1
  }
  git -C "$repository_root" archive "$deployment_source_commit" | tar -x -C "$historical_tree"
  rm -rf "$historical_tree/lib"
  ln -s "$repository_root/lib" "$historical_tree/lib"
  cp "$repository_root/script/generate-base-v1-verification-inputs.sh" \
    "$historical_tree/script/generate-base-v1-verification-inputs.sh"
  cp "$repository_root/config/base-v1-deployment.json" \
    "$historical_tree/config/base-v1-deployment.json"

  (
    cd "$historical_tree"
    ./script/generate-base-v1-verification-inputs.sh "$output_directory"
  )
  exit 0
fi

for required_command in forge jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to generate Base v1 verification inputs" >&2
    exit 1
  }
done

forge build >/dev/null
mkdir -p "$output_directory"

generate_verification_input() {
  local contract_name="$1"
  local source_path="$2"
  local artifact_path="$3"
  local output_path="$output_directory/$contract_name.standard-input.json"
  local temporary_output
  local source_count

  [[ -f "$artifact_path" ]] || {
    echo "Missing $contract_name artifact at $artifact_path" >&2
    exit 1
  }

  jq -e \
    --arg contract_name "$contract_name" \
    --arg source_path "$source_path" \
    '
      .metadata.language == "Solidity"
      and .metadata.settings.compilationTarget[$source_path] == $contract_name
      and (.metadata.sources | length > 0)
      and (
        .metadata.sources
        | to_entries
        | all(
            (.key | test("^(src|lib)/"))
            and (.key | test("^(test|script|broadcast|cache|out)/") | not)
            and (.value.content | type == "string")
          )
      )
    ' \
    "$artifact_path" >/dev/null || {
    echo "$contract_name artifact metadata contains an invalid target or non-production source" >&2
    exit 1
  }

  temporary_output="$(mktemp "$output_directory/.${contract_name}.XXXXXX")"
  jq -S \
    '
      {
        language: .metadata.language,
        sources: (
          .metadata.sources
          | with_entries(.value = {content: .value.content})
        ),
        settings: (
          (.metadata.settings | del(.compilationTarget))
          + {
              outputSelection: {
                "*": {
                  "*": [
                    "abi",
                    "evm.bytecode.object",
                    "evm.deployedBytecode.object",
                    "metadata"
                  ]
                }
              }
            }
        )
      }
    ' \
    "$artifact_path" >"$temporary_output"

  jq -e \
    --arg source_path "$source_path" \
    '
      .language == "Solidity"
      and (.sources | has($source_path))
      and (
        .sources
        | keys
        | all(
            test("^(src|lib)/")
            and (test("^(test|script|broadcast|cache|out)/") | not)
          )
      )
    ' \
    "$temporary_output" >/dev/null || {
    rm -f "$temporary_output"
    echo "$contract_name verification input contains an invalid source path" >&2
    exit 1
  }

  mv "$temporary_output" "$output_path"
  source_count="$(jq '.sources | length' "$output_path")"
  echo "Generated $output_path ($source_count target sources; no test or script sources)"
}

generate_verification_input \
  "DefiSimplify7702Account" \
  "src/DefiSimplify7702Account.sol" \
  "out/DefiSimplify7702Account.sol/DefiSimplify7702Account.json"
generate_verification_input \
  "FlowAssertions" \
  "src/FlowAssertions.sol" \
  "out/FlowAssertions.sol/FlowAssertions.json"
generate_verification_input \
  "StaticCallUint256Assertions" \
  "src/StaticCallUint256Assertions.sol" \
  "out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"
