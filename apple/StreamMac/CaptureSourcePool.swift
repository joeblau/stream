import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import StreamCore
import os.lock

/// The physical identity of one capture source, derived from a source
/// definition's payload (or an unbound layer's inline payload). Two layers
/// referencing the same camera device or display produce the SAME key, which
/// is what lets the pool run one capture for any number of layers.
enum CaptureSourceKey: Hashable, Sendable {
    case camera(CameraSourcePayload)
    case screen(ScreenSourcePayload)

    /// The system-default camera (no pinned device).
    static let defaultCamera = CaptureSourceKey.camera(CameraSourcePayload())
    /// The system-picker screen source (no pinned display/window).
    static let defaultScreen = CaptureSourceKey.screen(ScreenSourcePayload())

    /// True when nothing about the key pins a concrete device/display.
    var isDefaultSource: Bool {
        switch self {
        case .camera(let payload): return payload.deviceID == nil
        case .screen(let payload): return payload.targetIdentifier == nil
        }
    }
}

extension CaptureSourceKey {
    /// The physical captures the union of `program` and `staged` needs RIGHT
    /// NOW: every visible camera/screen layer resolves to one key. A layer
    /// bound to a registry `SourceDefinition` takes the DEFINITION's payload —
    /// the registry is the identity authority, so reconfiguring a source
    /// re-keys its capture — while unbound layers fall back to their inline
    /// payload (the render authority). Payload kinds without a physical
    /// capture (image/text/media/web/guest/…) produce no key.
    ///
    /// S06 seam: nested-scene layers (`.scene` payloads) are expanded by the
    /// caller graph walker before/instead of calling this — this function is
    /// the single place that turns "layers" into "captures to keep alive".
    static func demanded(program: Scene?,
                         staged: Scene?,
                         sources: [SourceDefinition]) -> Set<CaptureSourceKey> {
        var keys = Set<CaptureSourceKey>()
        for scene in [program, staged] {
            guard let scene else { continue }
            for layer in scene.layers where layer.isVisible {
                let payload = layer.sourceID
                    .flatMap { id in sources.first(where: { $0.id == id }) }?.payload
                    ?? layer.payload
                switch payload {
                case .camera(let camera): keys.insert(.camera(camera))
                case .screen(let screen): keys.insert(.screen(screen))
                default: break
                }
            }
        }
        return keys
    }
}

/// Lock-protected, off-main-readable view of the pool's live latest-frame
/// holders. The composition engines pull "the" screen/camera frame through
/// here exactly as they pulled the single W03 holders; the pool (main actor)
/// replaces the holder arrays whenever a capture instance is created. Stopped
/// captures clear their holder, so a holder list never serves stale pixels.
final class SourceFrameProviders: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var screenHolders: [LatestScreenFrame] = []
    private var cameraHolders: [LatestCameraFrame] = []

    func update(screenHolders: [LatestScreenFrame], cameraHolders: [LatestCameraFrame]) {
        os_unfair_lock_lock(&lock)
        self.screenHolders = screenHolders
        self.cameraHolders = cameraHolders
        os_unfair_lock_unlock(&lock)
    }

    /// The newest frame from the first active screen capture (holders are
    /// ordered default-source-first, so the single-screen runtime stays
    /// deterministic as N-screen support lands behind it).
    func latestScreenFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let holders = screenHolders
        os_unfair_lock_unlock(&lock)
        for holder in holders {
            if let buffer = holder.latest() { return buffer }
        }
        return nil
    }

    /// The freshest frame from the first active camera capture.
    func freshestCameraFrame() -> LatestCameraFrame.Frame? {
        os_unfair_lock_lock(&lock)
        let holders = cameraHolders
        os_unfair_lock_unlock(&lock)
        for holder in holders {
            if let frame = holder.freshest() { return frame }
        }
        return nil
    }
}

/// Holds the newest screen frame for one screen capture. Unlike the pre-W08
/// destructive take, reads are non-destructive: the composition ticks at the
/// output fps using the LATEST sample (issue #65), so a static screen keeps
/// compositing — moving camera overlays included — without ScreenCaptureKit
/// producing fresh frames.
final class LatestScreenFrame: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?

    func store(_ buffer: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        self.buffer = buffer
        os_unfair_lock_unlock(&lock)
    }

    func latest() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return buffer
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        buffer = nil
        os_unfair_lock_unlock(&lock)
    }
}

/// The S05 capture registry runtime (issue #73): owns one physical capture
/// per `CaptureSourceKey` and starts/stops captures purely by demand —
/// "a capture runs iff ≥1 layer in the staged OR program scene references it".
///
/// Reconciliation is set-based and keyed by source identity, never by "the
/// camera"/"the screen":
/// - a key in both the current and new demand is left RUNNING — a Take
///   between two scenes sharing a camera never restarts that capture (no
///   flicker/black frames);
/// - a key newly in demand starts (first reference); a key leaving demand
///   stops (last reference removed) and its device is released;
/// - N distinct cameras/displays are supported structurally: each key owns an
///   independent `FacecamCapture` / `ScreenSourceCapture` with its own
///   latest-frame holder. The composition engines still consume a single
///   screen/camera frame (default-source-first, deterministic), which keeps
///   the current single-camera/single-screen behavior bit-identical while
///   the source-adding UI arrives.
///
/// Failure surface: `sourceErrors` carries the last start failure per source
/// (screen capture errors are mirrored live, including mid-capture stops;
/// camera permission denials are pre-flighted) so the UI can badge individual
/// sources later.
@MainActor
final class CaptureSourcePool: ObservableObject {
    /// The last start/run failure per source identity, for future per-source
    /// UI badges. Cleared per source on a successful (re)start.
    @Published private(set) var sourceErrors: [CaptureSourceKey: String] = [:]
    /// Sources whose capture is delivering frames right now. Cameras report
    /// optimistically at start (their frames age out via `LatestCameraFrame`
    /// if the device never delivers); screens report from `isCapturing`.
    @Published private(set) var activeSources: Set<CaptureSourceKey> = []

    /// The engines' off-main frame read path (see `SourceFrameProviders`).
    let frames = SourceFrameProviders()
    /// App/mic audio from every screen capture; the controller routes this to
    /// the publisher's ordered ingress.
    var onScreenAudioSample: (@Sendable (CMSampleBuffer) -> Void)?

    /// Keys a start was requested for and not yet stopped. This — not
    /// `activeSources` — is what reconciliation diffs against, so an
    /// in-flight picker or a user-cancelled picker isn't re-presented until
    /// the source is genuinely unreferenced and re-referenced.
    private var requested: Set<CaptureSourceKey> = []
    private var cameras: [CaptureSourceKey: FacecamCapture] = [:]
    private var screens: [CaptureSourceKey: ScreenSourceCapture] = [:]
    private var screenFrames: [CaptureSourceKey: LatestScreenFrame] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Demand reconciliation

    /// Diffs the scene-derived demand against the running set: starts first
    /// references, stops last references, and leaves shared captures
    /// untouched.
    func reconcile(demand rawDemand: Set<CaptureSourceKey>, settings: StreamSettings) {
        let demand = Set(rawDemand.map(normalized(_:)))
        for key in demand.subtracting(requested) {
            start(key, settings: settings)
        }
        for key in requested.subtracting(demand) {
            stop(key)
        }
    }

    /// Stops every capture (pipeline demand hit 0). Instances and their
    /// remembered selections survive, so the next pipeline run restarts
    /// without re-prompting; the error surface resets for the fresh run.
    func stopAll() {
        for key in requested { stop(key) }
        sourceErrors = [:]
    }

    /// The capture instance for a screen key, created (and wired) on first
    /// use and stable thereafter — `StreamController.screenCapture` forwards
    /// here so existing reads keep working.
    func screenCapture(for key: CaptureSourceKey) -> ScreenSourceCapture {
        if let existing = screens[key] { return existing }
        let capture = ScreenSourceCapture()
        let holder = LatestScreenFrame()
        screens[key] = capture
        screenFrames[key] = holder
        capture.onVideoSample = { [holder] sample in
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                holder.store(buffer)
            }
        }
        capture.onAudioSample = { [weak self] sample in
            self?.onScreenAudioSample?(sample)
        }
        // Mirror the capture's own state into the per-source surface: errors
        // (permission denial, start failure, mid-capture stop) badge the
        // source; a clean user cancel leaves no error.
        capture.$isCapturing.sink { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture else { return }
                if capture.isCapturing {
                    self.activeSources.insert(key)
                    self.sourceErrors[key] = nil
                } else {
                    self.activeSources.remove(key)
                    if let message = capture.errorMessage {
                        self.sourceErrors[key] = message
                    }
                }
            }
        }.store(in: &cancellables)
        publishFrameHolders()
        return capture
    }

    // MARK: - Start / stop

    private func start(_ key: CaptureSourceKey, settings: StreamSettings) {
        requested.insert(key)
        switch key {
        case .camera(let payload):
            // Pre-flight the permission so a denied camera surfaces a
            // per-source error instead of silently rendering black.
            // `.notDetermined` passes through: FacecamCapture presents the
            // system prompt itself on first start.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted:
                sourceErrors[key] = "Camera access is disabled for StreamMac. Enable it in System Settings > Privacy & Security > Camera."
                return
            default:
                break
            }
            sourceErrors[key] = nil
            let camera = cameras[key] ?? makeCamera(for: key)
            camera.start(with: settings, deviceUniqueID: payload.deviceID)
            activeSources.insert(key)
        case .screen(let payload):
            sourceErrors[key] = nil
            let capture = screenCapture(for: key)
            Task { [weak capture] in
                guard let capture else { return }
                if payload.targetIdentifier != nil {
                    await capture.start(matching: payload)
                } else {
                    await capture.pickAndStart()
                }
            }
        }
    }

    private func stop(_ key: CaptureSourceKey) {
        requested.remove(key)
        activeSources.remove(key)
        switch key {
        case .camera:
            // Asynchronous on the capture's own queue; clears its frame holder.
            cameras[key]?.stop()
        case .screen:
            screenFrames[key]?.clear()
            if let capture = screens[key] {
                Task { await capture.stop() }
            }
        }
    }

    private func makeCamera(for key: CaptureSourceKey) -> FacecamCapture {
        let camera = FacecamCapture()
        cameras[key] = camera
        publishFrameHolders()
        return camera
    }

    /// Hands the engines the live holder set, default (unpinned) sources
    /// first so the single-path providers prefer the primary capture.
    private func publishFrameHolders() {
        let orderedScreens = screens.keys.sorted {
            ($0.isDefaultSource ? 0 : 1) < ($1.isDefaultSource ? 0 : 1)
        }
        let orderedCameras = cameras.keys.sorted {
            ($0.isDefaultSource ? 0 : 1) < ($1.isDefaultSource ? 0 : 1)
        }
        frames.update(
            screenHolders: orderedScreens.compactMap { screenFrames[$0] },
            cameraHolders: orderedCameras.compactMap { cameras[$0]?.latest })
    }

    /// Collapses keys that name the SAME physical device the default source
    /// already covers, so "the default camera" and "the default camera by
    /// unique ID" never open the device twice.
    private func normalized(_ key: CaptureSourceKey) -> CaptureSourceKey {
        guard case .camera(let payload) = key, let deviceID = payload.deviceID,
              let defaultDevice = AVCaptureDevice.default(for: .video),
              defaultDevice.uniqueID == deviceID else { return key }
        return .camera(CameraSourcePayload())
    }
}
