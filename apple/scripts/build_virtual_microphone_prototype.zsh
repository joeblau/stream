#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly VMIC_BUILD_DIR="${STREAM_VMIC_BUILD_DIR:-build/virtual-microphone-prototype}"
readonly VMIC_BUNDLE="$VMIC_BUILD_DIR/StreamVirtualMicrophone.driver"
readonly VMIC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$VMIC_BUNDLE/Contents/MacOS" "$VMIC_BUNDLE/Contents/Resources"
for VMIC_ARCH in arm64 x86_64; do
  xcrun clang -std=c11 -O2 -fblocks -isysroot "$VMIC_SDK" -mmacosx-version-min=14.0 -arch "$VMIC_ARCH" \
    -bundle -framework CoreAudio -framework CoreFoundation \
    prototypes/VirtualMicrophone/StreamVirtualMicrophone.c \
    prototypes/VirtualMicrophone/StreamLoopback.c \
    -o "$VMIC_BUILD_DIR/StreamVirtualMicrophone.$VMIC_ARCH"
done
xcrun lipo -create "$VMIC_BUILD_DIR/StreamVirtualMicrophone.arm64" "$VMIC_BUILD_DIR/StreamVirtualMicrophone.x86_64" \
  -output "$VMIC_BUNDLE/Contents/MacOS/StreamVirtualMicrophone"
cp prototypes/VirtualMicrophone/Info.plist "$VMIC_BUNDLE/Contents/Info.plist"
cp prototypes/VirtualMicrophone/LICENSE-Apple.txt "$VMIC_BUNDLE/Contents/Resources/LICENSE-Apple.txt"
# Earlier generated bundles placed this resource among nested code. Remove
# only that exact, unchanged generated license when rebuilding an owned cache.
if [[ -e "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt" || -L "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt" ]]; then
  [[ -f "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt" && ! -L "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt" ]] && \
    cmp -s prototypes/VirtualMicrophone/LICENSE-Apple.txt "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt" || {
      print -u2 'Unexpected legacy license entry; use a fresh STREAM_VMIC_BUILD_DIR.'; exit 1;
    }
  rm "$VMIC_BUNDLE/Contents/LICENSE-Apple.txt"
fi
xcrun clang -std=c11 -O2 -isysroot "$VMIC_SDK" -framework CoreAudio -framework CoreFoundation \
  prototypes/VirtualMicrophone/Probe.c -o "$VMIC_BUILD_DIR/installed-device-probe"
xcrun lipo -archs "$VMIC_BUNDLE/Contents/MacOS/StreamVirtualMicrophone"
print "Built $VMIC_BUNDLE. Not signed, installed, activated or qualified."
