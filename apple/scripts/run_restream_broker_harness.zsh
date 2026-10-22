#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BROKER_BUILD_PATH="${BROKER_BUILD_PATH:-build/restream-broker-validation}"
mkdir -p "$BROKER_BUILD_PATH"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
  -module-name StreamCore StreamCore/*.swift -emit-module-path "$BROKER_BUILD_PATH/StreamCore.swiftmodule" -o "$BROKER_BUILD_PATH/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -parse-as-library -DSTREAM_NATIVE_VALIDATION \
  -I "$BROKER_BUILD_PATH" -L "$BROKER_BUILD_PATH" -lStreamCore -Xlinker -rpath -Xlinker "${BROKER_BUILD_PATH:A}" \
  StreamMac/ProviderHTTP.swift Stream/RestreamChat.swift scripts/restream_broker_harness.swift -o "$BROKER_BUILD_PATH/harness"
"$BROKER_BUILD_PATH/harness"
