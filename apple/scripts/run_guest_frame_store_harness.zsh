#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_STORE_BUILD_DIR:-${APPLE_DIR}/build/guest-frame-store}
mkdir -p "${BUILD_DIR}"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -target "$(uname -m)-apple-macosx14.0" \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" \
  "${APPLE_DIR}/StreamMac/GuestVideoFrameStore.swift" \
  "${SCRIPT_DIR}/guest_frame_store_harness.swift" -o "${BUILD_DIR}/guest-frame-store-harness"
"${BUILD_DIR}/guest-frame-store-harness"
