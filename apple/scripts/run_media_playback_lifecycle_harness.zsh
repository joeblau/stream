#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly LIFECYCLE_DIR="${MEDIA_LIFECYCLE_DIR:-build/media-lifecycle-validation}"
readonly LIFECYCLE_FRAMEWORKS="${MEDIA_LIFECYCLE_FRAMEWORKS:-build/desktop/Build/Products/Debug}"
[[ -d "$LIFECYCLE_FRAMEWORKS/StreamCore.framework" ]] || { print -u2 'Set MEDIA_LIFECYCLE_FRAMEWORKS to built StreamCore products.'; exit 77; }
mkdir -p "$LIFECYCLE_DIR"
python3 - "$LIFECYCLE_DIR" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
graph = Path('StreamMac/LayerGraph.swift').read_text()
values = graph[graph.index('struct GraphID<Tag>'):graph.index('// MARK: - Geometry')]
values += graph[graph.index('enum MediaEndAction:'):graph.index('struct PDFSourcePayload:')]
values += '''
final class ResolvedAssetAccess: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    var isAccessible: Bool { true }
}
'''
(folder / 'MediaValues.swift').write_text('import Foundation\nimport StreamCore\n' + values)
source = Path('StreamMac/MediaSourcePlayback.swift').read_text()
start = source.index('    // BEGIN bookmark-only file access')
end = source.index('    // END bookmark-only file access', start)
# Only the external bookmark/grant boundary changes in this generated tool.
# Counted ownership tokens do not establish real sandbox authorization.
source = source[:start] + '''    private static func bookmarkAccess(_ bookmark: Data) throws -> MediaPlaybackAccess {
        MediaPlaybackAccess(bookmark: MediaFileAccess(url: try FixtureState.shared.resolve(bookmark)))
    }
''' + source[end:]
source = source.replace('init(url: URL) { self.url = url }', 'init(url: URL) { self.url = url; FixtureState.shared.acquire() }')
source = source.replace('deinit { url.stopAccessingSecurityScopedResource() }', 'deinit { FixtureState.shared.release() }')
boundary = '            let tracks = try await asset.load(.tracks)'
assert source.count(boundary) == 1
source = source.replace(boundary, boundary + '\n            await FixtureState.shared.waitAfterMetadata(url.lastPathComponent)')
# A single fixture-owned host-time boundary: default is the actual CM clock.
# Only the exact transport-range case freezes/advances it. Decoder, transport,
# source frames and end callbacks remain the production implementation.
clock = 'CMClockGetTime(CMClockGetHostTimeClock())'
assert source.count(clock) >= 10
source = source.replace(clock, 'FixtureClock.shared.now()')
read = '        try file.read(into: pcm, frameCount: count)'
assert source.count(read) == 1
source = source.replace(read, read + '\n        FixtureOfflineDecodeDelay.shared.afterRead()')
delivery = '            deliverAudio(audio, handler: handler, generation: generation, offlinePCM: true)\n            if ended'
assert source.count(delivery) == 1
source = source.replace(delivery,
    '            FixtureAudioPullTiming.shared.note(start: now, ready: FixtureClock.shared.now())\n' + delivery)
source += '''
extension MediaSourcePlayback {
    static func lifecyclePCMAdmission(_ url: URL) throws -> (original: CMSampleBuffer, fresh: CMSampleBuffer?, partial: CMSampleBuffer?, expired: CMSampleBuffer?, invalidClock: CMSampleBuffer?, distantClock: CMSampleBuffer?) {
        let decoder = try MediaOfflineAudio(url: url)
        guard let original = try decoder.next(through: CMTime(seconds: 1, preferredTimescale: 48_000), end: decoder.duration) else { throw CocoaError(.fileReadUnknown) }
        return (original,
            admittedOfflinePCM(original, at: CMTime(value: 480, timescale: 48_000)),
            admittedOfflinePCM(original, at: CMTime(value: 2_400, timescale: 48_000)),
            admittedOfflinePCM(original, at: CMTime(value: 9_600, timescale: 48_000)),
            admittedOfflinePCM(original, at: .invalid),
            admittedOfflinePCM(original, at: CMTime(value: Int64.max, timescale: 1)))
    }
    func lifecycleHeldDelivery() -> (@Sendable () -> Void)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let sample: CMSampleBuffer?
        if let offlineAudio { sample = try? offlineAudio.next(through: trimOut, end: trimOut) }
        else { sample = audioOutput?.copyNextSampleBuffer() }
        guard let sample else { return nil }
        let handler = onAudioSample, generation = loadGeneration
        let held = FixtureSample(sample)
        return { [self] in deliverAudio([held.value], handler: handler, generation: generation) }
    }
    func lifecycleItemPosition() -> Double? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return offlineAudio?.time(at: FixtureClock.shared.now(), playing: isPlaying).seconds
    }
    func lifecycleAnimatedCallbacks() -> ((@Sendable (SourceDefinitionID, MediaSourceStatus) -> Void)?, (@Sendable (SourceDefinitionID, Double) -> Void)?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (animated?.onStatus, animated?.onReachedEnd)
    }
    func lifecycleState() -> (loaded: Bool, videoPlayer: Bool, decoder: Bool, pending: Bool, retired: Bool, observing: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (didLoad, player != nil, audioReader != nil || offlineAudio != nil, loadTask != nil, retired, offlinePositionObserver != nil)
    }
}
'''
(folder / 'MediaSourcePlayback.swift').write_text(source)
PY
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$LIFECYCLE_FRAMEWORKS" -framework StreamCore \
  "$LIFECYCLE_DIR/MediaValues.swift" "$LIFECYCLE_DIR/MediaSourcePlayback.swift" \
  StreamMac/AnimatedOverlayPlayback.swift scripts/media_playback_lifecycle_harness.swift \
  -o "$LIFECYCLE_DIR/harness"
env DYLD_FRAMEWORK_PATH="${LIFECYCLE_FRAMEWORKS:A}" "$LIFECYCLE_DIR/harness" "${LIFECYCLE_DIR:A}" "$@"
