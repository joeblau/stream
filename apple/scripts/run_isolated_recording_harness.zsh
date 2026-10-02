#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ISO_BUILD_DIR="build/isolated-recording-validation"
readonly ISO_FRAMEWORKS="build/recording-controller-validation/derived/Build/Products/Debug"
mkdir -p "$ISO_BUILD_DIR"
if [[ ! -d "$ISO_FRAMEWORKS/StreamCore.framework" ]]; then
  scripts/run_recording_controller_harness.zsh
fi
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$ISO_FRAMEWORKS" -framework StreamCore \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift StreamMac/RecordingPreferences.swift \
  StreamMac/ProgramRecordingSession.swift StreamMac/IsolatedAudioRecorder.swift \
  StreamMac/AudioMixEngine.swift scripts/program_recording_fixtures.swift \
  scripts/isolated_recording_harness.swift -o "$ISO_BUILD_DIR/IsolatedRecordingHarness"
env DYLD_FRAMEWORK_PATH="$PWD/$ISO_FRAMEWORKS" \
  "$ISO_BUILD_DIR/IsolatedRecordingHarness" "$ISO_BUILD_DIR/media-$(uuidgen)"
