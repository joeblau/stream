#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_LIBRARY_BUILD_DIR="build/recording-library-validation"
mkdir -p "$RECORDING_LIBRARY_BUILD_DIR"
# The recorder's actual raw-video admission types live in StreamCore. Reuse
# an explicit matching framework or compile its real sources as an owned module.
RECORDING_LIBRARY_CORE_ARGUMENTS=()
if [[ -n "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
  [[ -d "$STREAM_CORE_FRAMEWORK_DIR/StreamCore.framework" ]] || { print -u2 'Set STREAM_CORE_FRAMEWORK_DIR to matching StreamCore products.'; exit 1; }
  RECORDING_LIBRARY_CORE_ARGUMENTS=(-F "$STREAM_CORE_FRAMEWORK_DIR" -framework StreamCore -Xlinker -rpath -Xlinker "${STREAM_CORE_FRAMEWORK_DIR:A}")
else
  readonly RECORDING_LIBRARY_CORE_DIR="${RECORDING_LIBRARY_BUILD_DIR:A}/core"
  mkdir -p "$RECORDING_LIBRARY_CORE_DIR"
  xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
    -target "$(uname -m)-apple-macos14.0" -module-name StreamCore StreamCore/*.swift \
    -emit-module-path "$RECORDING_LIBRARY_CORE_DIR/StreamCore.swiftmodule" -o "$RECORDING_LIBRARY_CORE_DIR/libStreamCore.dylib"
  RECORDING_LIBRARY_CORE_ARGUMENTS=(-I "$RECORDING_LIBRARY_CORE_DIR" -L "$RECORDING_LIBRARY_CORE_DIR" -lStreamCore -Xlinker -rpath -Xlinker "$RECORDING_LIBRARY_CORE_DIR")
fi
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${RECORDING_LIBRARY_CORE_ARGUMENTS[@]}" \
  -target "$(uname -m)-apple-macos14.0" \
  StreamMac/RawVideoResourceCoordinator.swift StreamMac/FrameDeliveryBroker.swift StreamMac/FrameDeliveryConverter.swift StreamMac/RecordingFrameDelivery.swift \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift StreamMac/RecordingChatPaint.swift StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift \
  StreamMac/RecordingLibraryModel.swift scripts/program_recording_fixtures.swift \
  scripts/recording_library_harness.swift -o "$RECORDING_LIBRARY_BUILD_DIR/RecordingLibraryHarness"
"$RECORDING_LIBRARY_BUILD_DIR/RecordingLibraryHarness" "$RECORDING_LIBRARY_BUILD_DIR/media-$(uuidgen)" "${1:-}"
