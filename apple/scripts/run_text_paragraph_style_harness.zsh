#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PARAGRAPH_STYLE_DIR="${PARAGRAPH_STYLE_DIR:-build/text-paragraph-style-validation}"
mkdir -p "$PARAGRAPH_STYLE_DIR"
# Compile the exact shipping implementation, optimized, with diagnostics fatal.
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -O -warnings-as-errors -parse-as-library \
  StreamCore/TextLayout.swift scripts/text_paragraph_style_harness.swift \
  -o "$PARAGRAPH_STYLE_DIR/harness"
"$PARAGRAPH_STYLE_DIR/harness"
