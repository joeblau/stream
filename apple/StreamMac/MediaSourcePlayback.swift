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
/// 150 ms ahead of the playhead, and each buffer's item-timeline PTS is
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
    private var recovery = PausedMediaRecovery()
    private var didLoad = false
    private var loadedBookmark: Data?
    /// G09 (issue #116): animated-image files (GIF/APNG/animated HEIC) have
    /// no AVAsset representation — they play through this CGImageSource
    /// frame-stepping engine instead of the AVPlayer path. Same pull cadence,
    /// same transport semantics, same shared instance (so preview and
    /// program stay frame-synchronized, and the animation composites stably
    /// above S09 transition blends).
    private var animated: AnimatedImagePlayback?
    private var loadTask: Task<Void, Never>?
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var endNotificationObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?

    init(sourceID: SourceDefinitionID,
         payloadProvider: @escaping @Sendable () -> MediaSourcePayload?) {
        self.sourceID = sourceID
        self.payloadProvider = payloadProvider
    }

    // MARK: - Loading

    /// Resolves the security-scoped bookmark and builds the player. No-op
    /// once loaded (or while a load is in flight).
    func load() {
        os_unfair_lock_lock(&lock)
        guard !didLoad, loadTask == nil else {
            os_unfair_lock_unlock(&lock)
            return
        }
        status.phase = .loading
        status.errorMessage = nil
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
        loadTask = Task { [weak self] in
            await self?.performLoad()
        }
    }

    private func performLoad() async {
        guard let payload = payloadProvider() else {
            fail("The media source has no registered payload — relink it to a video file.")
            return
        }
        guard let bookmark = payload.bookmarkData else {
            fail("No video file is linked — relink the source to an MP4/MOV file.")
            return
        }
        do {
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
            // G09 (issue #116): animated-image files dispatch to the
            // CGImageSource engine — the probe doubles as the load-time
            // unsupported-format gate (static/undecodable images fail here
            // with the explicit reason, never reaching program).
            if MediaOverlayClassifier.isAnimatedImageCandidate(url: url) {
                switch MediaOverlayClassifier.probeAnimatedImage(url: url) {
                case .failure(let error):
                    fail(error.message)
                case .success(let contents):
                    configureAnimated(contents: contents, bookmark: bookmark)
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
            // clips that have no video track (the frame pull simply never
            // produces pixels; the audio path is unchanged).
            guard hasVideo || hasAudio else {
                fail("\"\(url.lastPathComponent)\" has no audio or video track — sources need an AVFoundation-readable media file (MP4/MOV/ProRes/MP3/AAC/WAV/AIFF).")
                return
            }
            // `AVPlayerItem.init(asset:)` is MainActor-isolated, so the
            // player build hops to the main actor (transport and observer
            // callbacks live there anyway; only frame/audio pulls run on
            // the engine actors, through the nonisolated output APIs).
            await configure(asset: asset, bookmark: bookmark,
                            duration: duration,
                            audioTrack: tracks.first(where: { $0.mediaType == .audio }))
        } catch {
            fail("The video file could not be opened: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func configure(asset: AVAsset, bookmark: Data,
                           duration: CMTime, audioTrack: AVAssetTrack?) {
        os_unfair_lock_lock(&lock)
        self.asset = asset
        assetDuration = duration
        self.audioTrack = audioTrack
        loadedBookmark = bookmark
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
                self?.fail(item.error?.localizedDescription ?? "The video file failed to load.")
            }
        }
        endNotificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.handleReachedEnd()
        }
        // A trim-out short of the file's natural end is the same "reached
        // end" event for looping/end actions.
        if CMTimeCompare(trimOut, duration) < 0 {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: trimOut)], queue: .main
            ) { [weak self] in
                self?.handleReachedEnd()
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
        let shouldPlay = recovery.shouldPlay(autoplay: autoplay, requested: wantsPlay)
        let recoverySeek = recovery.consumePosition()
        os_unfair_lock_unlock(&lock)
        if let recoverySeek { pause(); seek(toSeconds: recoverySeek) }
        if shouldPlay { play() }
        os_unfair_lock_lock(&lock)
        loadTask = nil
        os_unfair_lock_unlock(&lock)
    }

    /// G09 (issue #116): loads an animated image into the CGImageSource
    /// engine. Transport/status plumbing is identical to the video path —
    /// the engine reports through the same `onStatus` mirror and honors the
    /// payload's loops/autoplay/end action live.
    private func configureAnimated(contents: AnimatedImageContents, bookmark: Data) {
        let engine = AnimatedImagePlayback(sourceID: sourceID,
                                           payloadProvider: payloadProvider)
        engine.onReachedEnd = { [weak self] id, time in self?.onReachedEnd?(id, time) }
        engine.onStatus = { [weak self] id, status in
            self?.onStatus?(id, status)
        }
        os_unfair_lock_lock(&lock)
        animated = engine
        loadedBookmark = bookmark
        didLoad = true
        status.phase = .ready
        status.positionSeconds = 0
        status.durationSeconds = contents.timeline.duration
        let autoplay = payloadProvider()?.autoplay ?? true
        let shouldPlay = recovery.shouldPlay(autoplay: autoplay, requested: wantsPlay)
        let recoverySeek = recovery.consumePosition()
        os_unfair_lock_unlock(&lock)
        engine.configure(contents: contents, autoplayHint: shouldPlay)
        if let recoverySeek { engine.pause(); engine.seek(toSeconds: recoverySeek); if shouldPlay { engine.play() } }
        os_unfair_lock_lock(&lock)
        loadTask = nil
        os_unfair_lock_unlock(&lock)
    }

    private func fail(_ message: String) {
        os_unfair_lock_lock(&lock)
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
        // A relink (the registry payload's bookmark changed) reloads the
        // file in place; no other source is disturbed.
        if didLoad, let bookmark = payloadProvider()?.bookmarkData,
           bookmark != loadedBookmark {
            teardownLocked()
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
        os_unfair_lock_unlock(&lock)
        for sample in audio {
            handler?(sample)
        }
        return frame
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
        var timing = CMSampleTimingInfo(duration: sample.duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sample,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    // MARK: - Transport

    /// Play. After ENDED this restarts from the trim-in point (Ecamm-style:
    /// pressing play on a finished file replays it).
    func play() {
        os_unfair_lock_lock(&lock)
        recovery.playIntent()
        wantsPlay = true
        // G09: animated-image sources forward transport to their engine.
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.play()
            return
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
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.pause()
            return
        }
        guard let player else {
            os_unfair_lock_unlock(&lock)
            return
        }
        player.pause()
        isPlaying = false
        removePositionObserverLocked(player)
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
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.stop()
            return
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
        recovery.restartIntent()
        wantsPlay = true
        if let animated {
            os_unfair_lock_unlock(&lock)
            animated.restart()
            return
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
    private func handleReachedEnd() {
        os_unfair_lock_lock(&lock)
        guard !isEnding, isPlaying, let player else {
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

    /// The 0.5 s position observer exists only while PLAYING (paused/ended
    /// sources report position on transport events) — no always-on timers.
    private func addPositionObserverLocked(_ player: AVPlayer) {
        guard periodicObserver == nil else { return }
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.notePosition(time)
        }
    }

    private func removePositionObserverLocked(_ player: AVPlayer) {
        if let periodicObserver {
            player.removeTimeObserver(periodicObserver)
        }
        periodicObserver = nil
    }

    private func notePosition(_ time: CMTime) {
        os_unfair_lock_lock(&lock)
        guard time.isNumeric else {
            os_unfair_lock_unlock(&lock)
            return
        }
        status.positionSeconds = time.seconds
        publishStatusLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Teardown

    /// Drops the current file (relink): every observer and reader goes, the
    /// held frame clears, and the next pull re-loads from the new bookmark.
    private func teardownLocked() {
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
        player = nil
        playerItem = nil
        videoOutput = nil
        asset = nil
        assetDuration = .invalid
        audioTrack = nil
        lastVideoBuffer = nil
        isPlaying = false
        isEnding = false
        didLoad = false
        loadedBookmark = nil
        status.phase = .idle
        status.positionSeconds = 0
        status.durationSeconds = 0
        publishStatusLocked()
    }

    private func publishStatusLocked() {
        onStatus?(sourceID, status)
    }
}
