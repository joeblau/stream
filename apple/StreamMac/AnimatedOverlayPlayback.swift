import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import os.lock
import StreamCore
import UniformTypeIdentifiers

/// G09 (issue #116): animated-image (GIF / APNG / animated HEIC) and
/// alpha-video (ProRes 4444 / HEVC-with-alpha) overlay playback.
///
/// **Why a second engine.** `MediaSourcePlayback` (A02) is AVFoundation
/// pull-based playout; animated images have no AVAsset representation, so
/// they get their own engine here with the SAME discipline: frames are
/// PULLED by the composition engines' render tick (`pullFrame`), timed off
/// the shared monotonic host clock (`CACurrentMediaTime`), with no timers
/// or runloops of its own. One engine instance feeds every composition
/// (preview and program pull identical frames through the pool), so overlay
/// animation stays synchronized through scene changes and composites —
/// stably — above the S09 transition blend. Transport (play/pause/stop/
/// restart/seek), the loops flag, and the HOLD/STOP end actions mirror the
/// A02 semantics exactly, so the existing transport UI drives both engines
/// unchanged.
///
/// **Format gating.** `MediaOverlayClassifier` probes picked files at
/// IMPORT time (the panel's file pickers) and at load time (the playback
/// dispatch), so an unsupported format — a static image, an undecodable
/// file, an opaque H.264 — is an explicit error before the asset ever
/// reaches program. The pure rules (type identifiers, codec fourCCs, frame
/// timing) live in StreamCore's `AnimatedImageTimeline` /
/// `MediaOverlayValidator` and are unit-tested there.
///
/// **Known limitation.** CGImageSource returns raw frames; GIF disposal
/// methods (partial-frame deltas) are NOT composited. Full-frame GIFs,
/// APNG, and animated HEIC — the overlay formats this issue targets —
/// render exactly.

/// The decoded-at-import description of one animated image: everything the
/// playback engine needs except the pixels (the CGImageSource is cheap to
/// recreate and is NOT Sendable, so it is built on the engine side).
struct AnimatedImageContents: Sendable {
    let fileURL: URL
    let timeline: AnimatedImageTimeline
    let pixelWidth: Int
    let pixelHeight: Int
    /// The container's UTI (e.g. `com.compuserve.gif`) — diagnostics.
    let typeIdentifier: String
}

/// Import-time probing for overlay media files (G09, issue #116): the
/// "report unsupported formats before the asset reaches program" gate. All
/// probes run on the caller's picked file while its security-scoped access
/// is held by the caller.
enum MediaOverlayClassifier {

    /// Is this URL even a candidate for animated-image playback (by
    /// extension/UTI)? `MediaSourcePlayback.performLoad` dispatches on this
    /// before building an AVAsset.
    static func isAnimatedImageCandidate(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return MediaOverlayValidator.isAnimatedImageTypeIdentifier(type.identifier)
    }

    /// Full animated-image probe: the container must be a supported type
    /// with at least two frames (the StreamCore validator owns the
    /// user-facing rejection reasons). On success the contents carry the
    /// clamped-delay timeline and the file's loop count.
    static func probeAnimatedImage(url: URL) -> Result<AnimatedImageContents, MediaOverlayFormatError> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failure(MediaOverlayFormatError("The image file could not be opened."))
        }
        let typeIdentifier = (CGImageSourceGetType(source) as String?)
            ?? UTType(filenameExtension: url.pathExtension.lowercased())?.identifier
        let frameCount = CGImageSourceGetCount(source)
        switch MediaOverlayValidator.validateAnimatedImage(typeIdentifier: typeIdentifier,
                                                           frameCount: frameCount) {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        var delays: [Double] = []
        delays.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            delays.append(frameDelay(source: source, index: index))
        }
        let loopCount = fileLoopCount(source: source)
        // Canvas = the file's declared pixel size (first frame properties);
        // frames are drawn centered/cleared into it, so alpha compositing is
        // exact even when individual frames differ in size.
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let width = (first?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let height = (first?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        guard width > 0, height > 0 else {
            return .failure(MediaOverlayFormatError("The image file declares no pixel dimensions."))
        }
        return .success(AnimatedImageContents(
            fileURL: url,
            timeline: AnimatedImageTimeline(rawFrameDelays: delays, loopCount: loopCount),
            pixelWidth: width,
            pixelHeight: height,
            typeIdentifier: typeIdentifier ?? "unknown"))
    }

    /// Alpha-video probe: the file must have a video track whose codec
    /// AVFoundation decodes WITH its alpha channel (ProRes 4444/4444XQ,
    /// HEVC-with-alpha) — anything else is rejected at import with the
    /// codec named, before it can composite opaque on program.
    static func probeAlphaVideo(url: URL) async -> Result<Void, MediaOverlayFormatError> {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            guard let video = tracks.first(where: { $0.mediaType == .video }) else {
                return MediaOverlayValidator.validateAlphaVideo(codecFourCC: nil)
            }
            let codec = try await videoCodecFourCC(of: video)
            return MediaOverlayValidator.validateAlphaVideo(codecFourCC: codec)
        } catch {
            return .failure(MediaOverlayFormatError(
                "The video file could not be opened: \(error.localizedDescription)"))
        }
    }

    /// The video track's codec fourCC (`ap4h`, `avc1`, `hvt1`, …) from its
    /// format descriptions, or nil when the track carries none.
    static func videoCodecFourCC(of track: AVAssetTrack) async throws -> String? {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else { return nil }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(description)
        var fourCC = mediaSubType.bigEndian
        let bytes = withUnsafeBytes(of: &fourCC) { Data($0) }
        return String(data: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - ImageIO property reads

    /// One frame's raw delay: the unclamped delay when present, else the
    /// clamped one, searched across the GIF/PNG(APNG)/HEICS property
    /// dictionaries (clamping itself is the timeline's job). The APNG
    /// dictionary key is a literal: ImageIO exposes APNG properties under
    /// the PNG dictionary on some SDKs, and the `kCGImagePropertyAPNG…`
    /// constants are not available everywhere.
    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        else { return 0 }
        for dictionaryKey in [kCGImagePropertyGIFDictionary as String,
                              kCGImagePropertyPNGDictionary as String,
                              "{APNG}",
                              kCGImagePropertyHEICSDictionary as String] {
            guard let dictionary = properties[dictionaryKey] as? [String: Any] else { continue }
            if let unclamped = dictionary["UnclampedDelayTime"] as? Double { return unclamped }
            if let delay = dictionary["DelayTime"] as? Double { return delay }
        }
        return 0
    }

    /// The file-level repeat budget: a stored count of 0 (or no loop block)
    /// is infinite by GIF convention; N means N replays after the first
    /// pass (`AnimatedImageLoopCount.finite`).
    private static func fileLoopCount(source: CGImageSource) -> AnimatedImageLoopCount {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        else { return .infinite }
        for dictionaryKey in [kCGImagePropertyGIFDictionary as String,
                              kCGImagePropertyPNGDictionary as String,
                              "{APNG}",
                              kCGImagePropertyHEICSDictionary as String] {
            guard let dictionary = properties[dictionaryKey] as? [String: Any],
                  let stored = dictionary["LoopCount"] as? Int else { continue }
            return stored > 0 ? .finite(storedCount: stored) : .infinite
        }
        return .infinite
    }
}

/// G09 (issue #116): the pull-based playback engine for ONE animated-image
/// overlay source. `MediaSourcePlayback` dispatches image files here and
/// forwards transport; everything else (status publishing, pool lifecycle,
/// registry identity) is the A02 machinery unchanged.
///
/// **Clock.** The playhead is `baseElapsed + (now − startHostTime)` on the
/// monotonic host clock, read on each `pullFrame` — the render tick is the
/// cadence, so looping GIFs can never drift from the composition the way a
/// timer-driven player would. `AnimatedImageTimeline` (StreamCore) owns the
/// index math; this class owns pixels and transport.
final class AnimatedImagePlayback: MediaFrameSource, @unchecked Sendable {
    let sourceID: SourceDefinitionID
    /// Live payload reads: loops/end action take effect at the next end of
    /// the current pass, exactly like the A02 video path.
    private let payloadProvider: @Sendable () -> MediaSourcePayload?
    /// Status mirror for the transport UI (wired by `MediaSourcePlayback`,
    /// which forwards the pool's callback). Fired off the engine lock.
    var onStatus: (@Sendable (SourceDefinitionID, MediaSourceStatus) -> Void)?

    private var lock = os_unfair_lock_s()
    private var imageSource: CGImageSource?
    /// The timeline honoring the FILE's loop count, used while the payload's
    /// loops flag is on.
    private var fileTimeline: AnimatedImageTimeline?
    /// The same frames constrained to exactly one pass, used while the
    /// payload's loops flag is off (play-once, then the end action).
    private var onceTimeline: AnimatedImageTimeline?
    private var pixelWidth = 0
    private var pixelHeight = 0
    /// Rendered-frame cache by frame index — an animated overlay repaints
    /// the same few dozen buffers, so each frame is rasterized once.
    private var frameBuffers: [Int: CVPixelBuffer] = [:]
    /// The buffer the last pull produced (the paused/ended hold frame).
    private var heldBuffer: CVPixelBuffer?
    private var status = MediaSourceStatus()
    private var isPlaying = false
    /// Play requested before the contents were configured; honored (with
    /// autoplay) at the end of `configure`.
    private var wantsPlay = false
    private var didLoad = false
    /// Host-clock anchor: `play()` stamps it; the playhead reads
    /// `baseElapsed + (CACurrentMediaTime() − startHostTime)` while playing.
    private var startHostTime: CFTimeInterval = 0
    /// Accumulated playhead seconds at the last play/seek/stop.
    private var baseElapsed = 0.0
    /// Reentrancy guard: end handling runs once per pass end.
    private var isEnding = false
    /// Status publishing is throttled to 0.5 s steps (the A02 transport
    /// cadence) — `pullFrame` runs per render tick.
    private var lastPublishedPosition = -1.0

    init(sourceID: SourceDefinitionID,
         payloadProvider: @escaping @Sendable () -> MediaSourcePayload?) {
        self.sourceID = sourceID
        self.payloadProvider = payloadProvider
    }

    // MARK: - Loading

    /// Configures the engine from a probed file (the caller holds the
    /// security-scoped access for the session, like the A02 video path).
    /// The CGImageSource is created here — it is not Sendable, so the probe
    /// ships value contents only.
    func configure(contents: AnimatedImageContents, autoplayHint: Bool?) {
        guard let source = CGImageSourceCreateWithURL(contents.fileURL as CFURL, nil) else {
            fail("The image file could not be reopened for playback.")
            return
        }
        os_unfair_lock_lock(&lock)
        imageSource = source
        fileTimeline = contents.timeline
        onceTimeline = AnimatedImageTimeline(rawFrameDelays: contents.timeline.frameDelays,
                                             loopCount: .finite(storedCount: 0))
        pixelWidth = contents.pixelWidth
        pixelHeight = contents.pixelHeight
        frameBuffers = [:]
        heldBuffer = nil
        didLoad = true
        isPlaying = false
        isEnding = false
        baseElapsed = 0
        status.phase = .ready
        status.positionSeconds = 0
        status.durationSeconds = contents.timeline.duration
        status.errorMessage = nil
        publishLocked()
        let shouldPlay = (autoplayHint ?? true) || wantsPlay
        os_unfair_lock_unlock(&lock)
        if shouldPlay { play() }
    }

    private func fail(_ message: String) {
        os_unfair_lock_lock(&lock)
        isPlaying = false
        status.phase = .error
        status.errorMessage = message
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Frame pulling (composition engine tick)

    /// The timeline the CURRENT payload policy plays against: loops on →
    /// the file's own loop count (infinite included); loops off → exactly
    /// one pass, then the end action. Read live per pull, so a loop-toggle
    /// edit takes effect at the next pass without restarting playback.
    private func activeTimelineLocked() -> AnimatedImageTimeline? {
        (payloadProvider()?.loops ?? true) ? fileTimeline : onceTimeline
    }

    /// The per-tick read: the frame for the CURRENT playhead position, plus
    /// end-of-animation handling (loop wrap is inside the timeline math;
    /// exhausted budgets apply the payload's HOLD/STOP end action here). A
    /// stopped/errored source returns nil — the renderer's paint-nothing
    /// fallback; pause and HOLD keep serving the held frame.
    func pullFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        guard didLoad, let timeline = activeTimelineLocked() else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        if isPlaying {
            let elapsed = currentElapsedLocked()
            switch timeline.placement(atElapsed: elapsed) {
            case .frame(let index):
                if let buffer = renderFrameLocked(index) {
                    heldBuffer = buffer
                }
                notePositionLocked(elapsed)
            case .ended:
                handleEndedLocked()
            }
        }
        let frame = heldBuffer
        os_unfair_lock_unlock(&lock)
        return frame
    }

    /// The playhead in seconds: anchored accumulation, never a step counter,
    /// so a paused→resumed overlay resumes exactly where it held.
    private func currentElapsedLocked() -> Double {
        guard isPlaying else { return baseElapsed }
        return baseElapsed + (CACurrentMediaTime() - startHostTime)
    }

    /// The active timeline's budget is exhausted (finite file loop count,
    /// or play-once with loops off): HOLD freezes the last frame, STOP
    /// rewinds and clears to the paint-nothing fallback. A loops/end-action
    /// edit takes effect at the NEXT end — replay comes from transport.
    private func handleEndedLocked() {
        guard !isEnding else { return }
        isEnding = true
        isPlaying = false
        switch payloadProvider()?.endAction ?? .hold {
        case .hold:
            status.phase = .ended
        case .stop:
            heldBuffer = nil
            baseElapsed = 0
            status.phase = .ready
            status.positionSeconds = 0
        }
        publishLocked()
    }

    // MARK: - Transport (mirrors MediaSourcePlayback semantics)

    /// Play. After ENDED this restarts from the beginning (the A02
    /// press-play-on-a-finished-file replay).
    func play() {
        os_unfair_lock_lock(&lock)
        wantsPlay = true
        guard didLoad else {
            os_unfair_lock_unlock(&lock)
            return
        }
        if status.phase == .ended {
            baseElapsed = 0
        }
        startHostTime = CACurrentMediaTime()
        isEnding = false
        isPlaying = true
        status.phase = .playing
        status.errorMessage = nil
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Pause mid-animation — the held frame keeps painting (also the pool's
    /// demand-loss behavior: position holds for the next reference).
    func pause() {
        os_unfair_lock_lock(&lock)
        guard didLoad, isPlaying else {
            os_unfair_lock_unlock(&lock)
            return
        }
        baseElapsed = currentElapsedLocked()
        isPlaying = false
        if status.phase == .playing {
            status.phase = .paused
        }
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Stop: rewind AND clear the held frame — the renderer's paint-nothing
    /// fallback, matching the STOP end action.
    func stop() {
        os_unfair_lock_lock(&lock)
        guard didLoad else {
            os_unfair_lock_unlock(&lock)
            return
        }
        isPlaying = false
        isEnding = false
        baseElapsed = 0
        heldBuffer = nil
        status.phase = .ready
        status.positionSeconds = 0
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Restart: back to the first frame and playing.
    func restart() {
        os_unfair_lock_lock(&lock)
        wantsPlay = true
        guard didLoad else {
            os_unfair_lock_unlock(&lock)
            return
        }
        isEnding = false
        baseElapsed = 0
        startHostTime = CACurrentMediaTime()
        isPlaying = true
        status.phase = .playing
        status.positionSeconds = 0
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Seek to an absolute position in seconds (clamped to the pass).
    func seek(toSeconds seconds: Double) {
        os_unfair_lock_lock(&lock)
        guard didLoad, let timeline = activeTimelineLocked(), seconds.isFinite else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let clamped = min(max(0, seconds), timeline.duration)
        baseElapsed = clamped
        startHostTime = CACurrentMediaTime()
        isEnding = false
        // The scrubbed frame paints immediately even while paused.
        if case .frame(let index) = timeline.placement(atElapsed: clamped),
           let buffer = renderFrameLocked(index) {
            heldBuffer = buffer
        }
        if status.phase == .ended {
            status.phase = .paused
        }
        status.positionSeconds = clamped
        publishLocked()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Rasterization

    /// Rasterizes one frame into a 32BGRA pixel buffer (cached by index).
    /// The buffer is cleared first, so the file's alpha composites exactly
    /// through the renderer's CIImage path (premultiplied-first, matching
    /// the A02 video output's pixel format).
    private func renderFrameLocked(_ index: Int) -> CVPixelBuffer? {
        if let cached = frameBuffers[index] { return cached }
        guard let imageSource,
              let image = CGImageSourceCreateImageAtIndex(imageSource, index, nil),
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, pixelWidth, pixelHeight,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // CGImageSource frames carry their own pixel size; draw into the
        // file canvas so mixed-size frames stay registered.
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: min(image.width, pixelWidth),
                                       height: min(image.height, pixelHeight)))
        frameBuffers[index] = buffer
        return buffer
    }

    // MARK: - Status

    private func notePositionLocked(_ elapsed: Double) {
        status.positionSeconds = elapsed
        // 0.5 s publish steps — the A02 position-observer cadence — so the
        // per-tick pull never floods the transport UI.
        if abs(elapsed - lastPublishedPosition) >= 0.5 {
            lastPublishedPosition = elapsed
            publishLocked()
        }
    }

    private func publishLocked() {
        let snapshot = status
        let handler = onStatus
        let id = sourceID
        // Fire off-lock: observers (the pool) hop actors and must never
        // reenter the engine (the A02 observer rule).
        DispatchQueue.main.async { handler?(id, snapshot) }
    }
}
