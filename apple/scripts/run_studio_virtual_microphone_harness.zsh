#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build_virtual_microphone_prototype.zsh
readonly VMIC_VALIDATION_DIR="build/virtual-microphone-prototype"
readonly VMIC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -std=c11 -D_DEFAULT_SOURCE -O2 -isysroot "$VMIC_SDK" -framework CoreAudio -framework CoreFoundation \
  scripts/studio_virtual_microphone_harness.c -o "$VMIC_VALIDATION_DIR/harness"
"$VMIC_VALIDATION_DIR/harness" "$PWD/$VMIC_VALIDATION_DIR/StreamVirtualMicrophone.driver/Contents/MacOS/StreamVirtualMicrophone"
