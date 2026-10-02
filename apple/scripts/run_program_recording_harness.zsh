#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_BUILD_DIR="build/program-recording-validation"
mkdir -p "$RECORDING_BUILD_DIR"
# Hosted VMs exercise writer contracts, not a physical Mac's encoder cadence.
# Native qualification retains the zero-drop assertion unless explicitly off.
if [[ "${CI:-false}" == "true" ]]; then
  export STREAM_RECORDING_REQUIRE_REALTIME="${STREAM_RECORDING_REQUIRE_REALTIME:-0}"
else
  export STREAM_RECORDING_REQUIRE_REALTIME="${STREAM_RECORDING_REQUIRE_REALTIME:-1}"
fi
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift scripts/program_recording_fixtures.swift scripts/program_recording_harness.swift \
  -o "$RECORDING_BUILD_DIR/ProgramRecordingHarness"
"$RECORDING_BUILD_DIR/ProgramRecordingHarness" "$RECORDING_BUILD_DIR/media"
