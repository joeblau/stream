#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly REVIEW_BUILD_PATH="${REVIEW_BUILD_PATH:-build/recovery-event-validation}"
mkdir -p "$REVIEW_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$REVIEW_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$REVIEW_BUILD_PATH.log" 2>&1
readonly REVIEW_PRODUCTS="$REVIEW_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$REVIEW_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${REVIEW_PRODUCTS:A}" \
    StreamBroadcast/Publisher.swift StreamMac/SessionState.swift \
    StreamMac/DestinationOutputController.swift StreamMac/DestinationEncodedMailbox.swift StreamMac/DestinationSharedEncoder.swift \
    StreamMac/SessionRecoveryCoordinator.swift StreamMac/RecoveryEventReviewCoordinator.swift \
    scripts/recovery_event_review_harness.swift -o "$REVIEW_BUILD_PATH/recovery-event-harness"
"$REVIEW_BUILD_PATH/recovery-event-harness"
