#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PTZ_AUTHORITY_DIR="${PTZ_AUTHORITY_DIR:-build/ptz-control-authority}"
mkdir -p "$PTZ_AUTHORITY_DIR"
# Storage identities only: the actual store uses documentStore:nil, so no
# application container, user document, UI, network or device is opened.
cat > "$PTZ_AUTHORITY_DIR/CoreSupport.swift" <<'SWIFT'
public enum AppGroup { public static let identifier = "com.joeblau.Stream.ptz-owned-fixture" }
SWIFT
cat > "$PTZ_AUTHORITY_DIR/StorageSupport.swift" <<'SWIFT'
import Foundation
enum DesktopStorage { static let projectDirectory = URL(fileURLWithPath: "/unused-owned-ptz-fixture") }
SWIFT
xcrun swiftc -swift-version 6 -j2 -emit-library -emit-module -module-name StreamCore \
  StreamCore/PTZ.swift "$PTZ_AUTHORITY_DIR/CoreSupport.swift" \
  -o "$PTZ_AUTHORITY_DIR/libStreamCore.dylib" -emit-module-path "$PTZ_AUTHORITY_DIR/StreamCore.swiftmodule"
xcrun swiftc -swift-version 6 -j2 -parse-as-library -I "$PTZ_AUTHORITY_DIR" -L "$PTZ_AUTHORITY_DIR" -lStreamCore \
  "$PTZ_AUTHORITY_DIR/StorageSupport.swift" StreamMac/PTZPresetStore.swift \
  "${PTZ_CONTROLLER_SOURCE:-StreamMac/PTZController.swift}" StreamMac/PTZTransport.swift \
  StreamMac/PTZMotionButton.swift \
  scripts/ptz_control_authority_harness.swift -o "$PTZ_AUTHORITY_DIR/PTZControlAuthorityHarness"
env DYLD_LIBRARY_PATH="${PTZ_AUTHORITY_DIR:A}" "$PTZ_AUTHORITY_DIR/PTZControlAuthorityHarness"
