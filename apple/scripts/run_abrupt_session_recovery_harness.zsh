#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ABRUPT_RECOVERY_DIR="${ABRUPT_RECOVERY_DIR:-build/abrupt-session-recovery-validation}"
ABRUPT_RECOVERY_BUILD_PATH="${ABRUPT_RECOVERY_BUILD_PATH:-${ABRUPT_RECOVERY_DIR}/derived}"
mkdir -p "$ABRUPT_RECOVERY_DIR"
ruby -ryaml -rjson - "$ABRUPT_RECOVERY_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'AbruptSessionRecoveryValidation'
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
target['settings'] ||= {}
target['settings']['base'] ||= {}
# Shared aliases (notably Stream/RestreamChat.swift) are outside the Mac copy
# loop. Their shipping validation guard must also disable secret reads/writes,
# legacy credential migration and default provider network transport.
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
# Keep the child and fresh parent startup on the same exclusively owned store.
# Do not remove these bytes at process exit, especially when media is unreadable.
File.write(File.join(folder, 'fixtures/GuestFixtureEnvironment.swift'), <<'SWIFT')
import Foundation
enum GuestFixtureDefaults {
    static let name = "com.joeblau.Stream.fixture.abrupt.\(ProcessInfo.processInfo.environment["STREAM_ABRUPT_FIXTURE_ID"]!)"
    nonisolated(unsafe) static let value = UserDefaults(suiteName: name)!
}
enum GuestFixtureStorage {
    static let artifactRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STREAM_ABRUPT_FIXTURE_ROOT"]!, isDirectory: true)
    static let machineDirectory = artifactRoot.appendingPathComponent("Studio", isDirectory: true)
    static let recordingsDirectory = artifactRoot.appendingPathComponent("Recordings", isDirectory: true)
}
SWIFT
def fixture_replace(target, root, folder, relative)
  original = File.join(root, 'StreamMac', relative)
  copy = File.join(folder, 'fixtures/Mac', relative)
  source = File.read(original)
  source.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
  source.gsub!(/UserDefaults\s*=\s*\.standard/, 'UserDefaults = GuestFixtureDefaults.value')
  replacement = yield source
  FileUtils.mkdir_p(File.dirname(copy)); File.write(copy, replacement)
  unless target['sources'][0]['excludes'].include?(relative)
    target['sources'][0]['excludes'] << relative
    target['sources'] << copy
  end
end
fixture_replace(target, root, folder, 'RecordingController.swift') do |source|
  abort 'Recording folder fixture boundary changed' unless source.include?('defaultDirectory: URL? = nil')
  source.sub('defaultDirectory: URL? = nil', 'defaultDirectory: URL? = GuestFixtureStorage.recordingsDirectory')
end
fixture_replace(target, root, folder, 'ProviderAccountSession.swift') do |source|
  seam = 'transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network'
  abort 'Provider transport fixture boundary changed' unless source.include?(seam)
  source.sub(seam, 'transport: @escaping ProviderTokenVault.Transport = { _ in throw ProviderFailure(.unavailable) }')
end
fixture_replace(target, root, folder, 'MacAudioInput.swift') do |source|
  seam = /    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
  abort 'Microphone fixture boundary changed' unless source.match?(seam)
  source.sub(seam, "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
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
# Read-only observations of the actual public AVPlayer clock, not substitutes
# for asynchronous seek/load or paused recovery behavior. Private storage is
# exposed only by same-file extensions in these generated tool copies.
fixture_replace(target, root, folder, 'MediaSourcePlayback.swift') do |source|
  source + <<'SWIFT'

extension MediaSourcePlayback {
    func abruptFixturePlayerState() -> (seconds: Double, rate: Float, muted: Bool)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let player else { return nil }
        return (player.currentTime().seconds, player.rate, player.isMuted)
    }
}
SWIFT
end
fixture_replace(target, root, folder, 'CaptureSourcePool.swift') do |source|
  source + <<'SWIFT'

extension CaptureSourcePool {
    func abruptFixturePlayerState(for id: SourceDefinitionID) -> (seconds: Double, rate: Float, muted: Bool)? {
        mediaPlaybacks[.media(id)]?.abruptFixturePlayerState()
    }
}
SWIFT
end
target['sources'] << File.join(root, 'scripts/abrupt_session_recovery_harness.swift')
target['sources'] << File.join(root, 'scripts/program_recording_fixtures.swift')
spec['targets']['AbruptSessionRecoveryHarness'] = target
spec['schemes']['AbruptSessionRecoveryHarness'] = { 'build' => { 'targets' => { 'AbruptSessionRecoveryHarness' => 'all' } } }
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$ABRUPT_RECOVERY_DIR/project.json" --project "$ABRUPT_RECOVERY_DIR"
xcodebuild -resolvePackageDependencies -project "$ABRUPT_RECOVERY_DIR/AbruptSessionRecoveryValidation.xcodeproj" \
  -scheme AbruptSessionRecoveryHarness -derivedDataPath "$ABRUPT_RECOVERY_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$ABRUPT_RECOVERY_BUILD_PATH"
xcodebuild -project "$ABRUPT_RECOVERY_DIR/AbruptSessionRecoveryValidation.xcodeproj" -scheme AbruptSessionRecoveryHarness \
  -destination 'platform=macOS' -derivedDataPath "$ABRUPT_RECOVERY_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
ABRUPT_PRODUCTS="${ABRUPT_RECOVERY_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$ABRUPT_PRODUCTS" python3 - "$ABRUPT_PRODUCTS/AbruptSessionRecoveryHarness" "${ABRUPT_RECOVERY_DIR:A}" <<'PY'
import os,pathlib,subprocess,sys,uuid
identity=str(uuid.uuid4())
root=pathlib.Path(sys.argv[2])/('artifacts-'+identity)
root.mkdir()
env=os.environ.copy()
env['STREAM_ABRUPT_FIXTURE_ROOT']=str(root)
env['STREAM_ABRUPT_FIXTURE_ID']=identity
try:
    raise SystemExit(subprocess.run([sys.argv[1]],env=env,timeout=60).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: abrupt recovery fixture exceeded 60 seconds; owned artifacts retained at '+str(root),flush=True)
    raise SystemExit(1)
PY
