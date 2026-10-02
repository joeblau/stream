#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CONTROLLERS_DIR="build/studio-controllers-validation"
mkdir -p "$CONTROLLERS_DIR"
swiftc -swift-version 6 -parse-as-library -framework CoreMIDI -framework Network -framework SwiftUI \
  StreamMac/StudioControllerMappings.swift StreamMac/StudioControllerTransport.swift StreamMac/StudioControllerManager.swift StreamMac/StudioControllerPanel.swift \
  scripts/studio_controllers_harness.swift -o "$CONTROLLERS_DIR/harness"
"$CONTROLLERS_DIR/harness"
