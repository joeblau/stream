#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CAPTURE_DIR="${BROWSER_CAPTURE_AUTHORITY_DIR:-build/browser-capture-authority}"
readonly CAPTURE_DERIVED="${BROWSER_CAPTURE_AUTHORITY_DERIVED:-$CAPTURE_DIR/derived}"
mkdir -p "$CAPTURE_DIR"
ruby -ryaml -rjson - "$CAPTURE_DIR" <<'RUBY'
root=Dir.pwd;folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml');spec['name']='BrowserCaptureAuthority'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path']=ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(package['path'])) : File.join(root,package['path'])
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)};spec['schemes']={}
spec['targets'].each_value do |target|
  target['dependencies']&.reject!{|dependency| dependency['target'] && !spec['targets'].key?(dependency['target'])}
  target['sources'].map!{|source| source.is_a?(String) ? File.join(root,source) : source.merge('path'=>File.join(root,source['path']))}
  target.delete('entitlements');target.delete('info')
end
target=spec['targets'].delete('StreamMac');target['type']='tool'
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root,'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'],target,root,folder)
target['sources'] << File.join(root,'scripts/browser_capture_authority_harness.swift')
spec['targets']['BrowserCaptureAuthority']=target
spec['schemes']['BrowserCaptureAuthority']={'build'=>{'targets'=>{'BrowserCaptureAuthority'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$CAPTURE_DIR/project.json" --project "$CAPTURE_DIR"
xcodebuild -resolvePackageDependencies -project "$CAPTURE_DIR/BrowserCaptureAuthority.xcodeproj" -scheme BrowserCaptureAuthority -derivedDataPath "$CAPTURE_DERIVED"
python3 scripts/repair_desktop_transport_archives.py "$CAPTURE_DERIVED"
xcodebuild -project "$CAPTURE_DIR/BrowserCaptureAuthority.xcodeproj" -scheme BrowserCaptureAuthority -configuration Debug -destination 'platform=macOS' -derivedDataPath "$CAPTURE_DERIVED" -jobs 2 CODE_SIGNING_ALLOWED=NO build
if [[ "${BROWSER_CAPTURE_AUTHORITY_BUILD_ONLY:-0}" == 1 ]]; then
  print 'Built the actual capture owner/mixer; no capture or helper qualification ran.'
  exit 0
fi
typeset -a harness_args
harness_args=("$@")
if [[ "${1:-all}" == ipc ]]; then
  readonly HELPER_APP="${CAPTURE_DIR:A}/StreamBrowserAudioHelper.app"
  mkdir -p "$HELPER_APP/Contents/MacOS"
  cat > "$HELPER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.joeblau.StreamBrowserAudioHelper</string>
<key>CFBundleName</key><string>StreamBrowserAudioHelper</string>
<key>CFBundleExecutable</key><string>StreamBrowserAudioHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
  # Exact shipping helper code. Ad hoc signing does not establish distribution
  # provenance/sandbox qualification; this owned prototype uses existing private IPC.
  swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -O \
    StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetAudioSocket.swift \
    StreamMac/BrowserWidgetVisualProtocol.swift StreamMac/BrowserWidgetRasterizer.swift \
    BrowserAudioHelper/BrowserAudioHelperMain.swift -o "$HELPER_APP/Contents/MacOS/StreamBrowserAudioHelper"
  codesign --force --sign - "$HELPER_APP"
  harness_args=(ipc "$HELPER_APP")
fi
env DYLD_FRAMEWORK_PATH="${CAPTURE_DERIVED:A}/Build/Products/Debug" \
  python3 - "${CAPTURE_DERIVED:A}/Build/Products/Debug/BrowserCaptureAuthority" "${harness_args[@]}" <<'PYRUN'
import subprocess,sys
try:
    result=subprocess.run(sys.argv[1:],timeout=45)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    # subprocess.run kills only its exact owned child. Closing its sockets
    # causes the owned helper's shipping EOF retirement path to terminate.
    print('FAIL: owned capture authority fixture exceeded45seconds',flush=True)
    raise SystemExit(1)
PYRUN
