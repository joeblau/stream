#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ENDING_BUILD_PATH="${ENDING_BUILD_PATH:-build/ending-validation}"
mkdir -p "$ENDING_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$ENDING_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$ENDING_BUILD_PATH.log" 2>&1
readonly ENDING_PRODUCTS="$ENDING_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -F "$ENDING_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${ENDING_PRODUCTS:A}" \
    StreamBroadcast/Publisher.swift StreamMac/SessionState.swift StreamMac/DestinationOutputController.swift StreamMac/DestinationEncodedMailbox.swift StreamMac/DestinationSharedEncoder.swift \
    StreamMac/StudioEndingCoordinator.swift scripts/studio_ending_harness.swift \
    -o "$ENDING_BUILD_PATH/ending-harness"
"$ENDING_BUILD_PATH/ending-harness"
