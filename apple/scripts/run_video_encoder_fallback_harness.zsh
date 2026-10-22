#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly VENDOR_DIR="${STREAM_VENDOR_ROOT:-$PWD/Vendor}/HaishinKit.swift/HaishinKit/Sources"
readonly OUTPUT_DIR="${VIDEO_ENCODER_FALLBACK_DIR:-$PWD/build/video-encoder-fallback-validation}"
mkdir -p "$OUTPUT_DIR"
# Compile the shipping codec/factory directly. Only logging is replaced by the
# harness; no capture, network, device, settings or production source is patched.
xcrun swiftc -j2 -package-name StreamEncoderFallback \
  scripts/video_encoder_fallback_harness.swift \
  "$VENDOR_DIR/Codec/VideoCodec.swift" \
  "$VENDOR_DIR/Codec/VideoCodecSettings.swift" \
  "$VENDOR_DIR/Codec/VTSessionMode.swift" \
  "$VENDOR_DIR/Codec/VTCompressionSessionFactory.swift" \
  "$VENDOR_DIR/Codec/VTSessionConvertible.swift" \
  "$VENDOR_DIR/Codec/VTSessionOption.swift" \
  "$VENDOR_DIR/Codec/VTSessionOptionKey.swift" \
  "$VENDOR_DIR/Extension/CMVideoFormatDescription+Extension.swift" \
  "$VENDOR_DIR/Extension/VTCompressionSession+Extension.swift" \
  "$VENDOR_DIR/Extension/VTDecompressionSession+Extension.swift" \
  "$VENDOR_DIR/Util/Runner.swift" \
  -o "$OUTPUT_DIR/VideoEncoderFallbackHarness"
# Keep malformed/hung native encoders bounded. The child group belongs solely
# to this fixture; no service or user process is signaled.
python3 - "$OUTPUT_DIR/VideoEncoderFallbackHarness" <<'PY'
import os
import signal
import subprocess
import sys

process = subprocess.Popen([sys.argv[1]], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=30))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("Owned encoder fallback fixture exceeded 30 seconds")
PY
