#!/usr/bin/env bash
set -euo pipefail

readonly contracts=(
  "DefiSimplify7702Account"
  "FlowAssertions"
  "StaticCallUint256Assertions"
)

command -v cast >/dev/null || {
  echo "cast is required to inspect deployed bytecode" >&2
  exit 1
}

command -v forge >/dev/null || {
  echo "forge is required to inspect contract artifacts" >&2
  exit 1
}

command -v jq >/dev/null || {
  echo "jq is required to inspect contract artifacts" >&2
  exit 1
}

for contract in "${contracts[@]}"; do
  case "$contract" in
    DefiSimplify7702Account)
      artifact="out/DefiSimplify7702Account.sol/DefiSimplify7702Account.json"
      ;;
    FlowAssertions)
      artifact="out/FlowAssertions.sol/FlowAssertions.json"
      ;;
    StaticCallUint256Assertions)
      artifact="out/StaticCallUint256Assertions.sol/StaticCallUint256Assertions.json"
      ;;
  esac

  if [[ ! -f "$artifact" ]]; then
    echo "Missing build artifact for $contract; run forge build first" >&2
    exit 1
  fi

  storage_count="$(jq '(.storageLayout.storage // []) | length' "$artifact")"
  if [[ "$storage_count" != "0" ]]; then
    echo "$contract defines $storage_count permanent storage entries" >&2
    exit 1
  fi

  event_count="$(jq '[.abi[] | select(.type == "event")] | length' "$artifact")"
  if [[ "$event_count" != "0" ]]; then
    echo "$contract exposes $event_count custom events" >&2
    exit 1
  fi

  if [[ "$(jq '(.bytecode.linkReferences // {}) == {}' "$artifact")" != "true" ]]; then
    echo "$contract creation bytecode requires a linked library" >&2
    exit 1
  fi
  if [[ "$(jq '(.deployedBytecode.linkReferences // {}) == {}' "$artifact")" != "true" ]]; then
    echo "$contract runtime bytecode requires a linked library" >&2
    exit 1
  fi

  deployed_bytecode="$(forge inspect "$contract" deployedBytecode)"
  bytecode="${deployed_bytecode#0x}"
  metadata_hex_length="${bytecode: -4}"
  metadata_character_count="$(( (16#$metadata_hex_length + 2) * 2 ))"
  executable_character_count="$(( ${#bytecode} - metadata_character_count ))"
  executable_opcodes="$(mktemp)"
  cast disassemble "0x${bytecode:0:executable_character_count}" > "$executable_opcodes"

  if grep -Eq ': (CALLCODE|DELEGATECALL)$' "$executable_opcodes"; then
    rm -f "$executable_opcodes"
    echo "$contract executable runtime contains proxy-style delegated execution" >&2
    exit 1
  fi
  rm -f "$executable_opcodes"

  if [[ "$contract" == "DefiSimplify7702Account" ]]; then
    constructor_types="$(
      jq -c '[.abi[] | select(.type == "constructor") | .inputs[].type]' "$artifact"
    )"
    if [[ "$constructor_types" != '["address"]' ]]; then
      echo "DefiSimplify7702Account must have only the immutable EntryPoint constructor argument" >&2
      exit 1
    fi

    immutable_reference_count="$(
      jq '[.deployedBytecode.immutableReferences // {} | to_entries[]?.value[]?] | length' "$artifact"
    )"
    if [[ "$immutable_reference_count" == "0" ]]; then
      echo "DefiSimplify7702Account runtime does not contain the immutable EntryPoint reference" >&2
      exit 1
    fi
  else
    constructor_count="$(jq '[.abi[] | select(.type == "constructor")] | length' "$artifact")"
    if [[ "$constructor_count" != "0" ]]; then
      echo "$contract must remain constructor-free" >&2
      exit 1
    fi

    immutable_reference_count="$(
      jq '[.deployedBytecode.immutableReferences // {} | to_entries[]?.value[]?] | length' "$artifact"
    )"
    if [[ "$immutable_reference_count" != "0" ]]; then
      echo "$contract unexpectedly contains immutable runtime substitutions" >&2
      exit 1
    fi
  fi

  echo "$contract is a direct, unlinked, eventless artifact with no permanent storage or proxy runtime"
done
