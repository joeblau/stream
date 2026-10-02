#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CONTROL_DIR="build/studio-local-control-validation"
mkdir -p "$CONTROL_DIR"
swiftc -swift-version 6 -parse-as-library -framework Network -framework Security \
  StreamMac/SessionState.swift StreamMac/ShowMacroController.swift StreamMac/StudioControlProtocol.swift \
  StreamMac/StudioControlPairingStore.swift StreamMac/StudioLocalControlServer.swift \
  scripts/studio_local_control_harness.swift -o "$CONTROL_DIR/harness"
"$CONTROL_DIR/harness"
