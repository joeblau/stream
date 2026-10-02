#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${STREAM_SIGNING_IDENTITY:?Set STREAM_SIGNING_IDENTITY to a Developer ID Application identity}"
readonly RELEASE_NOTARIZE="${STREAM_NOTARIZE:-1}"
[[ "$RELEASE_NOTARIZE" == 0 || "$RELEASE_NOTARIZE" == 1 ]] || { print -u2 "STREAM_NOTARIZE must be 0 or 1"; exit 1; }
if [[ "$RELEASE_NOTARIZE" == 1 ]]; then
  : "${STREAM_NOTARY_PROFILE:?Set STREAM_NOTARY_PROFILE to an existing notarytool keychain profile}"
fi
readonly RELEASE_DIR="${STREAM_RELEASE_DIR:-$PWD/build/release}"
mkdir -p "$RELEASE_DIR"
xcodegen generate
readonly RELEASE_ARCH="$(uname -m)"
xcodebuild -resolvePackageDependencies -project Stream.xcodeproj -scheme StreamMac \
  -derivedDataPath "$RELEASE_DIR/derived"
python3 scripts/repair_desktop_transport_archives.py "$RELEASE_DIR/derived"
xcodebuild archive -project Stream.xcodeproj -scheme StreamMac \
  -destination 'generic/platform=macOS' -archivePath "$RELEASE_DIR/StreamMac.xcarchive" \
  -derivedDataPath "$RELEASE_DIR/derived" ARCHS="$RELEASE_ARCH" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$STREAM_SIGNING_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp
python3 - "$RELEASE_DIR/ExportOptions.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'manual'}, file)
PY
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/StreamMac.xcarchive" \
  -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" -exportPath "$RELEASE_DIR/export"
readonly RELEASE_APP="$RELEASE_DIR/export/StreamMac.app"
python3 scripts/validate_desktop_distribution.py "$RELEASE_APP"
codesign --verify --deep --strict --verbose=2 "$RELEASE_APP"
ditto -c -k --keepParent "$RELEASE_APP" "$RELEASE_DIR/StreamMac.zip"
if [[ "$RELEASE_NOTARIZE" == 0 ]]; then
  print "Developer ID signed artifact (not notarized): $RELEASE_DIR/StreamMac.zip"
  exit 0
fi
xcrun notarytool submit "$RELEASE_DIR/StreamMac.zip" --keychain-profile "$STREAM_NOTARY_PROFILE" --wait
xcrun stapler staple "$RELEASE_APP"
spctl --assess --type execute --verbose=2 "$RELEASE_APP"
ditto -c -k --keepParent "$RELEASE_APP" "$RELEASE_DIR/StreamMac.zip"
print "Notarized artifact: $RELEASE_DIR/StreamMac.zip"
