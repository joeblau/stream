#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PACKAGE_BUILD="${VMIC_PACKAGE_BUILD_DIR:-build/virtual-microphone-package-validation}"
mkdir -p "$PACKAGE_BUILD"
readonly PACKAGE_RUN="$PACKAGE_BUILD/run-$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir "$PACKAGE_RUN"
STREAM_VMIC_BUILD_DIR="$PACKAGE_RUN/driver-build" zsh scripts/build_virtual_microphone_prototype.zsh
xcrun clang -std=c11 -D_DEFAULT_SOURCE -O2 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework CoreAudio -framework CoreFoundation scripts/studio_virtual_microphone_harness.c -o "$PACKAGE_RUN/callback-harness"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/virtual_microphone_package_harness.py \
  --driver "$PACKAGE_RUN/driver-build/StreamVirtualMicrophone.driver" \
  --callback-harness "$PACKAGE_RUN/callback-harness" --artifacts "$PACKAGE_RUN/artifacts"
