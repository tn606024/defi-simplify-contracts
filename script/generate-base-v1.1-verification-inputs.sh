#!/usr/bin/env bash
set -euo pipefail

readonly output_directory="${1:-out/verification/base-v1.1-candidate}"

./script/check-base-v1.1-candidate-manifest.sh >/dev/null
./script/generate-base-v1-verification-inputs.sh "$output_directory"
