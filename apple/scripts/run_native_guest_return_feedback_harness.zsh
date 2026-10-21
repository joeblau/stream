#!/bin/zsh
set -euo pipefail
readonly FEEDBACK_SCRIPT_DIR=${0:A:h}
readonly FEEDBACK_BUILD_DIR=${STREAM_GUEST_FEEDBACK_BUILD_DIR:-${FEEDBACK_SCRIPT_DIR:h}/build/native-guest-return-feedback}
mkdir -p "$FEEDBACK_BUILD_DIR"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
  -mmacosx-version-min=14.0 "$FEEDBACK_SCRIPT_DIR/native_guest_return_feedback_harness.cpp" \
  -o "$FEEDBACK_BUILD_DIR/NativeGuestReturnFeedbackHarness"
"$FEEDBACK_BUILD_DIR/NativeGuestReturnFeedbackHarness"
