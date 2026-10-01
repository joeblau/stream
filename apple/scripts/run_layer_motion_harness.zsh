#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MOTION_DIR="build/layer-motion-validation"
mkdir -p "$MOTION_DIR"
if [[ -z "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
    xcodegen generate
    xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
        -configuration Debug -derivedDataPath "$MOTION_DIR/derived" \
        CODE_SIGNING_ALLOWED=NO build
    STREAM_CORE_FRAMEWORK_DIR="$PWD/$MOTION_DIR/derived/Build/Products/Debug"
fi
# Compile real scene/transition values without the unrelated capture runtime.
sed '/^\/\/ MARK: - Take → program-engine hand-off/,$d' StreamMac/TransitionController.swift \
    > "$MOTION_DIR/SceneTransition.swift"
sed '/^final class MediaSourcePlayback/,$d' StreamMac/MediaSourcePlayback.swift > "$MOTION_DIR/MediaValues.swift"
sed -n '/^extension LayerPayload/,$p' StreamMac/WebOverlayIntegration.swift > "$MOTION_DIR/WebValues.swift"
swiftc -swift-version 6 -parse-as-library -F "$STREAM_CORE_FRAMEWORK_DIR" -framework StreamCore \
    StreamMac/LayerGraph.swift StreamMac/LayerStyle.swift StreamMac/SourceEffects.swift \
    StreamMac/TextLayer.swift StreamMac/LayerMotion.swift "$MOTION_DIR/SceneTransition.swift" \
    "$MOTION_DIR/MediaValues.swift" "$MOTION_DIR/WebValues.swift" \
    scripts/layer_motion_harness.swift -o "$MOTION_DIR/harness"
env DYLD_FRAMEWORK_PATH="$STREAM_CORE_FRAMEWORK_DIR" "$MOTION_DIR/harness"
