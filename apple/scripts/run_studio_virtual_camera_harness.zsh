#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CAMERA_HARNESS_DIR="build/studio-virtual-camera-validation"
mkdir -p "$CAMERA_HARNESS_DIR"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  VirtualOutputShared/VirtualCameraContract.swift \
  StreamCameraExtension/CameraProvider.swift StreamCameraExtension/CameraSink.swift \
  scripts/studio_virtual_camera_harness.swift -o "$CAMERA_HARNESS_DIR/harness"
"$CAMERA_HARNESS_DIR/harness"
