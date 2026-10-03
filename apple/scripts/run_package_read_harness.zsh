#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PACKAGE_READ_DIR="build/package-read-validation"
readonly PACKAGE_READ_BUILD_PATH="${PACKAGE_READ_BUILD_PATH:-$PACKAGE_READ_DIR/derived}"
mkdir -p "$PACKAGE_READ_DIR/fixtures"
ruby -ryaml -rjson - "$PACKAGE_READ_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'PackageReadValidation'
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
target['type'] = 'tool'; target.delete('info')
target['settings']['base'].delete('PROVISIONING_PROFILE_SPECIFIER')
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
def replace_source(target, root, folder, name)
  original = File.join(root, 'StreamMac', name)
  copy = File.join(folder, 'fixtures/Mac', name)
  source = File.read(original)
  source.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
  source.gsub!(/UserDefaults\s*=\s*\.standard/, 'UserDefaults = GuestFixtureDefaults.value')
  FileUtils.mkdir_p(File.dirname(copy)); File.write(copy, yield(source))
  target['sources'][0]['excludes'] << name unless target['sources'][0]['excludes'].include?(name)
  target['sources'] << copy unless target['sources'].include?(copy)
end
replace_source(target, root, folder, 'StudioWorkspace.swift') do |source|
  first = source.index('    func previewPackage(_ url: URL) {')
  last = source.index('    func importPreviewedPackage() async {', first)
  abort 'Package preview transaction boundary changed' unless first && last
  preview = source[first...last]
  abort 'Actual preview IO boundary changed' unless preview.include?('ShowPackageIO.preview(url)')
  preview.sub!('ShowPackageIO.preview(url)', 'PackageReadProbe.preview(url)')
  abort 'Actual preview completion boundary changed' unless preview.match?(/        Task \{[^\n]*\n/)
  preview.sub!(/        Task \{([^\n]*)\n/, "        Task {\\1\n            defer { PackageReadProbe.previewReturned(url) }\n")
  source[first...last] = preview
  seam = 'ShowPackageIO.importFiles(from: preview.url, to: destination)'
  abort 'Actual import IO boundary changed' unless source.include?(seam)
  source.sub(seam, 'PackageReadProbe.importFiles(from: preview.url, to: destination)')
end
replace_source(target, root, folder, 'ProviderAccountSession.swift') do |source|
  seam = 'transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network'
  abort 'Provider fixture boundary changed' unless source.include?(seam)
  source.sub(seam, 'transport: @escaping ProviderTokenVault.Transport = { _ in throw ProviderFailure(.unavailable) }')
end
replace_source(target, root, folder, 'StudioControlPairingStore.swift') do |source|
  seam = 'credentials ?? StudioControlKeychainCredentials()'
  abort 'Local control credential fixture boundary changed' unless source.include?(seam)
  source.sub(seam, 'credentials ?? PackageReadFixtureCredentials()')
end
replace_source(target, root, folder, 'MacAudioInput.swift') do |source|
  seam = /    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
  abort 'Microphone fixture boundary changed' unless source.match?(seam)
  source.sub(seam, "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
end
replace_source(target, root, folder, 'RecordingController.swift') do |source|
  seam = 'defaultDirectory: URL? = nil'
  abort 'Recording fixture directory changed' unless source.include?(seam)
  source.sub(seam, 'defaultDirectory: URL? = GuestFixtureStorage.recordingsDirectory')
end
target['sources'] << File.join(root, 'scripts/package_read_harness.swift')
spec['targets']['PackageReadHarness'] = target
spec['schemes']['PackageReadHarness'] = {'build' => {'targets' => {'PackageReadHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$PACKAGE_READ_DIR/project.json" --project "$PACKAGE_READ_DIR"
xcodebuild -resolvePackageDependencies -project "$PACKAGE_READ_DIR/PackageReadValidation.xcodeproj" \
  -scheme PackageReadHarness -derivedDataPath "$PACKAGE_READ_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$PACKAGE_READ_BUILD_PATH"
xcodebuild -project "$PACKAGE_READ_DIR/PackageReadValidation.xcodeproj" -scheme PackageReadHarness \
  -destination 'platform=macOS' -derivedDataPath "$PACKAGE_READ_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly PACKAGE_READ_PRODUCTS="${PACKAGE_READ_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$PACKAGE_READ_PRODUCTS" python3 - "$PACKAGE_READ_PRODUCTS/PackageReadHarness" "${PACKAGE_READ_DIR:A}" <<'PY'
import pathlib,subprocess,sys,uuid
folder=pathlib.Path(sys.argv[2])/('artifacts-'+str(uuid.uuid4()));folder.mkdir()
try: raise SystemExit(subprocess.run([sys.argv[1],str(folder)],timeout=45).returncode)
except subprocess.TimeoutExpired:
 print('FAIL: owned actual package reads exceeded45 seconds',flush=True)
 raise SystemExit(1)
PY
