#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly GAIN_CHECK_DIR="${GAIN_CHECK_DIR:-build/studio-gain-accessibility}"
mkdir -p "$GAIN_CHECK_DIR"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  StreamMac/StudioGainAccessibility.swift scripts/studio_gain_accessibility_harness.swift \
  -o "$GAIN_CHECK_DIR/harness"
"$GAIN_CHECK_DIR/harness"
