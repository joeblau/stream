#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RESTREAM_BUILD_PATH="${RESTREAM_BUILD_PATH:-build/restream-provider-validation}"
mkdir -p "$RESTREAM_BUILD_PATH"
# Exact production Core sources, no app/vendor build or real credential store.
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
    -module-name StreamCore StreamCore/*.swift \
    -emit-module-path "$RESTREAM_BUILD_PATH/StreamCore.swiftmodule" -o "$RESTREAM_BUILD_PATH/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library -DSTREAM_NATIVE_VALIDATION \
    -I "$RESTREAM_BUILD_PATH" -L "$RESTREAM_BUILD_PATH" -lStreamCore \
    -Xlinker -rpath -Xlinker "${RESTREAM_BUILD_PATH:A}" \
    StreamMac/ProviderHTTP.swift StreamMac/ProviderTokenVault.swift StreamMac/OAuthLoopbackReceiver.swift \
    StreamMac/StudioChatModel.swift StreamMac/StudioDirectChatModel.swift StreamMac/StudioChatSocket.swift \
    StreamMac/StudioChatOutbox.swift StreamMac/StudioDirectChatManager.swift StreamMac/ProviderPendingCatalog.swift \
    StreamMac/ProviderAccountSession.swift StreamMac/DestinationSession.swift StreamMac/ProviderAccountsView.swift \
    StreamMac/YouTubeStreamControls.swift StreamMac/DirectChatControls.swift Stream/RestreamChat.swift \
    scripts/restream_provider_harness.swift -o "$RESTREAM_BUILD_PATH/harness"
"$RESTREAM_BUILD_PATH/harness"
