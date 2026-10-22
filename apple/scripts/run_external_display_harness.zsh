#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly EXTERNAL_DISPLAY_BUILD_PATH="${EXTERNAL_DISPLAY_BUILD_PATH:-build/external-display-validation}"
mkdir -p "$EXTERNAL_DISPLAY_BUILD_PATH"
if [[ -z "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
    xcodegen generate
    xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' \
        -jobs "${STREAM_XCODE_JOBS:-2}" -derivedDataPath "$EXTERNAL_DISPLAY_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build-for-testing > "$EXTERNAL_DISPLAY_BUILD_PATH.log" 2>&1
    STREAM_CORE_FRAMEWORK_DIR="$EXTERNAL_DISPLAY_BUILD_PATH/Build/Products/Debug"
fi
cat > "$EXTERNAL_DISPLAY_BUILD_PATH/CompositedFrame.swift" <<'FRAME_IMPORTS'
import CoreMedia
import CoreVideo
FRAME_IMPORTS
# Compile the shipping frame value without pulling the entire app actor graph.
sed -n '/^struct CompositedFrame:/,/^}/p' StreamMac/CompositionEngine.swift >> "$EXTERNAL_DISPLAY_BUILD_PATH/CompositedFrame.swift"
readonly EXTERNAL_DISPLAY_PRODUCTS="$STREAM_CORE_FRAMEWORK_DIR"
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$EXTERNAL_DISPLAY_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${EXTERNAL_DISPLAY_PRODUCTS:A}" \
    StreamMac/ExternalDisplayOutputController.swift StreamMac/ExternalProgramImageConverter.swift StreamMac/CompositorWorkloadBudget.swift \
    "$EXTERNAL_DISPLAY_BUILD_PATH/CompositedFrame.swift" scripts/external_display_harness.swift \
    -o "$EXTERNAL_DISPLAY_BUILD_PATH/external-display-harness"
env DYLD_FRAMEWORK_PATH="${EXTERNAL_DISPLAY_PRODUCTS:A}" "$EXTERNAL_DISPLAY_BUILD_PATH/external-display-harness" "${EXTERNAL_DISPLAY_BUILD_PATH:A}/artifacts-$(uuidgen)"
