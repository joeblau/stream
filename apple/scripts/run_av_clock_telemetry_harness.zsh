#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CLOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stream-av-clock.XXXXXX")"
trap 'rm -rf "$CLOCK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library StreamCore/AVClockTelemetry.swift scripts/av_clock_telemetry_harness.swift -o "$CLOCK_DIR/clock"
"$CLOCK_DIR/clock"
