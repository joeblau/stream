#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ENDING_BUILD_PATH="${ENDING_BUILD_PATH:-build/ending-validation}"
mkdir -p "$ENDING_BUILD_PATH"
if [[ -z "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$ENDING_BUILD_PATH" CODE_SIGNING_ALLOWED=NO -jobs 2 build-for-testing > "$ENDING_BUILD_PATH.log" 2>&1
fi
readonly ENDING_PRODUCTS="${STREAM_CORE_FRAMEWORK_DIR:-$ENDING_BUILD_PATH/Build/Products/Debug}"
xcrun swiftc -j2 -swift-version 6 -parse-as-library -F "$ENDING_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${ENDING_PRODUCTS:A}" \
    StreamBroadcast/Publisher.swift StreamMac/SessionState.swift StreamMac/RecordingChatPaint.swift StreamMac/RawVideoResourceCoordinator.swift StreamMac/FrameDeliveryBroker.swift StreamMac/FrameDeliveryConverter.swift \
    StreamMac/DestinationVideoIngress.swift StreamMac/DestinationOutputController.swift StreamMac/DestinationEncodedMailbox.swift StreamMac/DestinationSharedEncoder.swift \
    StreamMac/StudioEndingCoordinator.swift scripts/studio_ending_harness.swift \
    -o "$ENDING_BUILD_PATH/ending-harness"
"$ENDING_BUILD_PATH/ending-harness"
