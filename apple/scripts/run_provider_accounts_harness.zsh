#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PROVIDERS_BUILD_PATH="${PROVIDERS_BUILD_PATH:-build/providers-validation}"
mkdir -p "$PROVIDERS_BUILD_PATH"
if [[ "${STREAM_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then xcodegen generate; fi
xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
    -derivedDataPath "$PROVIDERS_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$PROVIDERS_BUILD_PATH.log" 2>&1
readonly PROVIDERS_PRODUCTS="$PROVIDERS_BUILD_PATH/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$PROVIDERS_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${PROVIDERS_PRODUCTS:A}" \
    StreamMac/ProviderHTTP.swift StreamMac/ProviderTokenVault.swift StreamMac/OAuthLoopbackReceiver.swift \
    StreamMac/ProviderAccountSession.swift scripts/provider_accounts_harness.swift \
    -o "$PROVIDERS_BUILD_PATH/providers-harness"
"$PROVIDERS_BUILD_PATH/providers-harness"
