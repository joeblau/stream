#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SHORTCUT_DIR="build/studio-shortcuts-validation"
mkdir -p "$SHORTCUT_DIR"
swiftc -swift-version 6 -parse-as-library -framework AppKit -framework Carbon \
  StreamMac/StudioShortcutModel.swift StreamMac/StudioShortcutController.swift \
  scripts/studio_shortcuts_harness.swift -o "$SHORTCUT_DIR/harness"
"$SHORTCUT_DIR/harness"
