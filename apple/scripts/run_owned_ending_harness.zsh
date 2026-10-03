#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly OWNED_ENDING_BUILD_PATH="${OWNED_ENDING_BUILD_PATH:-build/owned-ending-validation}"
mkdir -p "$OWNED_ENDING_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$OWNED_ENDING_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$OWNED_ENDING_BUILD_PATH.log" 2>&1
readonly OWNED_ENDING_PRODUCTS="$OWNED_ENDING_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -D STREAM_NATIVE_VALIDATION \
    -F "$OWNED_ENDING_PRODUCTS" -framework StreamCore -Xlinker -rpath -Xlinker "${OWNED_ENDING_PRODUCTS:A}" \
    StreamMac/ProviderHTTP.swift StreamMac/ProviderTokenVault.swift StreamMac/OAuthLoopbackReceiver.swift \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioChatOutbox.swift StreamMac/StudioDirectChatManager.swift StreamMac/ProviderPendingCatalog.swift StreamMac/ProviderAccountSession.swift \
    StreamBroadcast/Publisher.swift StreamMac/SessionState.swift StreamMac/DestinationOutputController.swift \
    StreamMac/DestinationEncodedMailbox.swift StreamMac/DestinationSharedEncoder.swift \
    StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift StreamMac/RecordingChatTypes.swift \
    StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift \
    scripts/program_recording_fixtures.swift scripts/owned_ending_harness.swift -o "$OWNED_ENDING_BUILD_PATH/owned-ending-harness"
"$OWNED_ENDING_BUILD_PATH/owned-ending-harness"
