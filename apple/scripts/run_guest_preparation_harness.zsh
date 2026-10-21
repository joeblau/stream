#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly GUEST_DIR="build/guest-preparation-validation"
readonly GUEST_CORE_DIR="${GUEST_PRODUCTS_PATH:-${STREAM_CORE_FRAMEWORK_DIR:-$PWD/build/mac/Build/Products/Debug}}"
[[ -d "$GUEST_CORE_DIR/StreamCore.framework" ]] || { print -u2 'Set STREAM_CORE_FRAMEWORK_DIR to a built macOS StreamCore framework directory.'; exit 1; }
mkdir -p "$GUEST_DIR"
sed '/^\/\/ MARK: - Take → program-engine hand-off/,$d' StreamMac/TransitionController.swift > "$GUEST_DIR/SceneTransition.swift"
sed '/^final class MediaSourcePlayback/,$d' StreamMac/MediaSourcePlayback.swift > "$GUEST_DIR/MediaValues.swift"
{ print 'import Foundation'; print 'import CryptoKit'; print 'import StreamCore'; sed -n '/^extension LayerPayload/,$p' StreamMac/WebOverlayIntegration.swift; } > "$GUEST_DIR/WebValues.swift"
# Compile the actual lock-protected stores without the unrelated engine.
python3 - "$GUEST_DIR/CompositionStores.swift" <<'PY'
import sys
source=open('StreamMac/CompositionEngine.swift').read()
first=source.index('final class ProjectOverlayStore:')
last=source.index('/// The W08 GPU composition engine',first)
open(sys.argv[1],'w').write('import Foundation\nimport os.lock\n'+source[first:last])
PY
cat > "$GUEST_DIR/StorageFixture.swift" <<'SWIFT'
import Foundation
// Every SceneStore below receives a unique temp directory explicitly. A fixture
// default prevents accidental access to the operator's configured project.
enum DesktopStorage { static var projectDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("unused-guest-preparation-default") } }
SWIFT
swiftc -swift-version 6 -parse-as-library -F "$GUEST_CORE_DIR" -framework StreamCore \
    StreamMac/LayerGraph.swift StreamMac/SecondaryCanvasLayout.swift StreamMac/LayerStyle.swift StreamMac/SourceEffects.swift \
    StreamMac/TextLayer.swift StreamMac/GuestSlots.swift StreamMac/GuestPreparationView.swift \
    StreamMac/SceneModel.swift StreamMac/SceneMigration.swift StreamMac/SceneDocumentMigration.swift \
    StreamMac/LayerMotion.swift "$GUEST_DIR/SceneTransition.swift" "$GUEST_DIR/MediaValues.swift" \
    "$GUEST_DIR/WebValues.swift" "$GUEST_DIR/CompositionStores.swift" "$GUEST_DIR/StorageFixture.swift" \
    scripts/guest_preparation_harness.swift -o "$GUEST_DIR/harness"
env DYLD_FRAMEWORK_PATH="$GUEST_CORE_DIR" "$GUEST_DIR/harness"
