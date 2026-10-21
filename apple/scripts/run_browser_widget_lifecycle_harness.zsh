#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly LIFECYCLE_DIR="${BROWSER_LIFECYCLE_DIR:-build/browser-widget-lifecycle-validation}"
readonly LIFECYCLE_BUILD_PATH="${BROWSER_LIFECYCLE_BUILD_PATH:-$LIFECYCLE_DIR/derived}"
mkdir -p "$LIFECYCLE_DIR"
ruby -ryaml -rjson - "$LIFECYCLE_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='BrowserWidgetLifecycleValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path']=ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(package['path'])) : File.join(root,package['path'])
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['dependencies']&.reject!{|dependency| dependency['target'] && !spec['targets'].key?(dependency['target'])}
  target['sources'].map!{|source| source.is_a?(String) ? File.join(root,source) : source.merge('path'=>File.join(root,source['path']))}
  target.delete('entitlements'); target.delete('info')
end
target=spec['targets'].delete('StreamMac'); target['type']='tool'
require File.join(root,'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'],target,root,folder)
# Drive the actual controller reconciliation without allocating camera/mic,
# compositor or unrelated screen/app capture. Record exact capture requests.
controller=File.read(File.join(root,'StreamMac/StreamController.swift')).gsub('UserDefaults.standard','GuestFixtureDefaults.value')
needle='    func startPreview() {'
abort 'Browser lifecycle preview boundary changed' unless controller.scan(needle).length==1
controller.sub!(needle,"    func startPreview() {\n        isPipelineRunning = true; previewState = .active\n        reconcileSourceDemand()\n        return")
needle='            let prepared = await audioEngine.prepareClosedApplicationMixer('
abort 'Browser operator mixer preparation boundary changed' unless controller.scan(needle).length==1
controller.sub!(needle,"            await BrowserOperatorSeedGate.pause()\n"+needle)
controller_path=File.join(folder,'fixtures/BrowserLifecycleController.swift')
File.write(controller_path,controller)
target['sources'].reject!{|entry| entry.is_a?(String) && File.basename(entry)=='StreamController.swift'}
target['sources'][0]['excludes'] << 'StreamController.swift'
target['sources'] << controller_path
pool=File.read(File.join(root,'StreamMac/CaptureSourcePool.swift'))
start=pool.index('    private func start(_ key: CaptureSourceKey, settings: StreamSettings)')
finish=pool.index('    private func stop(_ key:', start)
abort 'Browser lifecycle source-start boundary changed' unless start && finish
body=pool[start...finish]
pattern=/        case \.screen\(let payload\):.*?        case \.syphon\(let payload\):/m
abort 'Browser lifecycle screen-start boundary changed' unless body.scan(pattern).length==1
body.sub!(pattern,"        case .screen(let payload):\n            BrowserLifecycleCaptureReceipts.screenPrivacy.append(payload.effectivePrivacy(defaults: settings))\n        case .syphon(let payload):")
pool[start...finish]=body
needle='        let host = BrowserOverlayHost(configuration: configuration, storeKey: storeKey)'
abort 'Browser lifecycle HTML boundary changed' unless pool.scan(needle).length==1
pool.sub!(needle,'        let host = BrowserOverlayHost(configuration: configuration, storeKey: storeKey, helperHTMLForQualification: "<body>Silent owned lifecycle fixture</body>")')
needle="                               settings: StreamSettings) {\n        sourceErrors[key] = nil\n        let capture = appAudioCapture(for: key)"
abort 'Browser lifecycle app-audio boundary changed' unless pool.scan(needle).length==1
pool.sub!(needle,"                               settings: StreamSettings) {\n        BrowserLifecycleCaptureReceipts.appExclusions.append(systemMixExclusions(in: requested, settings: settings))\n        return ()\n        sourceErrors[key] = nil\n        let capture = appAudioCapture(for: key)")
pool_path=File.join(folder,'fixtures/BrowserLifecycleCapturePool.swift')
File.write(pool_path,pool)
target['sources'][0]['excludes'] << 'CaptureSourcePool.swift'
target['sources'] << pool_path
target['sources'] << File.join(root,'scripts/browser_widget_lifecycle_harness.swift')
target['sources'] << File.join(root,'scripts/browser_helper_lifecycle_checks.swift')
spec['targets']['BrowserWidgetLifecycleHarness']=target
spec['schemes']['BrowserWidgetLifecycleHarness']={'build'=>{'targets'=>{'BrowserWidgetLifecycleHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$LIFECYCLE_DIR/project.json" --project "$LIFECYCLE_DIR"
xcodebuild -resolvePackageDependencies -project "$LIFECYCLE_DIR/BrowserWidgetLifecycleValidation.xcodeproj" \
  -scheme BrowserWidgetLifecycleHarness -derivedDataPath "$LIFECYCLE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$LIFECYCLE_BUILD_PATH"
xcodebuild -project "$LIFECYCLE_DIR/BrowserWidgetLifecycleValidation.xcodeproj" \
  -scheme BrowserWidgetLifecycleHarness -destination 'platform=macOS' -jobs "${STREAM_XCODE_JOBS:-4}" \
  -derivedDataPath "$LIFECYCLE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly HELPER_APP="$LIFECYCLE_DIR/StreamBrowserAudioHelper.app"
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
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Hold only the Stop-ACK continuation after the real public WebKit
# suspension completion. Actual helper retirement/page identity stays real.
python3 - "$LIFECYCLE_DIR" <<'PYHELPER'
from pathlib import Path
import sys
folder=Path(sys.argv[1])
source=Path('BrowserAudioHelper/BrowserAudioHelperMain.swift').read_text()
needle='\n        widget.view.setAllMediaPlaybackSuspended(true) { [weak self] in\n'
assert source.count(needle)==1, 'Retirement completion fixture boundary changed'
source=source.replace(needle, needle+'''            Task { @MainActor in
                let gate = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("retirement-gate")
                if FileManager.default.fileExists(atPath: gate.path) {
                    try? Data().write(to: gate.appendingPathExtension("entered"))
                    let deadline = ProcessInfo.processInfo.systemUptime + 3
                    while !FileManager.default.fileExists(atPath: gate.appendingPathExtension("release").path) {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { NSApplication.shared.terminate(nil); return }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
''',1)
needle='            for completion in completions { completion() }\n'
assert source.count(needle)==1, 'Retirement ACK fixture boundary changed'
source=source.replace(needle,needle+'            }\n',1)
(folder/'BrowserLifecycleHelper.swift').write_text(source)
for suffix in ['', '.entered', '.release']:
    (folder/('retirement-gate'+suffix)).unlink(missing_ok=True)
PYHELPER
swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -O \
  StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetAudioSocket.swift StreamMac/BrowserWidgetVisualProtocol.swift StreamMac/BrowserWidgetRasterizer.swift "$LIFECYCLE_DIR/BrowserLifecycleHelper.swift" \
  -o "$HELPER_APP/Contents/MacOS/StreamBrowserAudioHelper"
swiftc -swift-version 6 scripts/studio_accessibility_client.swift -o "$LIFECYCLE_DIR/BrowserOperatorAXClient"
export STREAM_ACCESSIBILITY_CLIENT="${LIFECYCLE_DIR:A}/BrowserOperatorAXClient"
export BROWSER_LIFECYCLE_COMPLETION="${LIFECYCLE_DIR:A}/completed"
rm -f "$BROWSER_LIFECYCLE_COMPLETION"
# Owned LS app + exact-PID private IPC only. No capture, install or codesign
# command; Swift's normal executable link behavior is unchanged.
env DYLD_FRAMEWORK_PATH="${LIFECYCLE_BUILD_PATH:A}/Build/Products/Debug" \
  python3 - "${LIFECYCLE_BUILD_PATH:A}/Build/Products/Debug/BrowserWidgetLifecycleHarness" "${HELPER_APP:A}" <<'PYRUN'
import os,pathlib,subprocess,sys
try:
    result=subprocess.run(sys.argv[1:],timeout=90)
    if result.returncode==0 and not pathlib.Path(os.environ["BROWSER_LIFECYCLE_COMPLETION"]).exists():
        print("FAIL: fixture exited before completing the operator proof",flush=True)
        raise SystemExit(1)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned browser lifecycle fixture exceeded90seconds',flush=True)
    raise SystemExit(1)
PYRUN
