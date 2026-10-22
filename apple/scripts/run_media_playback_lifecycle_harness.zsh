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
source += '''
extension MediaSourcePlayback {
    func lifecycleHeldDelivery() -> (@Sendable () -> Void)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let sample = audioOutput?.copyNextSampleBuffer() else { return nil }
        let handler = onAudioSample, generation = loadGeneration
        let held = FixtureSample(sample)
        return { [self] in deliverAudio([held.value], handler: handler, generation: generation) }
    }
    func lifecycleAnimatedCallbacks() -> ((@Sendable (SourceDefinitionID, MediaSourceStatus) -> Void)?, (@Sendable (SourceDefinitionID, Double) -> Void)?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (animated?.onStatus, animated?.onReachedEnd)
    }
    func lifecycleState() -> (loaded: Bool, player: Bool, reader: Bool, pending: Bool, retired: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (didLoad, player != nil, audioReader != nil, loadTask != nil, retired)
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
env DYLD_FRAMEWORK_PATH="${LIFECYCLE_FRAMEWORKS:A}" "$LIFECYCLE_DIR/harness" "${LIFECYCLE_DIR:A}"
