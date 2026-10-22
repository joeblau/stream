#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SCENE_SEMANTICS_DIR="${SCENE_SEMANTICS_DIR:-build/scene-selection-semantics}"
mkdir -p "$SCENE_SEMANTICS_DIR"
xcrun clang -fobjc-arc -c scripts/scene_selection_ax_bridge.m -o "$SCENE_SEMANTICS_DIR/bridge.o"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -import-objc-header scripts/scene_selection_ax_bridge.h StreamMac/SceneSelectionButton.swift \
  scripts/scene_selection_native_harness.swift "$SCENE_SEMANTICS_DIR/bridge.o" -o "$SCENE_SEMANTICS_DIR/harness"
"$SCENE_SEMANTICS_DIR/harness"
