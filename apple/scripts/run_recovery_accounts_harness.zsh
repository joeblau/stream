#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly REVIEW_ACCOUNTS_BUILD_PATH="${REVIEW_ACCOUNTS_BUILD_PATH:-build/recovery-accounts-validation}"
mkdir -p "$REVIEW_ACCOUNTS_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$REVIEW_ACCOUNTS_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$REVIEW_ACCOUNTS_BUILD_PATH.log" 2>&1
readonly REVIEW_ACCOUNTS_PRODUCTS="$REVIEW_ACCOUNTS_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -F "$REVIEW_ACCOUNTS_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${REVIEW_ACCOUNTS_PRODUCTS:A}" \
    StreamMac/ProviderHTTP.swift StreamMac/ProviderTokenVault.swift StreamMac/OAuthLoopbackReceiver.swift \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioChatOutbox.swift StreamMac/StudioDirectChatManager.swift StreamMac/ProviderPendingCatalog.swift StreamMac/ProviderAccountSession.swift \
    StreamMac/RecoveryEventReviewCoordinator.swift StreamMac/RecoveryEventReviewAccountBinding.swift scripts/recovery_accounts_harness.swift \
    -o "$REVIEW_ACCOUNTS_BUILD_PATH/recovery-accounts-harness"
"$REVIEW_ACCOUNTS_BUILD_PATH/recovery-accounts-harness"
