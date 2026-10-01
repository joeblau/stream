import Combine
import CoreImage
import CoreVideo
import StreamCore
import Vision
import os.lock

/// E03 (issue #164): the Vision person-segmentation runtime behind the
/// background blur/replacement effect.
///
/// CADENCE. Segmentation NEVER blocks the render tick. The renderer hands a
/// camera pixel buffer to `submit(...)` (non-blocking — a busy key drops the
/// submission, and a buffer already segmented is never re-submitted) and
/// blends `latestMask(for:)` when one is fresh. A missing, stale, or failed
/// mask composites the UNMODIFIED source: the clean passthrough fallback, and
/// the reason the output frame rate is preserved no matter what Vision does.
///
/// BUDGET. Every completed request's measured cost feeds a per-key
/// `SegmentationFrameGovernor` (StreamCore), which walks the effective
/// quality down (accurate → balanced → fast → suspended) past a sustained
/// overload and probes `.fast` again after a cooldown — the requested quality
/// in the settings is a ceiling, never a demand.
///
/// CAPABILITY. The static gate is `SegmentationCapabilityMatrix.current`
/// (pure derivation, tested in StreamCore): an unsupported OS or a device
/// whose slowest estimate can't fit half a frame disables submission
/// entirely — the UI reads the same matrix, so unsupported devices never get
/// an enable control. Runtime failures (Vision errors / empty results) are
/// counted per key; repeated failure marks the key unavailable with the
/// reason, and the renderer falls back to passthrough.
final class PersonSegmentationCoordinator: @unchecked Sendable {
    static let shared = PersonSegmentationCoordinator()

    /// The live per-source status the inspector surface polls (read-only).
    struct SourceStatus: Equatable, Sendable {
        /// A fresh mask exists — the effect is actually compositing.
        var isSegmenting = false
        /// The quality the governor is currently running (≤ the requested
        /// quality after a downgrade).
        var effectiveQuality: SegmentationQuality = .balanced
        /// The last measured Vision request cost, in milliseconds.
        var lastCostMs: Double = 0
        /// Passthrough fallback engaged: governor-suspended or key-level
        /// failure — the source renders unmodified.
        var isFallbackPassthrough = false
        /// Why segmentation stopped for this key (nil when healthy).
        var unavailableReason: String?
    }

    private struct KeyState {
        var governor: SegmentationFrameGovernor
        var inFlight = false
        /// Identity of the last submitted buffer (same capture frame ⇒ skip).
        var lastSubmittedBuffer: UnsafeMutableRawPointer?
        var latestMask: CVPixelBuffer?
        var maskProducedAt: UInt64 = 0
        var lastCostMs: Double = 0
        var consecutiveFailures = 0
        var unavailableReason: String?
    }

    /// A mask older than this no longer tracks the person (camera at 30 fps
    /// produces a fresh frame every ~33 ms; 250 ms ≈ 7 missed frames).
    static let maskFreshnessNanoseconds: UInt64 = 250_000_000
    /// Consecutive Vision failures before the key is declared unavailable
    /// (single misses — a briefly empty observation — stay passthrough).
    static let failureTolerance = 3

    private let queue = DispatchQueue(label: "stream.person-segmentation", qos: .userInitiated)
    private var lock = os_unfair_lock_s()
    private var states: [CaptureSourceKey: KeyState] = [:]
    /// The static capability gate (read by the renderer's submit path and
    /// the inspector's center alike).
    let capability: SegmentationCapabilityMatrix

    init(capability: SegmentationCapabilityMatrix = .current) {
        self.capability = capability
    }

    /// Non-blocking submission from the render tick. Drops the frame when the
    /// key is busy, suspended, or failed — cadence over freshness, always.
    func submit(_ buffer: CVPixelBuffer,
                for key: CaptureSourceKey,
                settings: BackgroundEffectSettings,
                frameIntervalMs: Double) {
        guard capability.isSupported, settings.isEnabled else { return }
        let pointer = Unmanaged.passUnretained(buffer).toOpaque()
        os_unfair_lock_lock(&lock)
        var state = states[key] ?? KeyState(
            governor: SegmentationFrameGovernor(requestedQuality: settings.quality))
        guard !state.inFlight,
              !state.governor.isSuspended,
              state.unavailableReason == nil,
              state.lastSubmittedBuffer != pointer else {
            states[key] = state
            os_unfair_lock_unlock(&lock)
            return
        }
        state.inFlight = true
        state.lastSubmittedBuffer = pointer
        let quality = state.governor.effectiveQuality
        states[key] = state
        os_unfair_lock_unlock(&lock)

        queue.async { [self] in
            let startedAt = DispatchTime.now()
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality.vnQualityLevel
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer)
            var mask: CVPixelBuffer?
            var failure: String?
            do {
                try handler.perform([request])
                mask = request.results?.first?.pixelBuffer
                if mask == nil { failure = "Vision returned no person-segmentation mask." }
            } catch {
                failure = "Vision segmentation failed: \(error.localizedDescription)"
            }
            let costMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000

            os_unfair_lock_lock(&lock)
            if var current = states[key] {
                current.inFlight = false
                current.lastCostMs = costMs
                if let mask {
                    current.latestMask = mask
                    current.maskProducedAt = DispatchTime.now().uptimeNanoseconds
                    current.consecutiveFailures = 0
                } else {
                    current.consecutiveFailures += 1
                    if current.consecutiveFailures >= Self.failureTolerance {
                        current.unavailableReason = failure ?? "Person segmentation is unavailable."
                    }
                }
                _ = current.governor.record(costMs: costMs, frameIntervalMs: frameIntervalMs)
                states[key] = current
            }
            os_unfair_lock_unlock(&lock)
        }
    }

    /// The latest mask for blending, or nil — the renderer's cue to composite
    /// the source UNMODIFIED (stale masks would cut the wrong silhouette).
    func latestMask(for key: CaptureSourceKey) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let state = states[key],
              let mask = state.latestMask,
              DispatchTime.now().uptimeNanoseconds - state.maskProducedAt
                < Self.maskFreshnessNanoseconds else { return nil }
        return mask
    }

    /// The live status of one key (defaults when the key never segmented).
    func status(for key: CaptureSourceKey) -> SourceStatus {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let state = states[key] else { return SourceStatus() }
        let maskFresh = state.latestMask != nil
            && DispatchTime.now().uptimeNanoseconds - state.maskProducedAt
                < Self.maskFreshnessNanoseconds
        return SourceStatus(
            isSegmenting: maskFresh,
            effectiveQuality: state.governor.effectiveQuality,
            lastCostMs: state.lastCostMs,
            isFallbackPassthrough: state.governor.isSuspended || state.unavailableReason != nil,
            unavailableReason: state.unavailableReason)
    }
}

extension SegmentationQuality {
    /// The Vision quality level this value maps to (public API).
    var vnQualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}

extension SegmentationCapabilityMatrix {
    /// This Mac's matrix, derived once from live `ProcessInfo` signals. The
    /// target frame rate is 60 — the app's ceiling — so the recommendation is
    /// conservative at lower output frame rates.
    static let current = evaluate(
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        processorCount: ProcessInfo.processInfo.processorCount,
        physicalMemory: ProcessInfo.processInfo.physicalMemory,
        targetFrameRate: 60)
}

/// The inspector's read-only surface for E03 (the `CameraControlCenter`
/// precedent — owned by the dispatcher so UI and future automation share one
/// instance). No mutations flow through here: effect settings ride E01's
/// existing `setLayerSourceEffects` / `setSourceEffectDefaults` commands.
@MainActor
final class BackgroundEffectsCenter: ObservableObject {
    @Published private(set) var capability: SegmentationCapabilityMatrix
    @Published private(set) var statuses: [CaptureSourceKey: PersonSegmentationCoordinator.SourceStatus] = [:]

    private let coordinator: PersonSegmentationCoordinator

    init(coordinator: PersonSegmentationCoordinator = .shared) {
        self.coordinator = coordinator
        self.capability = coordinator.capability
    }

    /// Re-reads the capability and the statuses of the keys the view asks
    /// about. Called on appear and on the section's slow refresh timer (the
    /// CameraControlsSectionView pattern), never per frame.
    func refresh(keys: Set<CaptureSourceKey>) {
        capability = coordinator.capability
        var next: [CaptureSourceKey: PersonSegmentationCoordinator.SourceStatus] = [:]
        for key in keys {
            let status = coordinator.status(for: key)
            if status.isSegmenting || status.isFallbackPassthrough || status.unavailableReason != nil {
                next[key] = status
            }
        }
        if next != statuses { statuses = next }
    }
}
