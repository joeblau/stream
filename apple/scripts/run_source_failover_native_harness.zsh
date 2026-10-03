#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
FAILOVER_NATIVE_DIR="${FAILOVER_NATIVE_DIR:-build/source-failover-native-validation}"
FAILOVER_NATIVE_BUILD_PATH="${FAILOVER_NATIVE_BUILD_PATH:-${FAILOVER_NATIVE_DIR}/derived}"
mkdir -p "$FAILOVER_NATIVE_DIR"
ruby -ryaml -rjson - "$FAILOVER_NATIVE_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'SourceFailoverNativeValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  target.delete('entitlements'); target.delete('info')
end
target = spec['targets'].delete('StreamMac')
target['type'] = 'tool'
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
File.write(File.join(folder, 'fixtures/GuestFixtureEnvironment.swift'), <<'SWIFT')
import Foundation
enum GuestFixtureDefaults {
    static let name = "com.joeblau.Stream.fixture.failover.\(UUID().uuidString)"
    nonisolated(unsafe) static let value: UserDefaults = {
        let value = UserDefaults(suiteName: name)!
        atexit { GuestFixtureDefaults.value.removePersistentDomain(forName: GuestFixtureDefaults.name) }
        return value
    }()
}
enum GuestFixtureStorage {
    static let artifactRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static let machineDirectory = artifactRoot.appendingPathComponent("Studio", isDirectory: true)
    static let recordingsDirectory = artifactRoot.appendingPathComponent("Recordings", isDirectory: true)
}
SWIFT
def fixture_replace(target, root, folder, name)
  source = File.read(File.join(root, 'StreamMac', name))
  source.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
  source.gsub!(/UserDefaults\s*=\s*\.standard/, 'UserDefaults = GuestFixtureDefaults.value')
  copy = File.join(folder, 'fixtures/Mac', name)
  FileUtils.mkdir_p(File.dirname(copy)); File.write(copy, yield(source))
  unless target['sources'][0]['excludes'].include?(name)
    target['sources'][0]['excludes'] << name; target['sources'] << copy
  end
end
fixture_replace(target, root, folder, 'CaptureSourcePool.swift') do |source|
  producer = /    private func start\(_ key: CaptureSourceKey, settings: StreamSettings\) \{.*?\n    \}\n\n(?=    private func stop)/m
  abort 'Owned capture producer boundary changed' unless source.match?(producer)
  source.sub!(producer, <<'SWIFT')
    private func start(_ key: CaptureSourceKey, settings: StreamSettings) {
        guard let holder = FailoverOwnedSources.start(key) else {
            preconditionFailure("Refusing an unowned capture request in source failover fixture")
        }
        requested.insert(key)
        screenFrames[key] = holder
        activeSources.insert(key)
        publishFrameHolders()
    }

SWIFT
  seam = '    private func stop(_ key: CaptureSourceKey) {'
  abort 'Owned capture stop boundary changed' unless source.include?(seam)
  source.sub(seam, "#{seam}\n        FailoverOwnedSources.stop(key)")
end
fixture_replace(target, root, folder, 'MacAudioInput.swift') do |source|
  seam = /    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
  abort 'Microphone fixture boundary changed' unless source.match?(seam)
  source.sub(seam, "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
end
fixture_replace(target, root, folder, 'ProviderAccountSession.swift') do |source|
  seam = 'transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network'
  abort 'Provider transport fixture boundary changed' unless source.include?(seam)
  source.sub(seam, 'transport: @escaping ProviderTokenVault.Transport = { _ in throw ProviderFailure(.unavailable) }')
end
fixture_replace(target, root, folder, 'PermissionsManager.swift') do |source|
  replacements = {
    /    func refresh\(\) \{.*?\n    \}/m => '    func refresh() { statuses = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, .denied) }) }',
    /    func probeScreenAccess\(\) async \{.*?\n    \}/m => '    func probeScreenAccess() async { refresh() }',
    /    func request\(_ kind: Kind\) async -> Status \{.*?\n    \}/m => '    func request(_ kind: Kind) async -> Status { .denied }',
    /    func openSystemSettings\(for kind: Kind\) \{.*?\n    \}/m => '    func openSystemSettings(for kind: Kind) {}'
  }
  replacements.each do |seam, replacement|
    abort 'Permission fixture boundary changed' unless source.match?(seam)
    source.sub!(seam, replacement)
  end
  source
end
fixture_replace(target, root, folder, 'RecordingController.swift') do |source|
  abort 'Recording folder fixture boundary changed' unless source.include?('defaultDirectory: URL? = nil')
  source.sub('defaultDirectory: URL? = nil', 'defaultDirectory: URL? = GuestFixtureStorage.recordingsDirectory')
end
# Read-only same-file observations. Health folding, policy reconciliation,
# scene switches, clock, renderer, recording and lifecycle remain shipping.
fixture_replace(target, root, folder, 'ResilientSourceFrames.swift') do |source|
  source + <<'SWIFT'

extension ResilientSourceFrames {
    var failoverFixtureRetainedCount: Int { cache.retainedCount }
}
SWIFT
end
fixture_replace(target, root, folder, 'StreamController.swift') do |source|
  source + <<'SWIFT'

extension StreamController {
    var failoverFixtureRetainedFrames: Int { resilientFrames.failoverFixtureRetainedCount }
    var failoverFixturePipelineRunning: Bool { isPipelineRunning }
}
SWIFT
end
target['sources'] += ['source_failover_native_harness.swift', 'program_recording_fixtures.swift'].map { |name| File.join(root, 'scripts', name) }
spec['targets']['SourceFailoverNativeHarness'] = target
spec['schemes']['SourceFailoverNativeHarness'] = {'build' => {'targets' => {'SourceFailoverNativeHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$FAILOVER_NATIVE_DIR/project.json" --project "$FAILOVER_NATIVE_DIR"
xcodebuild -resolvePackageDependencies -project "$FAILOVER_NATIVE_DIR/SourceFailoverNativeValidation.xcodeproj" \
  -scheme SourceFailoverNativeHarness -derivedDataPath "$FAILOVER_NATIVE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$FAILOVER_NATIVE_BUILD_PATH"
xcodebuild -project "$FAILOVER_NATIVE_DIR/SourceFailoverNativeValidation.xcodeproj" -scheme SourceFailoverNativeHarness \
  -destination 'platform=macOS' -derivedDataPath "$FAILOVER_NATIVE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
FAILOVER_NATIVE_PRODUCTS="${FAILOVER_NATIVE_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$FAILOVER_NATIVE_PRODUCTS" python3 - "$FAILOVER_NATIVE_PRODUCTS/SourceFailoverNativeHarness" "${FAILOVER_NATIVE_DIR:A}" <<'PY'
import pathlib,subprocess,sys,uuid
root=pathlib.Path(sys.argv[2])/('artifacts-'+str(uuid.uuid4()));root.mkdir()
try:raise SystemExit(subprocess.run([sys.argv[1],str(root)],timeout=60).returncode)
except subprocess.TimeoutExpired:
 print('FAIL: source failover native harness exceeded60s; owned artifacts retained at '+str(root),flush=True)
 raise SystemExit(1)
PY
