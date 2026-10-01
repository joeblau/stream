#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PRO_DIR="build/pro-input-validation"
mkdir -p "$PRO_DIR"
swiftc scripts/pro_input_prerequisites.swift -o "$PRO_DIR/prerequisites"
"$PRO_DIR/prerequisites" | tee "$PRO_DIR/prerequisites.json"
