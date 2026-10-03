#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
PORTABLE_NATIVE_DIR="${PORTABLE_NATIVE_DIR:-build/portable-show-native-validation}"
PORTABLE_NATIVE_BUILD_PATH="${PORTABLE_NATIVE_BUILD_PATH:-${PORTABLE_NATIVE_DIR}/derived}"
mkdir -p "$PORTABLE_NATIVE_DIR"
ruby -ryaml -rjson -rsecurerandom - "$PORTABLE_NATIVE_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'PortableShowNativeValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  target.delete('entitlements')
end
target = spec['targets'].delete('StreamMac')
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'].reject! { |source| source == File.join(folder, 'fixtures/GuestFixtureEnvironment.swift') }
target['sources'] << File.join(root, 'scripts/portable_show_native_fixture.swift')
def generated_replace(target, root, folder, name)
  source = File.read(File.join(root, 'StreamMac', name))
  source.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
  source.gsub!(/UserDefaults\s*=\s*\.standard/, 'UserDefaults = GuestFixtureDefaults.value')
  copy = File.join(folder, 'fixtures/Mac', name)
  FileUtils.mkdir_p(File.dirname(copy)); File.write(copy, yield(source))
  unless target['sources'][0]['excludes'].include?(name)
    target['sources'][0]['excludes'] << name; target['sources'] << copy
  end
end
generated_replace(target, root, folder, 'MacAudioInput.swift') do |source|
  seam = /    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
  abort 'Microphone fixture boundary changed' unless source.match?(seam)
  source.sub(seam, "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
end
generated_replace(target, root, folder, 'StreamController.swift') do |source|
  seam = '    func startPreview() {'
  abort 'Preview fixture boundary changed' unless source.include?(seam)
  source.sub(seam, "    func startPreview() {\n        PortableNativeAppDriver.previewSuppressed += 1\n        return")
end
generated_replace(target, root, folder, 'RecordingController.swift') do |source|
  abort 'Recording folder boundary changed' unless source.include?('defaultDirectory: URL? = nil')
  source.sub('defaultDirectory: URL? = nil', 'defaultDirectory: URL? = GuestFixtureStorage.recordingsDirectory')
end
generated_replace(target, root, folder, 'RecordingTerminationDelegate.swift') do |source|
  seam = '    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {'
  abort 'Termination observer boundary changed' unless source.include?(seam)
  source.sub(seam, "#{seam}\n        PortableNativeAppDriver.terminating()")
end
# Observe only the actual shipping decoder's URL. No generated handler,
# extra package security scope or replacement preview/import path.
generated_replace(target, root, folder, 'StudioPackageOpenReceiver.swift') do |source|
  seam = '        let urls = (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }'
  abort 'Shipping event URL decoder boundary changed' unless source.include?(seam)
  source.sub(seam, seam + "\n            .map { PortableNativeAppDriver.received($0); return $0 }")
end
generated_replace(target, root, folder, 'PermissionsManager.swift') do |source|
  {
    /    func refresh\(\) \{.*?\n    \}/m => '    func refresh() { statuses = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, .denied) }) }',
    /    func probeScreenAccess\(\) async \{.*?\n    \}/m => '    func probeScreenAccess() async { refresh() }',
    /    func request\(_ kind: Kind\) async -> Status \{.*?\n    \}/m => '    func request(_ kind: Kind) async -> Status { .denied }',
    /    func openSystemSettings\(for kind: Kind\) \{.*?\n    \}/m => '    func openSystemSettings(for kind: Kind) {}'
  }.each do |seam, replacement|
    abort 'Permission fixture boundary changed' unless source.match?(seam)
    source.sub!(seam, replacement)
  end
  source
end
app = File.read('StreamMac/StreamMacApp.swift')
app.sub!('@AppStorage("onboarding.hasCompletedFirstRun")', '@AppStorage("onboarding.hasCompletedFirstRun", store: GuestFixtureDefaults.value)')
entry = '.onOpenURL { workspace.previewPackage($0) }'
abort 'Shipping open-file entry changed' unless app.include?(entry)
app.sub!(entry, '.onOpenURL { PortableNativeAppDriver.received($0); workspace.previewPackage($0) }')
identity = '.id(ObjectIdentifier(workspace.runtime))'
abort 'Shipping root identity changed' unless app.include?(identity)
app.sub!(identity, ".defaultAppStorage(GuestFixtureDefaults.value)\n                .onAppear { PortableNativeAppDriver.attach(workspace) }\n                #{identity}")
app_copy = File.join(folder, 'fixtures/PortableStreamMacApp.swift')
File.write(app_copy, app)
driver = Marshal.load(Marshal.dump(target))
driver['type'] = 'tool'; driver.delete('info'); driver.delete('entitlements')
driver['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.joeblau.Stream.fixture.portable.driver.' + SecureRandom.uuid
driver['settings']['base'].delete('PROVISIONING_PROFILE_SPECIFIER')
driver['sources'] << File.join(root, 'scripts/portable_show_native_driver.swift')
target['sources'] << app_copy
target['settings']['base'].delete('PROVISIONING_PROFILE_SPECIFIER')
target['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.joeblau.Stream.fixture.portable.' + SecureRandom.uuid
target['settings']['base']['ENABLE_APP_SANDBOX'] = 'YES'
target['info']['path'] = File.join(folder, 'fixtures/PortableInfo.plist')
target['info']['properties']['CFBundleDocumentTypes'][0]['LSHandlerRank'] = 'None'
target['info']['properties']['CFBundleDocumentTypes'] << {
  'CFBundleTypeName' => 'Owned fixture repair PNG', 'CFBundleTypeRole' => 'Viewer', 'LSHandlerRank' => 'None', 'LSItemContentTypes' => ['public.png']
}
spec['targets']['PortableShowNativeFixture'] = target
spec['targets']['PortableShowNativeDriver'] = driver
spec['schemes']['PortableShowNative'] = {'build' => {'targets' => {'PortableShowNativeFixture' => 'all', 'PortableShowNativeDriver' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$PORTABLE_NATIVE_DIR/project.json" --project "$PORTABLE_NATIVE_DIR"
xcodebuild -resolvePackageDependencies -project "$PORTABLE_NATIVE_DIR/PortableShowNativeValidation.xcodeproj" \
  -scheme PortableShowNative -derivedDataPath "$PORTABLE_NATIVE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$PORTABLE_NATIVE_BUILD_PATH"
xcodebuild -project "$PORTABLE_NATIVE_DIR/PortableShowNativeValidation.xcodeproj" -scheme PortableShowNative \
  -destination 'platform=macOS' -derivedDataPath "$PORTABLE_NATIVE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
PORTABLE_PRODUCTS="${PORTABLE_NATIVE_BUILD_PATH:A}/Build/Products/Debug"
PORTABLE_APP="$PORTABLE_PRODUCTS/PortableShowNativeFixture.app"
python3 - "$PORTABLE_NATIVE_DIR" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
with (root/'sandbox.entitlements').open('wb') as f:
 plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.files.bookmarks.app-scope':True},f)
PY
if [[ -d "$PORTABLE_APP/Contents/Frameworks" ]]; then
  while IFS= read -r framework; do
    codesign --force --sign - "$framework"
  done < <(find "$PORTABLE_APP/Contents/Frameworks" -depth -name '*.framework')
fi
codesign --force --sign - --entitlements "$PORTABLE_NATIVE_DIR/sandbox.entitlements" "$PORTABLE_APP"
codesign --verify --deep --strict "$PORTABLE_APP"
codesign --display --entitlements - --xml "$PORTABLE_APP" > "$PORTABLE_NATIVE_DIR/actual-entitlements.plist"
python3 - "$PORTABLE_NATIVE_DIR" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
expected=plistlib.loads((root/'sandbox.entitlements').read_bytes())
actual=plistlib.loads((root/'actual-entitlements.plist').read_bytes())
assert actual==expected,'Actual fixture app has unexpected/missing entitlements'
print('Verified ad hoc signature and exact sandbox/user-selected/bookmark entitlements; no get-task-allow, device, network, App Group or Keychain claims',flush=True)
PY
env DYLD_FRAMEWORK_PATH="$PORTABLE_PRODUCTS" python3 - "$PORTABLE_PRODUCTS/PortableShowNativeDriver" "$PORTABLE_APP" "${PORTABLE_NATIVE_DIR:A}" <<'PY'
import pathlib,subprocess,sys,uuid
root=pathlib.Path(sys.argv[3])/('artifacts-'+str(uuid.uuid4()));root.mkdir()
try:raise SystemExit(subprocess.run([sys.argv[1],sys.argv[2],str(root)],timeout=100).returncode)
except subprocess.TimeoutExpired:
 print('FAIL: portable native driver exceeded100s; own app container/artifacts retained',flush=True)
 raise SystemExit(1)
PY
