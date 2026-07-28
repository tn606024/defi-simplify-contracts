#!/usr/bin/env bash
set -euo pipefail

readonly minimum_lines="100.00"
readonly minimum_statements="100.00"
readonly minimum_branches="100.00"
readonly minimum_functions="100.00"

summary_file="$(mktemp)"
trap 'rm -f "$summary_file"' EXIT

echo "Production coverage policy:"
echo "  report: authored src/ contracts and libraries only"
echo "  thresholds: lines=${minimum_lines}% statements=${minimum_statements}% branches=${minimum_branches}% functions=${minimum_functions}%"
echo "  coverage is regression evidence, not a security guarantee"
echo "  Foundry-unmappable inline-assembly or compiler-generated anchors remain visible as warnings;"
echo "  no source file, line, statement, branch, or function is manually excluded from src/ totals"

forge coverage \
    --no-match-path 'test/fork/**' \
    --no-match-contract 'BaseDeploymentManifestTest|BaseV1_1CandidateManifestTest' \
    --exclude-tests \
    --no-match-coverage 'script/' \
    --report summary \
    --color never 2>&1 | tee "$summary_file"

total_row="$(awk -F '|' '$2 ~ /^[[:space:]]*Total[[:space:]]*$/ { print; exit }' "$summary_file")"
if [[ -z "$total_row" ]]; then
    echo "Production coverage gate could not find the Total row" >&2
    exit 1
fi

extract_percentage() {
    local field="$1"
    local value
    value="$(awk -F '|' -v field="$field" '{ print $field }' <<<"$total_row")"
    sed -E 's/^[^0-9]*([0-9]+([.][0-9]+)?)%.*/\1/' <<<"$value"
}

check_threshold() {
    local name="$1"
    local actual="$2"
    local minimum="$3"

    if ! awk -v actual="$actual" -v minimum="$minimum" 'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
        echo "Production ${name} coverage ${actual}% is below the required ${minimum}%" >&2
        exit 1
    fi
}

lines="$(extract_percentage 3)"
statements="$(extract_percentage 4)"
branches="$(extract_percentage 5)"
functions="$(extract_percentage 6)"

check_threshold "line" "$lines" "$minimum_lines"
check_threshold "statement" "$statements" "$minimum_statements"
check_threshold "branch" "$branches" "$minimum_branches"
check_threshold "function" "$functions" "$minimum_functions"

echo "Production coverage gate passed: lines=${lines}% statements=${statements}% branches=${branches}% functions=${functions}%"
