#!/usr/bin/env bash
set -euo pipefail

for required_command in forge jq; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required to check Base v1.1.0 verification inputs" >&2
    exit 1
  }
done

readonly temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/base-v1.1-verification.XXXXXX")"
trap 'rm -rf -- "$temporary_directory"' EXIT

./script/generate-base-v1.1-verification-inputs.sh "$temporary_directory" >/dev/null

check_verification_input() {
  local contract_name="$1"
  local source_path="$2"
  local artifact_path="$3"
  local input_path="$temporary_directory/$contract_name.standard-input.json"
  local expected_sources actual_sources forbidden_sources

  [[ -f "$input_path" ]] || {
    echo "Missing generated verification input for $contract_name" >&2
    exit 1
  }

  expected_sources="$(jq -cS '.metadata.sources | keys' "$artifact_path")"
  actual_sources="$(jq -cS '.sources | keys' "$input_path")"
  if [[ "$actual_sources" != "$expected_sources" ]]; then
    echo "$contract_name verification input is not the artifact metadata source closure" >&2
    exit 1
  fi

  forbidden_sources="$(
    jq -r '
      .sources
      | keys[]
      | select(
          test("^(test|script|broadcast|cache|out)/")
          or (test("^(src|lib)/") | not)
        )
    ' "$input_path"
  )"
  if [[ -n "$forbidden_sources" ]]; then
    echo "$contract_name verification input contains forbidden sources:" >&2
    printf '%s\n' "$forbidden_sources" >&2
    exit 1
  fi

  jq -e \
    --arg source_path "$source_path" \
    '
      .language == "Solidity"
      and (.sources | has($source_path))
      and (
        [
          .sources
          | keys[]
          | select(
              . == "src/DefiSimplify7702Account.sol"
              or . == "src/FlowAssertions.sol"
              or . == "src/StaticCallUint256Assertions.sol"
            )
        ] == [$source_path]
      )
    ' \
    "$input_path" >/dev/null || {
    echo "$contract_name verification input includes an unrelated top-level production contract" >&2
    exit 1
  }

  echo "$contract_name verification input contains exactly its production source closure"
}

check_verification_input \
  "DefiSimplify7702Account" \
  "src/DefiSimplify7702Account.sol" \
  "out/DefiSimplify7702Account.sol/DefiSimplify7702Account.json"
check_verification_input \
  "FlowAssertions" \
  "src/FlowAssertions.sol" \
  "out/FlowAssertions.sol/FlowAssertions.json"
check_verification_input \
  "StaticCallUint256Assertions" \
  "src/StaticCallUint256Assertions.sol" \
  "out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"

echo "Base v1.1.0 BaseScan inputs contain code only: no test, script, build output, or unrelated contract sources"
