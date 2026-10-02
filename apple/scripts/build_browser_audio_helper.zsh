#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly HELPER_BUILD_DIR="${BROWSER_AUDIO_HELPER_BUILD_DIR:-build/browser-audio-helper}"
mkdir -p "$HELPER_BUILD_DIR"
for role in StreamBrowserAudioHelper StreamBrowserAudioNoiseFixture; do
  BUNDLE_PATH="$HELPER_BUILD_DIR/$role.app"
  mkdir -p "$BUNDLE_PATH/Contents/MacOS"
  cat > "$BUNDLE_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.joeblau.$role</string>
<key>CFBundleName</key><string>$role</string>
<key>CFBundleExecutable</key><string>$role</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -O \
    StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetAudioSocket.swift StreamMac/BrowserWidgetVisualProtocol.swift BrowserAudioHelper/BrowserAudioHelperMain.swift \
    -o "$BUNDLE_PATH/Contents/MacOS/$role"
  codesign --force --sign - --identifier "com.joeblau.$role" "$BUNDLE_PATH"
done
print "Built ad hoc qualification helpers only: $HELPER_BUILD_DIR"
