#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly GIFT_BUILD_PATH="${GIFT_BUILD_PATH:-build/youtube-gift-events-validation}"
mkdir -p "$GIFT_BUILD_PATH"
if [[ -n "${CHAT_PRODUCTS_PATH:-}" ]]; then
    readonly CHAT_PRODUCTS="$CHAT_PRODUCTS_PATH"
else
    if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
    xcodebuild -jobs 2 -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
        -derivedDataPath "$GIFT_BUILD_PATH/derived" CODE_SIGNING_ALLOWED=NO \
        'OTHER_SWIFT_FLAGS=$(inherited) -j2' build-for-testing > "$GIFT_BUILD_PATH/core-build.log" 2>&1
    readonly CHAT_PRODUCTS="$GIFT_BUILD_PATH/derived/Build/Products/Debug"
fi
xcrun swiftc -swift-version 6 -parse-as-library -O -j2 -F "$CHAT_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${CHAT_PRODUCTS:A}" \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioChatOutbox.swift StreamMac/StudioDirectChatManager.swift scripts/youtube_gift_events_harness.swift \
    -o "$GIFT_BUILD_PATH/youtube-gift-events-harness"
python3 - "${GIFT_BUILD_PATH:A}/youtube-gift-events-harness" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("FAIL: owned YouTube gift event fixture exceeded 30 seconds", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
