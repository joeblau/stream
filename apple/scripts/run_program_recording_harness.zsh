#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_BUILD_DIR="build/program-recording-validation"
mkdir -p "$RECORDING_BUILD_DIR"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift scripts/program_recording_fixtures.swift scripts/program_recording_harness.swift \
  -o "$RECORDING_BUILD_DIR/ProgramRecordingHarness"
"$RECORDING_BUILD_DIR/ProgramRecordingHarness" "$RECORDING_BUILD_DIR/media"
