#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
BUILD_DIR=${STREAM_GUEST_H264_PACKET_BUILD_DIR:-${SCRIPT_DIR:h}/build/native-guest-return-h264}
mkdir -p "$BUILD_DIR"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
  -mmacosx-version-min=14.0 "$SCRIPT_DIR/native_guest_return_h264_harness.cpp" \
  -o "$BUILD_DIR/NativeGuestReturnH264Harness"
"$BUILD_DIR/NativeGuestReturnH264Harness"
