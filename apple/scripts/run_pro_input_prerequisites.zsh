#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PRO_DIR="build/pro-input-validation"
mkdir -p "$PRO_DIR"
swiftc scripts/pro_input_prerequisites.swift -o "$PRO_DIR/prerequisites"
if [[ "${1:-}" == "--test" ]]; then
    python3 scripts/test_pro_input_prerequisites.py "$PRO_DIR/prerequisites"
    exit 0
fi
if (( $# != 0 )); then
    print -u2 'Usage: run_pro_input_prerequisites.zsh [--test]'
    exit 64
fi
"$PRO_DIR/prerequisites" | tee "$PRO_DIR/prerequisites.json"
