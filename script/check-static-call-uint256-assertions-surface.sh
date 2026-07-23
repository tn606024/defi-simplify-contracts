#!/usr/bin/env bash
set -euo pipefail

readonly implementation_contract="StaticCallUint256Assertions"
readonly interface_contract="IStaticCallUint256Assertions"
readonly implementation_artifact="out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"
readonly implementation_abi="$(mktemp)"
readonly interface_abi="$(mktemp)"
readonly executable_opcodes="$(mktemp)"

cleanup() {
  rm -f "$implementation_abi" "$interface_abi" "$executable_opcodes"
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required to inspect the StaticCallUint256Assertions surface" >&2
  exit 1
}

readonly canonicalize_abi='sort_by(.type + ":" + (.name // "") + ":" + ((.inputs // []) | map(.type) | join(",")))'

forge inspect "$implementation_contract" abi --json | jq -S "$canonicalize_abi" > "$implementation_abi"
forge inspect "$interface_contract" abi --json | jq -S "$canonicalize_abi" > "$interface_abi"

if ! diff -u "$interface_abi" "$implementation_abi"; then
  echo "StaticCallUint256Assertions ABI contains a surface outside IStaticCallUint256Assertions" >&2
  exit 1
fi

readonly storage_count="$(jq '(.storageLayout.storage // []) | length' "$implementation_artifact")"
if [[ "$storage_count" != "0" ]]; then
  echo "StaticCallUint256Assertions defines $storage_count permanent storage entries" >&2
  exit 1
fi

readonly event_count="$(jq '[.abi[] | select(.type == "event")] | length' "$implementation_artifact")"
if [[ "$event_count" != "0" ]]; then
  echo "StaticCallUint256Assertions defines $event_count custom events" >&2
  exit 1
fi

readonly payable_count="$(jq '[.abi[] | select(.type == "function" and .stateMutability == "payable")] | length' "$implementation_artifact")"
if [[ "$payable_count" != "0" ]]; then
  echo "StaticCallUint256Assertions defines $payable_count payable functions" >&2
  exit 1
fi

readonly deployed_bytecode="$(forge inspect "$implementation_contract" deployedBytecode)"
readonly bytecode="${deployed_bytecode#0x}"
readonly metadata_hex_length="${bytecode: -4}"
readonly metadata_character_count="$(( (16#$metadata_hex_length + 2) * 2 ))"
readonly executable_character_count="$(( ${#bytecode} - metadata_character_count ))"
cast disassemble "0x${bytecode:0:executable_character_count}" > "$executable_opcodes"

if grep -Eq ': (SLOAD|SSTORE|TLOAD|TSTORE)$' "$executable_opcodes"; then
  echo "StaticCallUint256Assertions executable bytecode accesses permanent or transient storage" >&2
  exit 1
fi

if grep -Eq ': (CALL|CALLCODE|DELEGATECALL|CREATE|CREATE2|SELFDESTRUCT)$' "$executable_opcodes"; then
  echo "StaticCallUint256Assertions executable bytecode contains an asset-moving or delegated operation" >&2
  exit 1
fi

if grep -Eq ': LOG[0-4]$' "$executable_opcodes"; then
  echo "StaticCallUint256Assertions executable bytecode emits an event" >&2
  exit 1
fi

echo "StaticCallUint256Assertions exposes only its interface and has no storage, events, or payable path"
