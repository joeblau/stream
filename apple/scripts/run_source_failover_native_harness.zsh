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
  source.sub(seam, "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart") +
    "\nextension MacAudioInput { var fixturePermissionAvailable: Bool { permissionAvailable } }\n"
end
fixture_replace(target, root, folder, 'ProviderAccountSession.swift') do |source|
  seam = 'transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network'
  abort 'Provider transport fixture boundary changed' unless source.include?(seam)
  source.sub(seam, 'transport: @escaping ProviderTokenVault.Transport = { _ in throw ProviderFailure(.unavailable) }')
end
fixture_replace(target, root, folder, 'PermissionsManager.swift') do |source|
  replacements = {
    /    func refresh\(\) \{.*?\n    \}/m => '    func refresh() { statuses = [.camera: .denied, .microphone: .denied, .screenCapture: .granted] }',
    /    func probeScreenAccess\(\) async \{.*?\n    \}/m => '    func probeScreenAccess() async { refresh() }',
    /    func request\(_ kind: Kind\) async -> Status \{.*?\n    \}/m => '    func request(_ kind: Kind) async -> Status { .denied }',
    /    func openSystemSettings\(for kind: Kind\) \{.*?\n    \}/m => '    func openSystemSettings(for kind: Kind) {}'
  }
  replacements.each do |seam, replacement|
    abort 'Permission fixture boundary changed' unless source.match?(seam)
    source.sub!(seam, replacement)
  end
  source + "\nextension PermissionsManager { func fixtureSet(_ kind: Kind, _ value: Status) { statuses[kind] = value } }\n"
end
# Separate probe type runs the exact shipping decision logic against controlled
# OS results. No TCC/SCShareableContent request reaches the host.
probe = File.read(File.join(root, 'StreamMac/PermissionsManager.swift'))
probe.gsub!('PermissionsManager', 'PermissionsProbeValidationManager')
probe.gsub!('CGPreflightScreenCaptureAccess()', 'OwnedPermissionProbe.preflight')
probe.gsub!('SCShareableContent.current', 'OwnedPermissionProbe.discover()')
probe.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
probe.gsub!('AVCaptureDevice.authorizationStatus(for: .video)', 'AVAuthorizationStatus.denied')
probe.gsub!('AVCaptureDevice.authorizationStatus(for: .audio)', 'AVAuthorizationStatus.denied')
probe_copy = File.join(folder, 'fixtures/PermissionsProbeValidationManager.swift')
File.write(probe_copy, probe); target['sources'] << probe_copy
['ScreenSourceCapture.swift', 'AppAudioCapture.swift'].each do |name|
  fixture_replace(target, root, folder, name) do |source|
    abort 'Capture discovery boundary changed' unless source.include?('SCShareableContent.current')
    source.gsub('SCShareableContent.current', 'OwnedCaptureDiscovery.current()')
  end
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
    func failoverFixturePermission(_ kind: PermissionsManager.Kind, _ status: PermissionsManager.Status) { permissions.fixtureSet(kind, status) }
    func failoverFixtureMicSample(_ sample: CMSampleBuffer) {
        let callback = audio.onMicSampleOffMain, boxed = OwnedPermissionAudioSample(sample)
        OwnedPermissionAudioQueue.value.async { callback?(boxed.value) }
    }
    func failoverFixtureAudioAllowed(_ channel: AudioChannelID) -> Bool { audioEngine.captureRouteIsAllowed(channel) }
    var failoverFixtureMicPermissionAvailable: Bool { audio.fixturePermissionAvailable }
    var failoverFixtureScreenStatus: PermissionsManager.Status? { lastPermissionStatuses[.screenCapture] }
    func failoverFixtureHoldMicRestore(_ barrier: OwnedPermissionResetBarrier) async {
        await audioEngine.addChannel(.microphone(deviceUID: nil), resetInsert: { barrier.reset() }, insert: { $0 })
    }
}
SWIFT
end
# The optional path-recovery case substitutes only NWPathMonitor delivery.
# Sockets/publishers/reconnect/backoff remain real and all endpoints are owned
# loopback. Read-only observations let the test await the actual callback.
rtmp_path = File.join(root, 'StreamBroadcast/RTMPPublisher.swift')
rtmp = File.read(rtmp_path)
abort 'RTMP monitor fixture boundary changed' unless rtmp.include?('for await path in NWPathMonitor()') && rtmp.include?('self?.handlePathUpdate(NetworkPathSnapshot(path))')
rtmp.sub!('for await path in NWPathMonitor()', 'for await path in OwnedPublisherPathFeed.updates.stream')
rtmp.sub!('self?.handlePathUpdate(NetworkPathSnapshot(path))', 'self?.handlePathUpdate(path)')
rtmp += <<'SWIFT'

extension RTMPPublisher {
    var pathFixtureCurrent: NetworkPathSnapshot? { currentPath }
    var pathFixtureDetached: Bool { !streamAttached }
    var pathFixtureRecovering: Bool { recoveryInProgress }
}
SWIFT
rtmp_copy = File.join(folder, 'fixtures/RTMPPublisher.swift')
File.write(rtmp_copy, rtmp)
abort 'RTMP source entry changed' unless target['sources'].include?(rtmp_path)
target['sources'][target['sources'].index(rtmp_path)] = rtmp_copy
support = File.read(File.join(root, 'scripts/shared_encoder_harness.swift'))
abort 'Shared encoder support boundary changed' unless support.include?('@main @MainActor struct SharedEncoderHarness')
support.sub!('@main @MainActor struct SharedEncoderHarness', '@MainActor struct SharedEncoderHarness')
support_copy = File.join(folder, 'fixtures/SharedEncoderNativeSupport.swift')
File.write(support_copy, support)
target['sources'] << support_copy
target['sources'] += ['source_failover_native_harness.swift', 'publisher_path_supervision_harness.swift', 'permission_resilience_harness.swift', 'program_recording_fixtures.swift'].map { |name| File.join(root, 'scripts', name) }
spec['targets']['SourceFailoverNativeHarness'] = target
spec['schemes']['SourceFailoverNativeHarness'] = {'build' => {'targets' => {'SourceFailoverNativeHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$FAILOVER_NATIVE_DIR/project.json" --project "$FAILOVER_NATIVE_DIR"
xcodebuild -resolvePackageDependencies -project "$FAILOVER_NATIVE_DIR/SourceFailoverNativeValidation.xcodeproj" \
  -scheme SourceFailoverNativeHarness -derivedDataPath "$FAILOVER_NATIVE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$FAILOVER_NATIVE_BUILD_PATH"
xcodebuild -project "$FAILOVER_NATIVE_DIR/SourceFailoverNativeValidation.xcodeproj" -scheme SourceFailoverNativeHarness \
  -destination 'platform=macOS' -derivedDataPath "$FAILOVER_NATIVE_BUILD_PATH" -jobs 2 CODE_SIGNING_ALLOWED=NO build
FAILOVER_NATIVE_PRODUCTS="${FAILOVER_NATIVE_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$FAILOVER_NATIVE_PRODUCTS" python3 - "$FAILOVER_NATIVE_PRODUCTS/SourceFailoverNativeHarness" "${FAILOVER_NATIVE_DIR:A}" "$@" <<'PY'
import pathlib,subprocess,sys,uuid
root=pathlib.Path(sys.argv[2])/('artifacts-'+str(uuid.uuid4()));root.mkdir()
try:
 result=subprocess.run([sys.argv[1],str(root)]+sys.argv[3:],timeout=60)
 if result.returncode:raise SystemExit(result.returncode)
 if '--external-decoder' in sys.argv[3:]:
  subprocess.run([sys.executable,'scripts/decode_source_failover_artifacts.py',str(root)],timeout=60,check=True)
except subprocess.TimeoutExpired:
 print('FAIL: source failover native harness exceeded60s; owned artifacts retained at '+str(root),flush=True)
 raise SystemExit(1)
PY
