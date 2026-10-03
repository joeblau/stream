#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CHAT_BUILD_PATH="${CHAT_BUILD_PATH:-build/direct-chat-validation}"
mkdir -p "$CHAT_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$CHAT_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$CHAT_BUILD_PATH.log" 2>&1
readonly CHAT_PRODUCTS="$CHAT_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -F "$CHAT_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${CHAT_PRODUCTS:A}" \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioDirectChatManager.swift scripts/direct_chat_harness.swift \
    -o "$CHAT_BUILD_PATH/direct-chat-harness"
"$CHAT_BUILD_PATH/direct-chat-harness"
