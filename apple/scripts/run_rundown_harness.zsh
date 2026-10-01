#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RUNDOWN_DIR="build/rundown-validation"
mkdir -p "$RUNDOWN_DIR"
if [[ -z "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
    xcodegen generate
    xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
        -configuration Debug -derivedDataPath "$RUNDOWN_DIR/derived" \
        CODE_SIGNING_ALLOWED=NO build
    STREAM_CORE_FRAMEWORK_DIR="$PWD/$RUNDOWN_DIR/derived/Build/Products/Debug"
fi
# Compile real scene/transition values without the unrelated capture runtime.
sed '/^\/\/ MARK: - Take → program-engine hand-off/,$d' StreamMac/TransitionController.swift \
    > "$RUNDOWN_DIR/SceneTransition.swift"
sed '/^final class MediaSourcePlayback/,$d' StreamMac/MediaSourcePlayback.swift > "$RUNDOWN_DIR/MediaValues.swift"
sed -n '/^extension LayerPayload/,$p' StreamMac/WebOverlayIntegration.swift > "$RUNDOWN_DIR/WebValues.swift"
swiftc -swift-version 6 -parse-as-library -F "$STREAM_CORE_FRAMEWORK_DIR" -framework StreamCore \
    StreamMac/LayerGraph.swift StreamMac/LayerStyle.swift StreamMac/SourceEffects.swift \
    StreamMac/TextLayer.swift StreamMac/LayerMotion.swift "$RUNDOWN_DIR/SceneTransition.swift" \
    "$RUNDOWN_DIR/MediaValues.swift" "$RUNDOWN_DIR/WebValues.swift" \
    StreamMac/DynamicOverlayStore.swift StreamMac/ShowRundownController.swift scripts/rundown_harness.swift -o "$RUNDOWN_DIR/harness"
env DYLD_FRAMEWORK_PATH="$STREAM_CORE_FRAMEWORK_DIR" "$RUNDOWN_DIR/harness" "$RUNDOWN_DIR/fixtures"
