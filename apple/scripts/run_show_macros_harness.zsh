#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MACRO_DIR="build/show-macros-validation"
mkdir -p "$MACRO_DIR"
swiftc -swift-version 6 -parse-as-library StreamMac/ShowMacroController.swift scripts/show_macros_harness.swift -o "$MACRO_DIR/harness"
"$MACRO_DIR/harness"
