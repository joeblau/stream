#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SCHEDULING_BUILD_PATH="${SCHEDULING_BUILD_PATH:-build/provider-scheduling-validation}"
mkdir -p "$SCHEDULING_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$SCHEDULING_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$SCHEDULING_BUILD_PATH.log" 2>&1
readonly SCHEDULING_PRODUCTS="$SCHEDULING_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -F "$SCHEDULING_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${SCHEDULING_PRODUCTS:A}" \
    StreamMac/ProviderHTTP.swift StreamMac/ProviderTokenVault.swift StreamMac/OAuthLoopbackReceiver.swift \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioChatOutbox.swift StreamMac/StudioDirectChatManager.swift \
    StreamMac/ProviderPendingCatalog.swift StreamMac/ProviderAccountSession.swift scripts/provider_scheduling_harness.swift \
    -o "$SCHEDULING_BUILD_PATH/provider-scheduling-harness"
"$SCHEDULING_BUILD_PATH/provider-scheduling-harness"
