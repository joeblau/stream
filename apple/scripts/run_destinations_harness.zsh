#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DESTINATIONS_BUILD_PATH="${DESTINATIONS_BUILD_PATH:-build/destinations-validation}"
xcodegen generate
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$DESTINATIONS_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build > "$DESTINATIONS_BUILD_PATH.log" 2>&1
readonly DESTINATIONS_PRODUCTS="$DESTINATIONS_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$DESTINATIONS_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${DESTINATIONS_PRODUCTS:A}" \
    StreamBroadcast/Publisher.swift StreamMac/SessionState.swift \
    StreamMac/DestinationOutputController.swift scripts/destinations_harness.swift \
    -o "$DESTINATIONS_BUILD_PATH/destinations-harness"
"$DESTINATIONS_BUILD_PATH/destinations-harness"
