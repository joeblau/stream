#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BROWSER_COMMAND_DIR="build/browser-helper-command-validation"
mkdir -p "$BROWSER_COMMAND_DIR"
swiftc -swift-version 6 -j 2 -parse-as-library -DSTREAM_NATIVE_VALIDATION \
  StreamMac/BrowserCaptureExclusions.swift StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetLocalContent.swift StreamMac/BrowserWidgetVisualProtocol.swift \
  StreamMac/BrowserWidgetAudioSocket.swift StreamMac/BrowserWidgetAudioCapture.swift \
  StreamMac/BrowserWidgetHelperSession.swift scripts/browser_helper_lifecycle_checks.swift \
  scripts/browser_helper_command_fixture.swift -o "$BROWSER_COMMAND_DIR/harness"
"$BROWSER_COMMAND_DIR/harness"
