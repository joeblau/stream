#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly OBSERVATION_DIR="${RESILIENCE_OBSERVATION_DIR:-build/resilience-observation-validation}"
mkdir -p "$OBSERVATION_DIR"
# Compile the actual standalone resilience model and production observers.
# No app/project build, source rewriting, system event, TCC or capture is needed.
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
    -module-name StreamCore StreamCore/DesktopResilience.swift \
    -emit-module-path "$OBSERVATION_DIR/StreamCore.swiftmodule" -o "$OBSERVATION_DIR/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -I "$OBSERVATION_DIR" -L "$OBSERVATION_DIR" -lStreamCore \
    -Xlinker -rpath -Xlinker "${OBSERVATION_DIR:A}" \
    StreamMac/DesktopResilienceCoordinator.swift StreamMac/DeviceMonitor.swift \
    scripts/resilience_observation_harness.swift -o "$OBSERVATION_DIR/harness"
"$OBSERVATION_DIR/harness"
