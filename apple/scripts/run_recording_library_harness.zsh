#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_LIBRARY_BUILD_DIR="build/recording-library-validation"
mkdir -p "$RECORDING_LIBRARY_BUILD_DIR"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift \
  StreamMac/RecordingLibraryModel.swift scripts/program_recording_fixtures.swift \
  scripts/recording_library_harness.swift -o "$RECORDING_LIBRARY_BUILD_DIR/RecordingLibraryHarness"
"$RECORDING_LIBRARY_BUILD_DIR/RecordingLibraryHarness" "$RECORDING_LIBRARY_BUILD_DIR/media-$(uuidgen)"
