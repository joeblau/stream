import Foundation

/// G09 (issue #116): the pure timing math behind animated-image overlay
/// playback (GIF / APNG / animated HEIC). The StreamMac playback engine
/// (`AnimatedImagePlayback`) decodes frames with CGImageSource and feeds
/// their per-frame delays and the file's loop count here; everything that
/// decides WHICH frame shows at a given playhead position — delay clamping,
/// loop wrapping, finite-repeat end detection — is plain value math, so it
/// lives in StreamCore and is unit-tested without ImageIO.

/// How many times an animated image plays through its frames.
public enum AnimatedImageLoopCount: Equatable, Sendable {
    /// GIF/APNG loop count 0 (or no loop block): repeat forever.
    case infinite
    /// A finite repeat budget. GIF's NETSCAPE count N means N replays after
    /// the first pass, so the total pass count is N + 1 (the browser
    /// interpretation). The caller maps the FILE's stored value: a stored 0
    /// (or missing loop block) is `.infinite` by GIF convention, never
    /// `.finite(storedCount: 0)` — that spelling means "play exactly once"
    /// and is how a payload's loops=off maps in.
    case finite(storedCount: Int)

    /// Total passes through the frame list, nil for infinite.
    public var totalPasses: Int? {
        switch self {
        case .infinite: return nil
        case .finite(let storedCount): return max(1, storedCount + 1)
        }
    }
}

/// Where a playhead position lands on an animated-image timeline.
public enum AnimatedImagePlacement: Equatable, Sendable {
    /// Show `index` (0-based into the frame list).
    case frame(Int)
    /// The finite repeat budget is exhausted — the caller applies its end
    /// action (hold the last frame / clear), never this type.
    case ended
}

/// One animated image's frame-stepping timeline: clamped per-frame delays,
/// one pass duration, and loop wrap / end detection. All times in seconds.
public struct AnimatedImageTimeline: Equatable, Sendable {
    /// Per-frame display delays AFTER clamping (`clampedDelay`).
    public let frameDelays: [Double]
    public let loopCount: AnimatedImageLoopCount

    /// Cumulative start time of each frame (frame i shows in
    /// `[starts[i], starts[i+1])`); `starts[count]` is the pass duration.
    private let starts: [Double]

    /// The GIF-spec delay floor: a delay of 0–10 ms is historically a
    /// decoder artifact and browsers clamp it to 100 ms; honoring that keeps
    /// GIFs authored without delays from strobing at render fps.
    public static let minimumDelay = 0.1

    /// Clamps one raw frame delay the way browsers treat GIF/APNG delays
    /// (≤ 10 ms → 100 ms); negative or non-finite values clamp too.
    public static func clampedDelay(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0.01 else { return minimumDelay }
        return raw
    }

    /// Builds the timeline from raw per-frame delays. An empty frame list is
    /// rejected by the caller (a non-animated image is an import error), but
    /// a defensive empty timeline simply reports `ended` for every query.
    public init(rawFrameDelays: [Double], loopCount: AnimatedImageLoopCount) {
        let clamped = rawFrameDelays.map(Self.clampedDelay)
        self.frameDelays = clamped
        self.loopCount = loopCount
        var starts = [Double]()
        starts.reserveCapacity(clamped.count + 1)
        var cursor = 0.0
        starts.append(cursor)
        for delay in clamped {
            cursor += delay
            starts.append(cursor)
        }
        self.starts = starts
    }

    /// Duration of ONE pass through every frame in seconds.
    public var duration: Double { starts.last ?? 0 }

    /// The frame showing at `elapsed` seconds past playback start, or
    /// `ended` once a finite loop budget is exhausted. Infinite loops wrap
    /// by the pass duration, so the SAME position math serves preview and
    /// program ticks identically (one shared playhead, no drift).
    public func placement(atElapsed elapsed: Double) -> AnimatedImagePlacement {
        guard !frameDelays.isEmpty, duration > 0 else { return .ended }
        guard elapsed.isFinite, elapsed >= 0 else { return .frame(0) }
        let pass = elapsed / duration
        if let totalPasses = loopCount.totalPasses, pass >= Double(totalPasses) {
            return .ended
        }
        let withinPass = elapsed.truncatingRemainder(dividingBy: duration)
        return .frame(frameIndex(atTimeInPass: withinPass))
    }

    /// The index of the frame showing at `time` seconds into one pass.
    public func frameIndex(atTimeInPass time: Double) -> Int {
        guard !frameDelays.isEmpty else { return 0 }
        // Linear scan: animated overlays are tens of frames, and the scan
        // keeps the math obviously correct (binary search buys nothing).
        var index = 0
        while index + 1 < frameDelays.count, starts[index + 1] <= time {
            index += 1
        }
        return index
    }

    /// Seconds elapsed at the start of `index`'s frame — the seek target
    /// for scrubbing to a frame.
    public func elapsed(atFrameIndex index: Int) -> Double {
        guard !starts.isEmpty else { return 0 }
        return starts[min(max(0, index), starts.count - 1)]
    }
}

// MARK: - Import-time format classification

/// G09 (issue #116): which overlay media flavor a picked file is. The
/// classifier decides BEFORE the asset is registered (the unsupported-format
/// report surfaces at import/config time, never on program).
public enum MediaOverlayAssetKind: String, Equatable, Sendable {
    /// GIF / APNG / animated HEIC — CGImageSource frame-stepped playback.
    case animatedImage
    /// ProRes 4444/4444XQ or HEVC-with-alpha — AVFoundation playback with
    /// the alpha channel preserved.
    case alphaVideo
    /// Any other AVFoundation-readable video (plays like an A02 media
    /// source; no alpha guarantee).
    case video
}

/// An import-time rejection with a user-facing reason.
public struct MediaOverlayFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Pure classification rules for overlay media: UTType identifier strings
/// and codec fourCCs in, supported/unsupported out. ImageIO/AVFoundation
/// probing stays in the StreamMac caller; these rules are the testable core.
public enum MediaOverlayValidator {
    /// Uniform type identifiers whose files can carry frame-stepped
    /// animation (GIF, PNG→APNG, HEIC/HEIF sequences).
    public static let animatedImageTypeIdentifiers: Set<String> = [
        "com.compuserve.gif",
        "public.png",
        "public.heic",
        "public.heif",
        "org.webmproject.webp",
    ]

    /// Video codec fourCCs that carry an alpha channel through
    /// AVFoundation's 32BGRA decode path: ProRes 4444 (`ap4h`), ProRes
    /// 4444 XQ (`ap4x`), and HEVC with alpha (`hvt1`).
    public static let alphaVideoCodecs: Set<String> = ["ap4h", "ap4x", "hvt1"]

    /// Can this type identifier even be an animated image? (Frame COUNT is
    /// probed separately with ImageIO — a static PNG is a valid type but a
    /// one-frame "animation".)
    public static func isAnimatedImageTypeIdentifier(_ identifier: String) -> Bool {
        animatedImageTypeIdentifiers.contains(identifier)
    }

    /// Import gate for the Animated Image add path: the picked file must be
    /// a supported image type with at least two frames — a static image or
    /// an unreadable file is rejected here, before it reaches any scene.
    public static func validateAnimatedImage(typeIdentifier: String?,
                                             frameCount: Int) -> Result<Void, MediaOverlayFormatError> {
        guard let typeIdentifier, isAnimatedImageTypeIdentifier(typeIdentifier) else {
            return .failure(MediaOverlayFormatError(
                "Unsupported animated-image format — pick a GIF, APNG, or animated HEIC file."))
        }
        guard frameCount > 0 else {
            return .failure(MediaOverlayFormatError(
                "The image file could not be decoded (no frames)."))
        }
        guard frameCount > 1 else {
            return .failure(MediaOverlayFormatError(
                "This image has a single frame — animated overlays need a GIF, APNG, or animated HEIC with at least two frames."))
        }
        return .success(())
    }

    /// Does this codec fourCC carry alpha through the decode path?
    public static func isAlphaVideoCodec(_ fourCC: String) -> Bool {
        alphaVideoCodecs.contains(fourCC)
    }

    /// Import gate for the Alpha Video add path: the file's video codec
    /// must be one AVFoundation decodes WITH its alpha channel, so a
    /// flattened H.264 is rejected at import rather than compositing opaque
    /// on program.
    public static func validateAlphaVideo(codecFourCC: String?) -> Result<Void, MediaOverlayFormatError> {
        guard let codecFourCC else {
            return .failure(MediaOverlayFormatError(
                "The file has no video track — alpha overlays need a ProRes 4444 or HEVC-with-alpha video."))
        }
        guard isAlphaVideoCodec(codecFourCC) else {
            return .failure(MediaOverlayFormatError(
                "Codec \"\(codecFourCC)\" has no alpha channel — alpha overlays need ProRes 4444/4444XQ or HEVC with alpha."))
        }
        return .success(())
    }
}
