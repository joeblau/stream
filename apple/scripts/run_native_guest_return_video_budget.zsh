#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_RETURN_VIDEO_BUDGET_BUILD_DIR:-${APPLE_DIR}/build/guest-return-video-budget}
mkdir -p "${BUILD_DIR}"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${APPLE_DIR}/StreamMac/NativeGuestReturnVideoBudget.swift" \
  "${SCRIPT_DIR}/native_guest_return_video_budget_harness.swift" \
  -o "${BUILD_DIR}/NativeGuestReturnVideoBudgetHarness"
"${BUILD_DIR}/NativeGuestReturnVideoBudgetHarness"
