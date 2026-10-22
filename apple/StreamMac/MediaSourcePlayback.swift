import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore
import os.lock

/// A02 (issue #97): the pull-based frame surface the composition engines read
/// each tick. Unlike camera/screen holders (push: the capture writes, the
/// engine reads the latest), media frames are PULLED — the engine's render
/// tick is the cadence, so playout needs no second clock and no runaway
/// timers. Pulling also tops up the source's mix-engine audio, so audio and
/// video ride the same tick.
protocol MediaFrameSource: Sendable {
    func pullFrame() -> CVPixelBuffer?
}

/// A02 (issue #97): one media source's playout phase — the per-source status
/// the issue's acceptance criteria name (loaded/playing/paused/ended/error).
enum MediaPlayoutPhase: String, Sendable, Equatable {
    /// No playback engine has loaded the file yet (source just registered).
    case idle
    case loading
    /// Loaded and parked at the trim-in point (also the state after Stop).
    case ready
    case playing
    case paused
    /// Reached the end with the HOLD end action — the last frame keeps
    /// painting (the documented fallback).
    case ended
    case error
}

/// The transport UI's view of one media source. Session state only — never
/// persisted (the payload owns loops/autoplay/end action/trim).
struct MediaSourceStatus: Equatable, Sendable {
    var phase: MediaPlayoutPhase = .idle
    /// Playhead position in SECONDS on the file's own timeline.
    var positionSeconds: Double = 0
    /// Full file duration in seconds (trim points apply around this).
    var durationSeconds: Double = 0
    var errorMessage: String? = nil

    var remainingSeconds: Double { max(0, durationSeconds - positionSeconds) }
}

/// Builds the registry payload for a user-picked video file. The app is
/// sandboxed, so the security-scoped bookmark is the persisted access grant
/// (S05's pattern for file-backed sources): the raw URL alone would not
/// reopen across launches. `com.apple.security.files.user-selected.read-only`
/// + `com.apple.security.files.bookmarks.app-scope` entitlements cover this.
enum MediaSourceFactory {
    static func payload(forPickedFile url: URL) -> MediaSourcePayload? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return nil }
        return MediaSourcePayload(bookmarkData: bookmark,
                                  fileName: url.lastPathComponent)
    }
}

/// Serializes only sample delivery. Terminal retirement drains delivery after
/// releasing the playback lock, before the owner removes its mixer channel.
private final class MediaAudioDeliveryGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true
    func deliver(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if active { body() }
    }
    func revokeAndDrain() {
        lock.lock(); active = false; lock.unlock()
    }
}

private final class MediaFileAccess: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { url.stopAccessingSecurityScopedResource() }
}

/// Preserve the owner of either an external bookmark grant or a library
/// reference. Project copies need no external sandbox scope.
private final class MediaPlaybackAccess: @unchecked Sendable {
    let url: URL
    private let bookmark: MediaFileAccess?
    private let library: ResolvedAssetAccess?
    init(bookmark: MediaFileAccess) { self.url = bookmark.url; self.bookmark = bookmark; self.library = nil }
    init(library: ResolvedAssetAccess) { self.url = library.url; self.bookmark = nil; self.library = library }
}

/// File-only PCM decoding has no player, output device, AudioQueue, or HAL
/// clock. The owning playback lock serializes bounded reads and seeks; PCM
/// stays at its native rate until the existing mixer converter receives it.
private final class MediaOfflineAudio: @unchecked Sendable {
    let file: AVAudioFile
    let duration: CMTime
    private let format: CMAudioFormatDescription
    var position: CMTime = .zero
    var startedAt: CMTime = .zero
    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, (8_000...384_000).contains(rate), (1...32).contains(file.processingFormat.channelCount), file.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        duration = CMTime(seconds: Double(file.length) / rate, preferredTimescale: 1_000_000_000)
        var asbd = file.processingFormat.streamDescription.pointee
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw CocoaError(.fileReadCorruptFile) }
        format = description
    }
    func time(at now: CMTime, playing: Bool) -> CMTime {
        playing ? position + (now - startedAt) : position
    }
    func seek(_ target: CMTime, now: CMTime) {
        position = target; startedAt = now
        file.framePosition = min(file.length, max(0, AVAudioFramePosition((target.seconds * file.processingFormat.sampleRate).rounded(.down))))
    }
    func discard(before time: CMTime) {
        // Round toward the first admitted frame, never just behind the edge.
        let frame = min(file.length, max(0, AVAudioFramePosition((time.seconds * file.processingFormat.sampleRate).rounded(.up))))
        if file.framePosition < frame { file.framePosition = frame }
    }
    func next(through horizon: CMTime, end: CMTime) throws -> CMSampleBuffer? {
        let rate = file.processingFormat.sampleRate
        let upper = min(file.length, AVAudioFramePosition((min(horizon.seconds, end.seconds) * rate).rounded(.up)))
        let start = file.framePosition
        guard start < upper else { return nil }
        let count = AVAudioFrameCount(min(4096, upper - start))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: pcm, frameCount: count)
        guard pcm.frameLength > 0, file.framePosition > start,
              let bytes = pcm.audioBufferList.pointee.mBuffers.mData else { throw CocoaError(.fileReadCorruptFile) }
        let length = Int(pcm.frameLength) * Int(file.processingFormat.streamDescription.pointee.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr else {
            throw CocoaError(.fileReadUnknown)
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: Int(pcm.frameLength), presentationTimeStamp: CMTime(seconds: Double(start) / rate, preferredTimescale: 1_000_000_000),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { throw CocoaError(.fileReadUnknown) }
        return sample
    }
}

/// A02 (issue #97): the playback engine for ONE registry media source.
///
/// G09 (issue #116): image files (GIF/APNG/animated HEIC) dispatch at load
/// to the CGImageSource frame-stepping engine in `AnimatedOverlayPlayback.swift`
/// (same pull cadence and transport semantics — this class stays the pool's
/// single entry point); video files, including ProRes 4444 / HEVC-alpha
/// overlay assets, take the AVPlayer path below, whose 32BGRA output
/// preserves their alpha channel.
///
/// **Clock discipline.** Video frames are PULLED by the composition engines'
/// render tick (`pullFrame`): the engine asks for the frame at the player's
/// current item time and stamps the composited output on its own shared host
/// clock — playout adds no timebase of its own. Audio is pulled from a
/// separate `AVAssetReader` (the player itself is muted) on the same tick,
/// 150 ms ahead of the playhead. Audio-only files instead use AVAudioFile
/// with no AVPlayer/output device; their playhead derives directly from the
/// same host clock and pauses by freezing its item-position anchor. Each buffer's item-timeline PTS is
/// mapped onto the shared host clock (`hostNow − (itemTime − samplePTS)` at
/// rate 1) before it is enqueued as the A01 mix engine's `.media(sourceID)`
/// channel. The mix engine's ring absorbs the delivery jitter by absolute
/// host position, so media audio and video derive from one clock and cannot
/// drift apart — through scene changes, because the SAME playback instance
/// feeds every composition (preview and program pull identical frames).
///
/// **Transport.** play/pause/stop/restart/seek, looping, and the HOLD/STOP
/// end actions (the issue's return-to-previous-scene / advance-the-rundown
/// actions are S08 scene-control hooks — `MediaEndAction` is the seam).
/// Play after end restarts from the trim-in point; Stop rewinds to trim-in
/// AND clears the held frame (the renderer's black fallback); Pause and the
/// HOLD end action keep serving the last pulled frame.
///
/// **Lifecycle.** The pool starts loading on first scene reference and pauses
/// mid-file when the last reference goes away (position holds — a Take or a
/// scene change never restarts playback). Explicit transport commands act on
/// this one shared instance even while unreferenced (audition: position
/// advances, nothing renders and no audio reaches the mix until a layer
/// pulls frames). A relink (payload bookmark change) is detected on the pull
/// path and reloads the file without disturbing any other source.
///
/// **Threading.** Transport and load callbacks run on the main actor (pool /
/// observers); `pullFrame` runs on the composition engine actors. All mutable
/// state sits behind one unfair lock; observer closures never reenter it.
final class MediaSourcePlayback: MediaFrameSource, @unchecked Sendable {
    let sourceID: SourceDefinitionID
    /// Live payload reads (loops/end action take effect at the next loop
    /// point or end; a bookmark change triggers the relink reload). Reads
    /// the pool-published `SourcePayloadStore` — the registry is the
    /// identity authority, exactly like capture demand resolution.
    private let payloadProvider: @Sendable () -> MediaSourcePayload?
    private let assetAccessProvider: (@MainActor @Sendable (String) -> ResolvedAssetAccess?)?
    /// Pool-wired: retimed audio buffers for the mix engine's
    /// `.media(sourceID)` channel. Fired off the engine tick, never under
    /// the lock.
    var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Pool-wired: status mirror for the transport UI. Fired under the lock
    /// but required to never reenter the playback (the pool hops actors).
    var onStatus: (@Sendable (SourceDefinitionID, MediaSourceStatus) -> Void)?

    var onReachedEnd: (@Sendable (SourceDefinitionID, Double) -> Void)?

    private var lock = os_unfair_lock_s()
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var asset: AVAsset?
    private var assetDuration: CMTime = .invalid
    private var offlineAudio: MediaOfflineAudio?
    private var offlinePositionObserver: Task<Void, Never>?
    private var rejectedAudioTrimOut: Double?
    private var audioTrack: AVAssetTrack?
    private var audioReader: AVAssetReader?
    private var audioOutput: AVAssetReaderTrackOutput?
    /// Item-timeline time the audio reader has supplied through (the pacing
    /// cursor for the 150 ms read-ahead).
    private var audioBufferedThrough: CMTime = .zero
    private var lastVideoBuffer: CVPixelBuffer?
    private var trimIn: CMTime = .zero
    private var trimOut: CMTime = .invalid
    private var status = MediaSourceStatus()
    private var isPlaying = false
    /// Reentrancy guard: the natural-end notification and the trim-out
    /// boundary observer can both fire for one end of file.
    private var isEnding = false
    /// A play requested before the file finished loading; honored (with
    /// autoplay) at the end of `configure`.
    private var wantsPlay = false
    private var wantsPause = false
    private var recovery = PausedMediaRecovery()
    private var didLoad = false
    private var loadedBookmark: Data?
    private var loadedAssetIdentifier: String?
    /// G09 (issue #116): animated-image files (GIF/APNG/animated HEIC) have
    /// no AVAsset representation — they play through this CGImageSource
    /// frame-stepping engine instead of the AVPlayer path. Same pull cadence,
    /// same transport semantics, same shared instance (so preview and
    /// program stay frame-synchronized, and the animation composites stably
    /// above S09 transition blends).
    private var animated: AnimatedImagePlayback?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var retired = false
    private var fileAccess: MediaPlaybackAccess?
    private let audioDelivery = MediaAudioDeliveryGate()
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var endNotificationObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?

    init(sourceID: SourceDefinitionID,
         assetAccessProvider: (@MainActor @Sendable (String) -> ResolvedAssetAccess?)? = nil,
         payloadProvider: @escaping @Sendable () -> MediaSourcePayload?) {
        self.sourceID = sourceID
        self.payloadProvider = payloadProvider
        self.assetAccessProvider = assetAccessProvider
    }

    // BEGIN bookmark-only file access
    private static func bookmarkAccess(_ bookmark: Data) throws -> MediaPlaybackAccess {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        return MediaPlaybackAccess(bookmark: MediaFileAccess(url: url))
    }
    // END bookmark-only file access

    /// A same-ID library relink/replacement retires its old decoder and grant;
    /// load-generation checks prevent the earlier file from publishing later.
    func reloadAsset(_ identifiers: Set<AssetID>) {
        os_unfair_lock_lock(&lock)
        guard !retired, let raw = payloadProvider()?.assetIdentifier, let uuid = UUID(uuidString: raw), identifiers.contains(AssetID(uuid)) else {
            os_unfair_lock_unlock(&lock); return
        }
        teardownLocked()
        os_unfair_lock_unlock(&lock)
        load()
    }

    // MARK: - Loading

    /// Resolves the security-scoped bookmark and builds the player. No-op
    /// once loaded (or while a load is in flight).
    func load() {
        os_unfair_lock_lock(&lock)
        guard !retired, !didLoad, loadTask == nil else {
            os_unfair_lock_unlock(&lock)
            return
        }
        status.phase = .loading
        status.errorMessage = nil
        publishStatusLocked()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.performLoad(generation: generation)
        }
        os_unfair_lock_unlock(&lock)
    }

    private func performLoad(generation: UInt64) async {
        guard let payload = payloadProvider() else {
            fail("The media source has no registered payload — relink it to a video file.", generation: generation)
            return
        }
        let bookmark = payload.bookmarkData
        do {
            let access: MediaPlaybackAccess
            if let identifier = payload.assetIdentifier {
                guard let assetAccessProvider, let resolved = await assetAccessProvider(identifier), resolved.isAccessible else {
                    fail("The video asset is missing. Relink it in Assets before playing this source.", generation: generation)
                    return
                }
                access = MediaPlaybackAccess(library: resolved)
            } else if let bookmark {
                access = try Self.bookmarkAccess(bookmark)
            } else {
                fail("No video file is linked — relink the source to an MP4/MOV file.", generation: generation)
                return
            }
            let url = access.url
            try Task.checkCancellation()
            // G09 (issue #116): animated-image files dispatch to the
            // CGImageSource engine — the probe doubles as the load-time
            // unsupported-format gate (static/undecodable images fail here
            // with the explicit reason, never reaching program).
            if MediaOverlayClassifier.isAnimatedImageCandidate(url: url) {
                switch MediaOverlayClassifier.probeAnimatedImage(url: url) {
                case .failure(let error):
                    fail(error.message, generation: generation)
                case .success(let contents):
                    configureAnimated(contents: contents, bookmark: bookmark, assetIdentifier: payload.assetIdentifier, access: access, generation: generation)
                }
                return
            }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let hasVideo = tracks.contains { $0.mediaType == .video }
            let hasAudio = tracks.contains { $0.mediaType == .audio }
            // A03 (issue #98): audio-only assets load too — the soundboard,
            // music playlists, and scene sounds reuse this engine for
            // clips that have no video track. Those files use bounded offline
            // PCM reads and the shared host clock, without a device player.
            guard hasVideo || hasAudio else {
                fail("\"\(url.lastPathComponent)\" has no audio or video track — sources need an AVFoundation-readable media file (MP4/MOV/ProRes/MP3/AAC/WAV/AIFF).", generation: generation)
                return
            }
            if !hasVideo {
                let decoded = try MediaOfflineAudio(url: url)
                configureAudio(decoded, bookmark: bookmark, assetIdentifier: payload.assetIdentifier, access: access, generation: generation)
                return
            }
            // `AVPlayerItem.init(asset:)` is MainActor-isolated, so the
            // player build hops to the main actor (transport and observer
            // callbacks live there anyway; only frame/audio pulls run on
            // the engine actors, through the nonisolated output APIs).
            await configure(asset: asset, bookmark: bookmark, assetIdentifier: payload.assetIdentifier, access: access, generation: generation,
                            duration: duration,
                            audioTrack: tracks.first(where: { $0.mediaType == .audio }))
        } catch {
            fail("The video file could not be opened: \(error.localizedDescription)", generation: generation)
        }
    }

    private func configureAudio(_ decoded: MediaOfflineAudio, bookmark: Data?, assetIdentifier: String?, access: MediaPlaybackAccess, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard acceptsLoadLocked(bookmark: bookmark, assetIdentifier: assetIdentifier, generation: generation) else {
            os_unfair_lock_unlock(&lock); return
        }
        assetDuration = decoded.duration
        loadedBookmark = bookmark; loadedAssetIdentifier = assetIdentifier
        let payload = payloadProvider()
        trimIn = CMTime(seconds: max(0, payload?.trimInSeconds ?? 0), preferredTimescale: 1_000_000_000)
        trimOut = payload?.trimOutSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) } ?? decoded.duration
        if !trimOut.isNumeric || trimOut > decoded.duration { trimOut = decoded.duration }
        if trimIn >= trimOut { trimIn = .zero }
        guard trimOut > trimIn else {
            // Keep a stable repairable error, rather than starting an empty
            // loop or repeatedly reopening the same invalid trim on each pull.
            rejectedAudioTrimOut = payload?.trimOutSeconds
            didLoad = true; loadTask = nil
            status.phase = .error; status.durationSeconds = decoded.duration.seconds
            status.errorMessage = "Trim Out must be later than Trim In. Adjust the trim range before playing."
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        fileAccess = access; offlineAudio = decoded
        decoded.seek(trimIn, now: CMClockGetTime(CMClockGetHostTimeClock()))
        didLoad = true
        status.phase = .ready; status.positionSeconds = trimIn.seconds; status.durationSeconds = decoded.duration.seconds
        publishStatusLocked()
        let shouldPlay = recovery.shouldPlay(autoplay: payload?.autoplay ?? true, requested: wantsPlay) && !wantsPause
        let recoverySeek = recovery.consumePosition()
        loadTask = nil
        os_unfair_lock_unlock(&lock)
        if let recoverySeek { pause(); seek(toSeconds: recoverySeek) }
        if shouldPlay { play() }
    }

    @MainActor
    private func configure(asset: AVAsset, bookmark: Data?, assetIdentifier: String?, access: MediaPlaybackAccess?, generation: UInt64,
                           duration: CMTime, audioTrack: AVAssetTrack?) {
        os_unfair_lock_lock(&lock)
        guard acceptsLoadLocked(bookmark: bookmark, assetIdentifier: assetIdentifier, generation: generation) else {
            os_unfair_lock_unlock(&lock); return
        }
        fileAccess = access
        self.asset = asset
        assetDuration = duration
        self.audioTrack = audioTrack
        loadedBookmark = bookmark
        loadedAssetIdentifier = assetIdentifier
        let payload = payloadProvider()
        trimIn = CMTime(seconds: max(0, payload?.trimInSeconds ?? 0),
                        preferredTimescale: 600)
        trimOut = payload?.trimOutSeconds.map {
            CMTime(seconds: $0, preferredTimescale: 600)
        } ?? duration
        if !trimOut.isNumeric || CMTimeCompare(trimOut, duration) > 0 {
            trimOut = duration
        }
        if CMTimeCompare(trimIn, trimOut) >= 0 {
            trimIn = .zero
        }

        let item = AVPlayerItem(asset: asset)
        // 32BGRA carries a full alpha channel, so ProRes 4444/4444XQ and
        // HEVC-with-alpha tracks (G09, issue #116) keep their transparency
        // through this decode path — the renderer's CIImage compositing is
        // premultiplied-alpha-correct against it. Codec VALIDATION for the
        // alpha-overlay add path happens at import
        // (`MediaOverlayClassifier.probeAlphaVideo`); an opaque codec here
        // simply composites like any other video.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        // Audio reaches the mix through the AVAssetReader path below; the
        // player itself must never sound on the local speakers.
        player.isMuted = true
        player.actionAtItemEnd = .pause

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                self?.fail(item.error?.localizedDescription ?? "The video file failed to load.", generation: generation)
            }
        }
        endNotificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.handleReachedEnd(generation: generation)
        }
        // A trim-out short of the file's natural end is the same "reached
        // end" event for looping/end actions.
        if CMTimeCompare(trimOut, duration) < 0 {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: trimOut)], queue: .main
            ) { [weak self] in
                self?.handleReachedEnd(generation: generation)
            }
        }

        playerItem = item
        videoOutput = output
        self.player = player
        resetAudioReaderLocked(at: trimIn)
        player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
        didLoad = true
        status.phase = .ready
        status.positionSeconds = trimIn.seconds
        status.durationSeconds = duration.isNumeric ? duration.seconds : 0
        publishStatusLocked()
        let autoplay = payload?.autoplay ?? true
        let shouldPlay = recovery.shouldPlay(autoplay: autoplay, requested: wantsPlay) && !wantsPause
        let recoverySeek = recovery.consumePosition()
        os_unfair_lock_unlock(&lock)
        if let recoverySeek { pause(); seek(toSeconds: recoverySeek) }
        if shouldPlay { play() }
        os_unfair_lock_lock(&lock)
        if loadGeneration == generation { loadTask = nil }
        os_unfair_lock_unlock(&lock)
    }

    /// G09 (issue #116): loads an animated image into the CGImageSource
    /// engine. Transport/status plumbing is identical to the video path —
    /// the engine reports through the same `onStatus` mirror and honors the
    /// payload's loops/autoplay/end action live.
    private func configureAnimated(contents: AnimatedImageContents, bookmark: Data?, assetIdentifier: String?,
                                   access: MediaPlaybackAccess?, generation: UInt64) {
        let engine = AnimatedImagePlayback(sourceID: sourceID,
                                           payloadProvider: payloadProvider)
        engine.onReachedEnd = { [weak self] id, time in
            self?.forwardAnimatedEnd(id, time: time, generation: generation)
        }
        engine.onStatus = { [weak self] id, status in
            self?.forwardAnimatedStatus(id, status: status, generation: generation)
        }
        os_unfair_lock_lock(&lock)
        guard acceptsLoadLocked(bookmark: bookmark, assetIdentifier: assetIdentifier, generation: generation) else {
            os_unfair_lock_unlock(&lock); return
        }
        fileAccess = access
        animated = engine
        loadedBookmark = bookmark
        loadedAssetIdentifier = assetIdentifier
        didLoad = true
        status.phase = .ready
        status.positionSeconds = 0
        status.durationSeconds = contents.timeline.duration
        let autoplay = payloadProvider()?.autoplay ?? true
        let shouldPlay = recovery.shouldPlay(autoplay: autoplay, requested: wantsPlay) && !wantsPause
        let recoverySeek = recovery.consumePosition()
        os_unfair_lock_unlock(&lock)
        engine.configure(contents: contents, autoplayHint: shouldPlay)
        if let recoverySeek { engine.pause(); engine.seek(toSeconds: recoverySeek); if shouldPlay { engine.play() } }
        os_unfair_lock_lock(&lock)
        if loadGeneration == generation { loadTask = nil }
        os_unfair_lock_unlock(&lock)
    }

    private func forwardAnimatedStatus(_ id: SourceDefinitionID, status: MediaSourceStatus, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !retired, loadGeneration == generation else { return }
        onStatus?(id, status)
    }

    private func forwardAnimatedEnd(_ id: SourceDefinitionID, time: Double, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !retired, loadGeneration == generation else { return }
        onReachedEnd?(id, time)
    }

    private func acceptsLoadLocked(bookmark: Data?, assetIdentifier: String?, generation: UInt64) -> Bool {
        guard !retired, loadGeneration == generation, !Task.isCancelled else { return false }
        let current = payloadProvider()
        guard current?.assetIdentifier == assetIdentifier, assetIdentifier != nil || current?.bookmarkData == bookmark else {
            teardownLocked()
            return false
        }
        return true
    }

    private func fail(_ message: String, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard !retired, loadGeneration == generation else {
            os_unfair_lock_unlock(&lock); return
        }
        isPlaying = false
        status.phase = .error
        status.errorMessage = message
        publishStatusLocked()
        loadTask = nil
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Frame + audio pulling (composition engine tick)

    /// The composition engines' per-tick read: the frame for the player's
    /// CURRENT item time (the newest decoded frame when playing; the held
    /// frame when paused/ended — the documented last-frame fallback), plus a
    /// top-up of the source's mix-engine audio paced to the same tick. A
    /// source with no pixels (loading, error, Stop end action) returns nil —
    /// the renderer's paint-nothing fallback.
    func pullFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        guard !retired else { os_unfair_lock_unlock(&lock); return nil }
        // A relink (the registry payload's bookmark changed) reloads the
        // file in place; no other source is disturbed.
        if didLoad {
            let current = payloadProvider()
            if current?.assetIdentifier != loadedAssetIdentifier || (loadedAssetIdentifier == nil && current?.bookmarkData != loadedBookmark)
                || (rejectedAudioTrimOut != nil && current?.trimOutSeconds != rejectedAudioTrimOut) {
                teardownLocked()
            }
        }
        if !didLoad, loadTask == nil, status.phase != .loading {
            // Reload after a teardown (relink) — load() manages its own lock,
            // so defer it past the unlock below.
            os_unfair_lock_unlock(&lock)
            load()
            return nil
        }
        // G09: animated-image sources delegate the pull to the CGImageSource
        // engine (no AVPlayer state exists for them; audio is n/a).
        if let animated {
            os_unfair_lock_unlock(&lock)
            return animated.pullFrame()
        }
        if let offlineAudio {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let itemTime = offlineAudio.time(at: now, playing: isPlaying)
            let time = min(trimOut, itemTime)
            var audio: [CMSampleBuffer] = []
            if isPlaying {
                do {
                    offlineAudio.discard(before: max(trimIn, itemTime - CMTime(seconds: 0.02, preferredTimescale: 600)))
                    let horizon = time + CMTime(seconds: 0.15, preferredTimescale: 600)
                    while let sample = try offlineAudio.next(through: horizon, end: trimOut) {
                        let hostPTS = now - (itemTime - sample.presentationTimeStamp)
                        // Source-frame rounding and nanosecond CMTime conversion
                        // may place the first frame exactly on the admission edge.
                        let edge = now - CMTime(seconds: 0.020001, preferredTimescale: 1_000_000_000)
                        if hostPTS >= edge, let retimed = retiming(sample, to: hostPTS) { audio.append(retimed) }
                    }
                } catch {
                    isPlaying = false; offlinePositionObserver?.cancel(); offlinePositionObserver = nil
                    status.phase = .error; status.errorMessage = "The audio file could not be decoded: \(error.localizedDescription)"
                    publishStatusLocked()
                }
                if time.seconds - status.positionSeconds >= 0.5 { status.positionSeconds = time.seconds; publishStatusLocked() }
            }
            let ended = isPlaying && time >= trimOut
            let handler = onAudioSample, generation = loadGeneration
            os_unfair_lock_unlock(&lock)
            deliverAudio(audio, handler: handler, generation: generation)
            if ended { handleOfflineEnd(generation: generation) }
            return nil
        }
        var audio: [CMSampleBuffer] = []
        if let item = playerItem, let output = videoOutput {
            let time = item.currentTime()
            if time.isNumeric {
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time,
                                                       itemTimeForDisplay: nil) {
                    lastVideoBuffer = buffer
                }
                if isPlaying {
                    audio = collectAudioLocked(itemTime: time)
                }
            }
        }
        let frame = lastVideoBuffer
        let handler = onAudioSample
        let generation = loadGeneration
        os_unfair_lock_unlock(&lock)
        deliverAudio(audio, handler: handler, generation: generation)
        return frame
    }

    private func deliverAudio(_ audio: [CMSampleBuffer], handler: (@Sendable (CMSampleBuffer) -> Void)?, generation: UInt64) {
        audioDelivery.deliver {
            os_unfair_lock_lock(&lock)
            let current = !retired && loadGeneration == generation
            os_unfair_lock_unlock(&lock)
            guard current else { return }
            for sample in audio { handler?(sample) }
        }
    }

    /// Reads decompressed audio up to 150 ms past the playhead and retimes
    /// each buffer onto the shared host clock. Buffers already in the past
    /// (right after a seek/loop reset) are dropped — the mix engine would
    /// place them behind its write cursor anyway.
    private func collectAudioLocked(itemTime: CMTime) -> [CMSampleBuffer] {
        guard let audioOutput else { return [] }
        let horizon = CMTimeAdd(itemTime, CMTime(seconds: 0.15, preferredTimescale: 600))
        var collected: [CMSampleBuffer] = []
        while CMTimeCompare(audioBufferedThrough, horizon) < 0 {
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                // Range exhausted (trim-out / natural end); the loop or end
                // action's audio-reader reset resumes coverage.
                audioReader = nil
                self.audioOutput = nil
                break
            }
            let pts = sample.presentationTimeStamp
            let end = CMTimeAdd(pts, sample.duration)
            audioBufferedThrough = end.isNumeric ? end : pts
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let hostPTS = CMTimeSubtract(hostNow, CMTimeSubtract(itemTime, pts))
            let pastEdge = CMTimeSubtract(hostNow, CMTime(seconds: 0.02, preferredTimescale: 600))
            guard CMTimeCompare(hostPTS, pastEdge) > 0,
                  let retimed = retiming(sample, to: hostPTS) else { continue }
            collected.append(retimed)
        }
        return collected
    }

    /// Rebuilds the audio reader from `time` to the trim-out point. The
    /// reader decompresses to LPCM (the mix engine's canonical converter
    /// takes it from there — compressed buffers would be dropped).
    private func resetAudioReaderLocked(at time: CMTime) {
        audioReader?.cancelReading()
        audioReader = nil
        audioOutput = nil
        guard let asset, let audioTrack,
              let reader = try? AVAssetReader(asset: asset) else { return }
        let end = trimOut.isNumeric ? trimOut : assetDuration
        guard end.isNumeric else { return }
        reader.timeRange = CMTimeRangeFromTimeToTime(start: time, end: end)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }
        audioReader = reader
        audioOutput = output
        audioBufferedThrough = time
    }

    private func retiming(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        // Entries contain per-sample durations. Reusing the aggregate
        // `sample.duration` would multiply an 8192-frame chunk into 1398 s.
        // Shift every valid timestamp together; retain durations and invalid
        // DTS entries verbatim so relative decode/presentation timing holds.
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0, sample.presentationTimeStamp.isNumeric else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        let read = timings.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: $0.baseAddress, entriesNeededOut: nil)
        }
        guard read == noErr else { return nil }
        let offset = pts - sample.presentationTimeStamp
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isNumeric { timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset }
            if timings[index].decodeTimeStamp.isNumeric { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset }
        }
        var out: CMSampleBuffer?
        let copied = timings.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress!, sampleBufferOut: &out)
        }
        return copied == noErr ? out : nil
    }

    // MARK: - Transport

    /// Play. After ENDED this restarts from the trim-in point (Ecamm-style:
    /// pressing play on a finished file replays it).
    func play() {
        os_unfair_lock_lock(&lock)
        guard !retired else { os_unfair_lock_unlock(&lock); return }
        recovery.playIntent()
        wantsPlay = true; wantsPause = false
        // G09: animated-image sources forward transport to their engine.
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.play()
            return
        }
        if let offlineAudio, didLoad {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if status.phase == .ended { offlineAudio.seek(trimIn, now: now) }
            else if !isPlaying { offlineAudio.startedAt = now }
            isEnding = false; isPlaying = true; status.phase = .playing; status.errorMessage = nil
            startOfflinePositionObserverLocked()
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        guard let player, didLoad else {
            os_unfair_lock_unlock(&lock)
            return
        }
        if status.phase == .ended {
            player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
            resetAudioReaderLocked(at: trimIn)
            status.positionSeconds = trimIn.seconds
        }
        isEnding = false
        isPlaying = true
        status.phase = .playing
        status.errorMessage = nil
        addPositionObserverLocked(player)
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
        player.play()
    }

    /// Pause mid-file — the held frame keeps painting (also the pool's
    /// demand-loss behavior: position holds for the next reference).
    func pause() {
        os_unfair_lock_lock(&lock)
        wantsPlay = false; wantsPause = true
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.pause()
            return
        }
        if let offlineAudio {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let position = min(trimOut, offlineAudio.time(at: now, playing: isPlaying))
            // Re-read the bounded lookahead under the next play anchor; those
            // old host timestamps must not create a gap after a long pause.
            offlineAudio.seek(position, now: now); isPlaying = false
            offlinePositionObserver?.cancel(); offlinePositionObserver = nil
            status.positionSeconds = offlineAudio.position.seconds
            if status.phase == .playing { status.phase = .paused }
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        guard let player else {
            os_unfair_lock_unlock(&lock)
            return
        }
        player.pause()
        isPlaying = false
        removePositionObserverLocked(player)
        let position = player.currentTime()
        if position.isNumeric { status.positionSeconds = position.seconds }
        if status.phase == .playing {
            status.phase = .paused
        }
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Stop: rewind to the trim-in point AND clear the held frame — the
    /// renderer's paint-nothing (black/background) fallback, matching the
    /// issue's "stop" end action.
    func stop() {
        os_unfair_lock_lock(&lock)
        wantsPlay = false; wantsPause = true
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.stop()
            return
        }
        if let offlineAudio {
            offlineAudio.seek(trimIn, now: CMClockGetTime(CMClockGetHostTimeClock()))
            isPlaying = false; isEnding = false; status.phase = .ready; status.positionSeconds = trimIn.seconds
            offlinePositionObserver?.cancel(); offlinePositionObserver = nil
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        guard let player else {
            os_unfair_lock_unlock(&lock)
            return
        }
        player.pause()
        isPlaying = false
        isEnding = false
        removePositionObserverLocked(player)
        player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
        resetAudioReaderLocked(at: trimIn)
        lastVideoBuffer = nil
        status.phase = .ready
        status.positionSeconds = trimIn.seconds
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Restart: back to the trim-in point and playing.
    func restart() {
        os_unfair_lock_lock(&lock)
        guard !retired else { os_unfair_lock_unlock(&lock); return }
        recovery.restartIntent()
        wantsPlay = true; wantsPause = false
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.restart()
            return
        }
        if let offlineAudio, didLoad {
            offlineAudio.seek(trimIn, now: CMClockGetTime(CMClockGetHostTimeClock()))
            isEnding = false; isPlaying = true; status.phase = .playing; status.positionSeconds = trimIn.seconds
            startOfflinePositionObserverLocked()
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        guard let player, didLoad else {
            os_unfair_lock_unlock(&lock)
            return
        }
        isEnding = false
        player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
        resetAudioReaderLocked(at: trimIn)
        isPlaying = true
        status.phase = .playing
        status.positionSeconds = trimIn.seconds
        addPositionObserverLocked(player)
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
        player.play()
    }

    /// Explicit recovery seeds local playout without honoring autoplay. Only a
    /// subsequent operator Play/Restart releases this hold, including slow loads.
    func restorePausedPosition(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        os_unfair_lock_lock(&lock)
        recovery.restore(seconds: seconds); wantsPlay = false
        let loaded = didLoad
        if loaded { _ = recovery.consumePosition() }
        os_unfair_lock_unlock(&lock)
        if loaded { pause(); seek(toSeconds: seconds) }
        else { load() }
    }

    /// Seek to an absolute file position in seconds (clamped to the trim
    /// range). Frame-accurate (zero tolerances): scrub commits and
    /// pause-stepping land on the exact frame.
    func seek(toSeconds seconds: Double) {
        os_unfair_lock_lock(&lock)
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.seek(toSeconds: seconds)
            return
        }
        if let offlineAudio, didLoad, seconds.isFinite {
            let target = min(max(seconds, trimIn.seconds), trimOut.seconds)
            offlineAudio.seek(CMTime(seconds: target, preferredTimescale: 1_000_000_000), now: CMClockGetTime(CMClockGetHostTimeClock()))
            isEnding = false; status.positionSeconds = target
            if status.phase == .ended { status.phase = .paused }
            if isPlaying { startOfflinePositionObserverLocked() }
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        guard let player, didLoad, seconds.isFinite else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let lower = trimIn.seconds
        let upper = trimOut.isNumeric ? trimOut.seconds : seconds
        let clamped = min(max(seconds, lower), max(lower, upper))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        resetAudioReaderLocked(at: target)
        isEnding = false
        status.positionSeconds = clamped
        if status.phase == .ended {
            status.phase = .paused
        }
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - End of file

    /// Natural end (or the trim-out boundary): loop back to trim-in, or apply
    /// the payload's end action — HOLD keeps the last frame painting, STOP
    /// rewinds and clears it (black fallback). The issue's
    /// return-to-previous-scene / advance-rundown actions are S08
    /// scene-control decisions; `MediaEndAction` is the seam for them.
    private func handleOfflineEnd(generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard !retired, loadGeneration == generation, !isEnding, isPlaying, let offlineAudio else {
            os_unfair_lock_unlock(&lock); return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // A concurrent seek/restart may have moved away from the boundary.
        guard offlineAudio.time(at: now, playing: true) >= trimOut else { os_unfair_lock_unlock(&lock); return }
        isEnding = true
        let payload = payloadProvider()
        if payload?.loops ?? true {
            offlineAudio.seek(trimIn, now: now); status.positionSeconds = trimIn.seconds; isEnding = false
            startOfflinePositionObserverLocked()
            publishStatusLocked(); os_unfair_lock_unlock(&lock); return
        }
        isPlaying = false
        offlinePositionObserver?.cancel(); offlinePositionObserver = nil
        if payload?.endAction == .stop {
            offlineAudio.seek(trimIn, now: now); status.phase = .ready; status.positionSeconds = trimIn.seconds
        } else {
            offlineAudio.position = trimOut; status.phase = .ended; status.positionSeconds = trimOut.seconds
        }
        publishStatusLocked(); os_unfair_lock_unlock(&lock)
        onReachedEnd?(sourceID, now.seconds)
    }

    private func handleReachedEnd(generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard !retired, loadGeneration == generation, !isEnding, isPlaying, let player else {
            os_unfair_lock_unlock(&lock)
            return
        }
        isEnding = true
        let payload = payloadProvider()
        if payload?.loops ?? true {
            player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
            resetAudioReaderLocked(at: trimIn)
            status.positionSeconds = trimIn.seconds
            isEnding = false
            publishStatusLocked()
            os_unfair_lock_unlock(&lock)
            player.play()
            return
        }
        isPlaying = false
        removePositionObserverLocked(player)
        audioReader?.cancelReading()
        audioReader = nil
        audioOutput = nil
        switch payload?.endAction ?? .hold {
        case .hold:
            status.phase = .ended
        case .stop:
            lastVideoBuffer = nil
            player.seek(to: trimIn, toleranceBefore: .zero, toleranceAfter: .zero)
            resetAudioReaderLocked(at: trimIn)
            status.phase = .ready
            status.positionSeconds = trimIn.seconds
        }
        let endedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
        onReachedEnd?(sourceID, endedAt)
    }

    // MARK: - Position reporting

    /// Like the video's periodic/boundary observers, this exists only while
    /// playing. It observes the host-derived clock without decoding or opening
    /// any output, so an unreferenced audition still reports position and end.
    private func startOfflinePositionObserverLocked() {
        offlinePositionObserver?.cancel()
        let generation = loadGeneration
        offlinePositionObserver = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.offlinePositionDelay(generation: generation) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.noteOfflinePosition(generation: generation)
            }
        }
    }

    private func offlinePositionDelay(generation: UInt64) -> Double? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard !retired, loadGeneration == generation, isPlaying, let offlineAudio else { return nil }
        let remaining = (trimOut - offlineAudio.time(at: CMClockGetTime(CMClockGetHostTimeClock()), playing: true)).seconds
        return max(0.001, min(0.5, remaining))
    }

    private func noteOfflinePosition(generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard !retired, loadGeneration == generation, !Task.isCancelled, isPlaying, let offlineAudio else {
            os_unfair_lock_unlock(&lock); return
        }
        let time = offlineAudio.time(at: CMClockGetTime(CMClockGetHostTimeClock()), playing: true)
        status.positionSeconds = min(trimOut, time).seconds
        publishStatusLocked()
        let ended = time >= trimOut
        os_unfair_lock_unlock(&lock)
        if ended { handleOfflineEnd(generation: generation) }
    }

    /// The 0.5 s position observer exists only while PLAYING (paused/ended
    /// sources report position on transport events) — no always-on timers.
    private func addPositionObserverLocked(_ player: AVPlayer) {
        guard periodicObserver == nil else { return }
        let generation = loadGeneration
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.notePosition(time, generation: generation)
        }
    }

    private func removePositionObserverLocked(_ player: AVPlayer) {
        if let periodicObserver {
            player.removeTimeObserver(periodicObserver)
        }
        periodicObserver = nil
    }

    private func notePosition(_ time: CMTime, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        guard !retired, loadGeneration == generation, didLoad, time.isNumeric else {
            os_unfair_lock_unlock(&lock)
            return
        }
        status.positionSeconds = time.seconds
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Teardown

    /// Terminal retirement differs from transport Stop: no pending load,
    /// observer, decoder or scoped resource may revive this instance.
    func shutdown() {
        os_unfair_lock_lock(&lock)
        guard !retired else {
            os_unfair_lock_unlock(&lock)
            audioDelivery.revokeAndDrain()
            return
        }
        retired = true
        onAudioSample = nil; onStatus = nil; onReachedEnd = nil
        wantsPlay = false; wantsPause = true
        teardownLocked()
        os_unfair_lock_unlock(&lock)
        // In-flight callbacks may enqueue into the mixer; drain them before
        // returning so the owner can now safely remove this channel.
        audioDelivery.revokeAndDrain()
    }

    deinit {
        onAudioSample = nil; onStatus = nil; onReachedEnd = nil
        teardownLocked()
    }

    /// Drops the current file (relink): every observer and reader goes, the
    /// held frame clears, and the next pull re-loads from the new bookmark.
    private func teardownLocked() {
        loadGeneration &+= 1
        loadTask?.cancel(); loadTask = nil
        if let player {
            player.pause()
            removePositionObserverLocked(player)
            if let boundaryObserver {
                player.removeTimeObserver(boundaryObserver)
            }
        }
        boundaryObserver = nil
        if let endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        endNotificationObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        audioReader?.cancelReading()
        audioReader = nil
        audioOutput = nil
        animated = nil
        offlinePositionObserver?.cancel(); offlinePositionObserver = nil
        offlineAudio = nil
        rejectedAudioTrimOut = nil
        player = nil
        playerItem = nil
        videoOutput = nil
        asset = nil
        fileAccess = nil
        assetDuration = .invalid
        audioTrack = nil
        lastVideoBuffer = nil
        isPlaying = false
        isEnding = false
        didLoad = false
        loadedBookmark = nil
        loadedAssetIdentifier = nil
        status.phase = .idle
        status.positionSeconds = 0
        status.durationSeconds = 0
        publishStatusLocked()
    }

    private func publishStatusLocked() {
        onStatus?(sourceID, status)
    }
}
