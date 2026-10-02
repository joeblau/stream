#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECOVERY_BUILD_PATH="${RECOVERY_BUILD_PATH:-build/session-recovery-validation}"
mkdir -p "$RECOVERY_BUILD_PATH"
xcodegen generate
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$RECOVERY_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$RECOVERY_BUILD_PATH.log" 2>&1
readonly RECOVERY_PRODUCTS="$RECOVERY_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$RECOVERY_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${RECOVERY_PRODUCTS:A}" \
    StreamMac/SessionRecoveryCoordinator.swift StreamMac/SessionRecordingJournalReader.swift \
    scripts/session_recovery_harness.swift -o "$RECOVERY_BUILD_PATH/session-recovery-harness"
"$RECOVERY_BUILD_PATH/session-recovery-harness"
