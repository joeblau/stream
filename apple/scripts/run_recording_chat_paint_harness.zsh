#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PAINT_BUILD_PATH="${PAINT_BUILD_PATH:-build/recording-chat-paint-validation}"
mkdir -p "$PAINT_BUILD_PATH"
xcrun swiftc -swift-version 6 -parse-as-library -O -j2 \
    -framework CoreMedia -framework CryptoKit -framework Foundation \
    StreamMac/RecordingChatPaint.swift scripts/recording_chat_paint_harness.swift \
    -o "$PAINT_BUILD_PATH/recording-chat-paint-harness"
python3 - "${PAINT_BUILD_PATH:A}/recording-chat-paint-harness" "${PAINT_BUILD_PATH:A}/result.json" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], timeout=15)
except subprocess.TimeoutExpired:
    print("FAIL: owned recording chat paint fixture exceeded15 seconds", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
