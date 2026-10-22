#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
DECK_AUDIO_MEDIA_DIR="${DECK_AUDIO_MEDIA_DIR:-build/deck-audio-media-validation}"
DECK_AUDIO_MEDIA_BUILD_PATH="${DECK_AUDIO_MEDIA_BUILD_PATH:-${DECK_AUDIO_MEDIA_DIR}/derived}"
mkdir -p "$DECK_AUDIO_MEDIA_DIR"
ruby -ryaml -rjson - "$DECK_AUDIO_MEDIA_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
# Preserve unchanged generated source mtimes across bounded fixture repeats.
previous_sources = Dir.glob(File.join(folder, 'fixtures/**/*.swift')).to_h { |path| [path, [File.binread(path), File.mtime(path)]] }
spec = YAML.load_file('project.yml')
spec['name'] = 'DeckAudioMediaValidation'
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
# Keep generated media, project, and recordings in this fixture-owned directory.
File.write(File.join(folder, 'fixtures/GuestFixtureEnvironment.swift'), <<'SWIFT')
import Foundation
#if !STREAM_NATIVE_VALIDATION
#error("The owned internal-media resolver is restricted to generated native validation targets")
#endif
enum GuestFixtureDefaults {
    static let name = "com.joeblau.Stream.fixture.deck-audio-media.\(ProcessInfo.processInfo.environment["STREAM_DECK_AUDIO_MEDIA_FIXTURE_ID"]!)"
    nonisolated(unsafe) static let value = UserDefaults(suiteName: name)!
}
enum GuestFixtureStorage {
    static let artifactRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STREAM_DECK_AUDIO_MEDIA_FIXTURE_ROOT"]!, isDirectory: true)
    static let machineDirectory = artifactRoot.appendingPathComponent("Studio", isDirectory: true)
    static let recordingsDirectory = artifactRoot.appendingPathComponent("Recordings", isDirectory: true)
}
/// This unsigned tool owns an allowlisted set of internal WAV/MOV assets. This is ordinary file access,
/// not an external sandbox grant or a security-scoped bookmark qualification.
enum DeckFixtureOwnedMedia {
    static func validate(_ url: URL) throws -> URL {
        let root = GuestFixtureStorage.artifactRoot.standardizedFileURL.resolvingSymlinksInPath()
        let names: Set<String> = ["tone-low.wav", "tone-high.wav", "cues.wav", "video.mov"]
        guard names.contains(url.lastPathComponent) else { throw CocoaError(.fileReadNoPermission) }
        let expected = root.appendingPathComponent(url.lastPathComponent)
        guard url.isFileURL, url.lastPathComponent == expected.lastPathComponent,
              url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == root.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL.resolvingSymlinksInPath().path == expected.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }
    static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw CocoaError(.fileReadNoPermission) }
        return try validate(url)
    }
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
  boundary = <<'SWIFT'
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                fail("macOS denied access to \"\(url.lastPathComponent)\". Relink the file to restore access.")
                return
            }
            // Access is held for the rest of the session (one startAccessing
            // per load; a relink resolves the new bookmark the same way).
SWIFT
  abort 'Owned internal-media fixture boundary changed' unless source.include?(boundary)
  source.sub!(boundary, <<'SWIFT')
            // Generated validation only: exact owned internal media, no scope
            // grant claimed. Real asset load and player stay below.
            let url = try DeckFixtureOwnedMedia.resolve(bookmark)
SWIFT
  source + <<'SWIFT'

extension MediaSourcePlayback {
    func deckFixtureRetime(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? { retiming(sample, to: pts) }
    func deckFixtureObserveAudio(_ sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        os_unfair_lock_lock(&lock)
        let original = onAudioSample
        onAudioSample = { sample in sink(sample); original?(sample) }
        os_unfair_lock_unlock(&lock)
    }
    func deckFixturePlayerState() -> (seconds: Double, rate: Float, muted: Bool, clock: Int)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let player else { return nil }
        return (player.currentTime().seconds, player.rate, player.isMuted, player.timeControlStatus.rawValue)
    }
}
SWIFT
end
fixture_replace(target, root, folder, 'CaptureSourcePool.swift') do |source|
  source + <<'SWIFT'

extension CaptureSourcePool {
    func deckFixturePlayerState(for id: SourceDefinitionID) -> (seconds: Double, rate: Float, muted: Bool, clock: Int)? {
        mediaPlaybacks[.media(id)]?.deckFixturePlayerState()
    }
}
SWIFT
end
fixture_replace(target, root, folder, 'SoundboardController.swift') do |source|
  source + <<'SWIFT'

extension SoundboardController {
    func deckFixturePlayerState(_ id: SourceDefinitionID) -> (seconds: Double, rate: Float, muted: Bool, clock: Int)? {
        padEngines[id]?.first?.engine.deckFixturePlayerState()
    }
    func deckFixtureObserve(_ id: SourceDefinitionID, sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        for entry in padEngines[id] ?? [] {
            entry.engine.deckFixtureObserveAudio(sink)
        }
    }
    var deckFixtureResources: (players: Int, pumping: Bool) {
        (engineList.snapshot().count, pumpTask != nil)
    }
}
SWIFT
end
target['sources'] << File.join(root, 'scripts/deck_audio_media_harness.swift')
target['sources'] << File.join(root, 'scripts/program_recording_fixtures.swift')
spec['targets']['DeckAudioMediaHarness'] = target
spec['schemes']['DeckAudioMediaHarness'] = { 'build' => { 'targets' => { 'DeckAudioMediaHarness' => 'all' } } }
previous_sources.each do |path, (bytes, modified)|
  File.utime(File.atime(path), modified, path) if File.file?(path) && File.binread(path) == bytes
end
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$DECK_AUDIO_MEDIA_DIR/project.json" --project "$DECK_AUDIO_MEDIA_DIR"
xcodebuild -resolvePackageDependencies -project "$DECK_AUDIO_MEDIA_DIR/DeckAudioMediaValidation.xcodeproj" \
  -scheme DeckAudioMediaHarness -derivedDataPath "$DECK_AUDIO_MEDIA_BUILD_PATH" -jobs 2
python3 scripts/repair_desktop_transport_archives.py "$DECK_AUDIO_MEDIA_BUILD_PATH"
xcodebuild -project "$DECK_AUDIO_MEDIA_DIR/DeckAudioMediaValidation.xcodeproj" -scheme DeckAudioMediaHarness \
  -destination 'platform=macOS' -derivedDataPath "$DECK_AUDIO_MEDIA_BUILD_PATH" -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO build
DECK_AUDIO_MEDIA_PRODUCTS="${DECK_AUDIO_MEDIA_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$DECK_AUDIO_MEDIA_PRODUCTS" python3 - "$DECK_AUDIO_MEDIA_PRODUCTS/DeckAudioMediaHarness" "${DECK_AUDIO_MEDIA_DIR:A}" <<'PY'
import os,pathlib,subprocess,sys,uuid
identity=str(uuid.uuid4())
root=pathlib.Path(sys.argv[2])/('artifacts-'+identity)
root.mkdir()
env=os.environ.copy()
env['STREAM_DECK_AUDIO_MEDIA_FIXTURE_ROOT']=str(root)
env['STREAM_DECK_AUDIO_MEDIA_FIXTURE_ID']=identity
try:
    raise SystemExit(subprocess.run([sys.argv[1]],env=env,timeout=90).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: deck audio/media fixture exceeded 90 seconds; owned artifacts retained at '+str(root),flush=True)
    raise SystemExit(1)
PY
