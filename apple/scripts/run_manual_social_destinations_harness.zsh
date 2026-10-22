#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MANUAL_SOCIAL_DIR="${MANUAL_SOCIAL_DIR:-build/manual-social-destinations-validation}"
mkdir -p "$MANUAL_SOCIAL_DIR"
# Rebuild exact production Core, including new templates. No cached framework.
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
  -module-name StreamCore StreamCore/*.swift \
  -emit-module-path "$MANUAL_SOCIAL_DIR/StreamCore.swiftmodule" -o "$MANUAL_SOCIAL_DIR/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -I "$MANUAL_SOCIAL_DIR" -L "$MANUAL_SOCIAL_DIR" -lStreamCore \
  -Xlinker -rpath -Xlinker "${MANUAL_SOCIAL_DIR:A}" \
  StreamMac/DestinationSession.swift scripts/manual_social_destinations_harness.swift \
  -o "$MANUAL_SOCIAL_DIR/harness"
"$MANUAL_SOCIAL_DIR/harness"
