#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_BUILD_DIR="build/recording-frame-delivery-validation"
readonly RAW_SOURCES="${STREAM_RECORDING_RAW_SOURCE_ROOT:-$PWD}/StreamMac"
readonly BROKER_SOURCES="${STREAM_RECORDING_BROKER_SOURCE_ROOT:-$PWD}/StreamMac"
readonly CONVERTER_SOURCES="${STREAM_RECORDING_CONVERTER_SOURCE_ROOT:-$PWD}/StreamMac"
mkdir -p "$RECORDING_BUILD_DIR"
if [[ -n "${STREAM_RECORDING_FRAMEWORKS:-}" ]]; then
  readonly RECORDING_FRAMEWORKS="$STREAM_RECORDING_FRAMEWORKS"
else
  readonly RECORDING_FRAMEWORKS="$PWD/$RECORDING_BUILD_DIR/frameworks"
  mkdir -p "$RECORDING_FRAMEWORKS/StreamCore.framework/Modules"
  swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -emit-library -emit-module -module-name StreamCore \
    StreamCore/*.swift -o "$RECORDING_FRAMEWORKS/StreamCore.framework/StreamCore" \
    -emit-module-path "$RECORDING_FRAMEWORKS/StreamCore.framework/Modules/StreamCore.swiftmodule"
fi
swiftc -j2 -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$RECORDING_FRAMEWORKS" -framework StreamCore \
  -Xlinker -rpath -Xlinker "$RECORDING_FRAMEWORKS" \
  "$RAW_SOURCES/RawVideoResourceCoordinator.swift" "$BROKER_SOURCES/FrameDeliveryBroker.swift" \
  "$CONVERTER_SOURCES/FrameDeliveryConverter.swift" \
  StreamMac/RecordingChatPaint.swift StreamMac/RecordingFrameDelivery.swift \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift \
  StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift \
  StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift \
  scripts/recording_frame_delivery_harness.swift -o "$RECORDING_BUILD_DIR/RecordingFrameDeliveryHarness"
python3 - "$RECORDING_BUILD_DIR/RecordingFrameDeliveryHarness" "$RECORDING_BUILD_DIR" <<'PY'
import pathlib, subprocess, sys, uuid
executable = pathlib.Path(sys.argv[1]).resolve()
media = pathlib.Path(sys.argv[2]).resolve() / ("media-" + str(uuid.uuid4()))
print(f"Owned recording ingress media: {media}", flush=True)
try:
    completed = subprocess.run([str(executable), str(media)], timeout=120, check=False)
except subprocess.TimeoutExpired:
    print("UNQUALIFIED: owned recorder fixture exceeded120s; partial files retained", file=sys.stderr, flush=True)
    raise SystemExit(124)
raise SystemExit(completed.returncode if completed.returncode >= 0 else 128 - completed.returncode)
PY
