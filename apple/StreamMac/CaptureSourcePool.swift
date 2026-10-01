import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
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
    /// S06: callers flatten nested-scene references first
    /// (`SceneGraph.flattenedVisibleLayers` — cycle-guarded), so a camera
    /// used ONLY inside a nested scene still demands its capture. The
    /// layer-list overload below is the single place that turns "layers"
    /// into "captures to keep alive".
    static func demanded(program: Scene?,
                         staged: Scene?,
                         sources: [SourceDefinition]) -> Set<CaptureSourceKey> {
        demanded(layers: [program, staged].compactMap { $0 }.flatMap(\.layers),
                 sources: sources)
    }

    /// The capture-demand core: every visible camera/screen layer in the
    /// (already S06-flattened) list resolves to one key, registry payloads
    /// winning over inline ones exactly as documented above.
    static func demanded(layers: [LayerNode],
                         sources: [SourceDefinition]) -> Set<CaptureSourceKey> {
        var keys = Set<CaptureSourceKey>()
        for layer in layers where layer.isVisible {
            let payload = layer.sourceID
                .flatMap { id in sources.first(where: { $0.id == id }) }?.payload
                ?? layer.payload
            switch payload {
            case .camera(let camera): keys.insert(.camera(camera))
            case .screen(let screen): keys.insert(.screen(screen))
            default: break
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
/// sources later. C10 (issue #79) adds the MISSING state (`missingSources`):
/// a hot-unplugged device/display keeps its registry entry and demand, shows
/// the disconnect reason through `sourceErrors`, and resumes automatically
/// when the same stable identity returns — see the hot-plug section below.
@MainActor
final class CaptureSourcePool: ObservableObject {
    /// The last start/run failure per source identity, for future per-source
    /// UI badges. Cleared per source on a successful (re)start.
    @Published private(set) var sourceErrors: [CaptureSourceKey: String] = [:]
    /// Sources whose capture is delivering frames right now. Cameras report
    /// optimistically at start (their frames age out via `LatestCameraFrame`
    /// if the device never delivers); screens report from `isCapturing`.
    @Published private(set) var activeSources: Set<CaptureSourceKey> = []
    /// C10 (issue #79): requested sources whose physical device/display is
    /// currently unavailable (hot-unplugged, window closed, never connected).
    /// The source stays in the registry and in demand — its layers keep
    /// their binding, the renderer's documented fallback paints nothing, and
    /// capture resumes automatically when the SAME identity returns. Nothing
    /// is ever silently substituted for the missing device/display.
    @Published private(set) var missingSources: Set<CaptureSourceKey> = []

    /// The engines' off-main frame read path (see `SourceFrameProviders`).
    let frames = SourceFrameProviders()
    /// App/mic audio from every screen capture; the controller routes this to
    /// the publisher's ordered ingress.
    var onScreenAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// C10: fired when a screen capture reports an error (start failure,
    /// mid-capture stop). The controller probes Screen Recording permission
    /// here — the W06 revocation probe (`probeScreenAccess`) — because
    /// preflight lags a System Settings toggle.
    var onScreenCaptureError: (() -> Void)?

    /// Keys a start was requested for and not yet stopped. This — not
    /// `activeSources` — is what reconciliation diffs against, so an
    /// in-flight picker or a user-cancelled picker isn't re-presented until
    /// the source is genuinely unreferenced and re-referenced.
    private var requested: Set<CaptureSourceKey> = []
    private var cameras: [CaptureSourceKey: FacecamCapture] = [:]
    private var screens: [CaptureSourceKey: ScreenSourceCapture] = [:]
    private var screenFrames: [CaptureSourceKey: LatestScreenFrame] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// C10: the physical camera each camera key's capture is actually using —
    /// the pinned device ID, or the system default resolved at start — so a
    /// disconnect notification can be matched to exactly the sources it
    /// affects (and an unrelated camera never matches).
    private var cameraDeviceIDs: [CaptureSourceKey: String] = [:]
    /// C10: screen keys that have captured at least once, i.e. their capture
    /// instance holds a remembered content selection, so a retry restarts
    /// WITHOUT re-presenting the system picker.
    private var screenHadSelection: Set<CaptureSourceKey> = []
    /// The settings from the most recent reconcile, reused by hot-plug
    /// recovery and permission-grant retries to restart captures.
    private var lastReconcileSettings: StreamSettings?

    // MARK: - Demand reconciliation

    /// Diffs the scene-derived demand against the running set: starts first
    /// references, stops last references, and leaves shared captures
    /// untouched.
    func reconcile(demand rawDemand: Set<CaptureSourceKey>, settings: StreamSettings) {
        lastReconcileSettings = settings
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
        missingSources = []
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
                    self.missingSources.remove(key)
                    // The capture has a remembered selection from here on, so
                    // later retries never need to re-present the picker.
                    self.screenHadSelection.insert(key)
                } else {
                    self.activeSources.remove(key)
                    if let message = capture.errorMessage {
                        self.sourceErrors[key] = message
                    }
                }
            }
        }.store(in: &cancellables)
        // C10: the C02 sink below mirrors terminal error messages into
        // `sourceErrors`; this one adds the permission-revocation probe hook
        // — a screen error can mean Screen Recording was toggled off in
        // System Settings, and preflight lags that.
        capture.$errorMessage.sink { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, message != nil else { return }
                self.onScreenCaptureError?()
            }
        }.store(in: &cancellables)
        // C02: a pinned-source start that fails BEFORE any frame (missing
        // display/window/app, permission denial) never flips `isCapturing`,
        // so the sink above stays silent — mirror terminal error messages
        // too, or the sources UI would read "idle" instead of "error".
        capture.$errorMessage.sink { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture,
                      let message = capture.errorMessage,
                      !capture.isCapturing else { return }
                self.sourceErrors[key] = message
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
            startCamera(key, payload: payload, settings: settings)
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
        missingSources.remove(key)
        cameraDeviceIDs[key] = nil
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

    // MARK: - Device hot-plug and permission recovery (C10, issue #79)
    //
    // The DeviceMonitor (wired by StreamController) reports stable identities
    // — camera `uniqueID`s, `CGDirectDisplayID`s — and the pool moves the
    // matching sources between active and MISSING. A missing source keeps its
    // registry entry and demand; its capture stops, its frame holder clears
    // (the renderer's documented fallback paints nothing), and `sourceErrors`
    // carries the reason so the layer badges and diagnostics surfaces can
    // show it. Recovery restarts capture only for the SAME identity — an
    // unrelated camera/display never substitutes; that is what the relink
    // action (S05 registry update) is for.

    /// Camera unplugged: mark every requested camera capture actually using
    /// that device as missing. Unrelated sources keep running.
    func handleCameraDisconnected(_ uniqueID: String) {
        for key in requested {
            guard case .camera = key,
                  cameraDeviceIDs[key] == uniqueID,
                  !missingSources.contains(key) else { continue }
            markMissing(key, message: "The camera was disconnected. Reconnect it, or relink the source to another camera.")
        }
    }

    /// Camera connected: restart captures waiting on exactly this device.
    /// A default (unpinned) source that found no camera at all recovers on
    /// ANY connect — its defined identity IS "the system default camera".
    func handleCameraConnected(_ uniqueID: String) {
        guard let settings = lastReconcileSettings else { return }
        for key in missingSources {
            guard case .camera(let payload) = key else { continue }
            let matches = payload.deviceID.map { $0 == uniqueID }
                ?? (cameraDeviceIDs[key] == nil || cameraDeviceIDs[key] == uniqueID)
            guard matches else { continue }
            startCamera(key, payload: payload, settings: settings)
        }
    }

    /// Display set changed: pinned DISPLAY targets are checked synchronously
    /// against CoreGraphics' active list (no permission needed); pinned
    /// WINDOW targets and the default screen source's retry go through an
    /// SCShareableContent re-probe (skipped entirely when it throws — the
    /// permission-repair surface owns that state).
    func handleDisplaysChanged(displayIDs: Set<CGDirectDisplayID>) {
        for key in requested {
            guard case .screen(let payload) = key, payload.target == .display,
                  let raw = payload.targetIdentifier, let id = UInt32(raw) else { continue }
            if !displayIDs.contains(id) {
                guard !missingSources.contains(key) else { continue }
                markMissing(key, message: "The captured display was disconnected. Reconnect it, or relink the source to another display.")
            } else if missingSources.contains(key)
                        || (!activeSources.contains(key) && sourceErrors[key] != nil) {
                // Back (or a start that failed while it was gone): resume.
                recoverScreen(key, payload: payload)
            }
        }
        // Default screen source: if a remembered-selection capture died with
        // an error (e.g. its display vanished), retry now that the display
        // set changed. `pickAndStart` reuses the remembered filter, so no
        // picker appears; sources never picked stay untouched.
        if requested.contains(.defaultScreen),
           !activeSources.contains(.defaultScreen),
           sourceErrors[.defaultScreen] != nil,
           screenHadSelection.contains(.defaultScreen) {
            let capture = screenCapture(for: .defaultScreen)
            Task { [weak capture] in await capture?.pickAndStart() }
        }
        Task { await reevaluateWindowTargets() }
    }

    /// Permission (re)granted: retry every requested source sitting in an
    /// error/missing state. Nothing else would ever retry a source whose
    /// start was blocked by the permission pre-flight.
    func retryErroredSources() {
        guard let settings = lastReconcileSettings else { return }
        for key in requested where sourceErrors[key] != nil || missingSources.contains(key) {
            guard !activeSources.contains(key) else { continue }
            switch key {
            case .camera(let payload):
                startCamera(key, payload: payload, settings: settings)
            case .screen(let payload):
                missingSources.remove(key)
                sourceErrors[key] = nil
                let capture = screenCapture(for: key)
                Task { [weak capture] in
                    guard let capture else { return }
                    if payload.targetIdentifier != nil {
                        await capture.start(matching: payload)
                    } else if screenHadSelection.contains(key) {
                        await capture.pickAndStart()
                    }
                }
            }
        }
    }

    /// Camera access revoked mid-session: surface the repair state on every
    /// requested camera source and stop their captures. Other sources and
    /// every output are untouched (no false LIVE — the session states never
    /// derived from source health). `retryErroredSources` resumes capture
    /// when the permission comes back.
    func noteCameraPermissionRevoked() {
        for key in requested {
            guard case .camera = key else { continue }
            activeSources.remove(key)
            missingSources.remove(key)
            sourceErrors[key] = "Camera access was revoked. Re-enable it in System Settings > Privacy & Security > Camera — capture resumes automatically."
            cameras[key]?.stop()
        }
    }

    /// The per-source health message a layer badge shows (C10): the
    /// disconnect/missing reason or the last capture error. Nil = healthy.
    func problem(for key: CaptureSourceKey) -> String? {
        sourceErrors[normalized(key)]
    }

    /// True while the source's physical device/display is unavailable (the
    /// missing state — capture resumes automatically when identity returns).
    func isMissing(_ key: CaptureSourceKey) -> Bool {
        missingSources.contains(normalized(key))
    }

    /// Starts (or restarts) a camera capture: pre-flights permission and
    /// device presence — a pinned camera that no longer resolves becomes
    /// MISSING instead of falling back to an unrelated device — then builds
    /// a FRESH capture instance. A session whose device was unplugged holds
    /// a dead input that can't reliably resume, so recovery never reuses it.
    private func startCamera(_ key: CaptureSourceKey, payload: CameraSourcePayload,
                             settings: StreamSettings) {
        // `.notDetermined` passes through: FacecamCapture presents the
        // system prompt itself on first start.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            sourceErrors[key] = "Camera access is disabled for StreamMac. Enable it in System Settings > Privacy & Security > Camera."
            return
        default:
            break
        }
        if let deviceID = payload.deviceID {
            cameraDeviceIDs[key] = deviceID
            guard AVCaptureDevice(uniqueID: deviceID) != nil else {
                markMissing(key, message: "The pinned camera is not connected. Reconnect it, or relink the source to another camera.")
                return
            }
        } else {
            guard let resolved = AVCaptureDevice.default(for: .video)?.uniqueID else {
                cameraDeviceIDs[key] = nil
                markMissing(key, message: "No camera is connected. Connect one, or relink the source to a specific camera.")
                return
            }
            cameraDeviceIDs[key] = resolved
        }
        missingSources.remove(key)
        sourceErrors[key] = nil
        cameras[key]?.stop()
        let camera = FacecamCapture()
        cameras[key] = camera
        publishFrameHolders()
        camera.start(with: settings, deviceUniqueID: payload.deviceID)
        activeSources.insert(key)
    }

    /// Moves a source into the missing state: capture stops, frames clear,
    /// demand and registry binding survive.
    private func markMissing(_ key: CaptureSourceKey, message: String) {
        missingSources.insert(key)
        activeSources.remove(key)
        sourceErrors[key] = message
        switch key {
        case .camera:
            cameras[key]?.stop()
        case .screen:
            screenFrames[key]?.clear()
            if let capture = screens[key] {
                Task { await capture.stop() }
            }
        }
    }

    /// Restarts a pinned screen source whose target is available again.
    private func recoverScreen(_ key: CaptureSourceKey, payload: ScreenSourcePayload) {
        missingSources.remove(key)
        sourceErrors[key] = nil
        let capture = screenCapture(for: key)
        Task { [weak capture] in
            await capture?.start(matching: payload)
        }
    }

    /// Re-probes shareable content for pinned WINDOW targets: a window whose
    /// app closed marks its source missing; the same window ID reappearing
    /// restarts it. A failed probe (Screen Recording permission missing)
    /// changes nothing — the repair surface owns that state.
    private func reevaluateWindowTargets() async {
        let windowKeys: [(CaptureSourceKey, ScreenSourcePayload)] = requested.compactMap { key in
            guard case .screen(let payload) = key, payload.target == .window,
                  payload.targetIdentifier != nil else { return nil }
            return (key, payload)
        }
        guard !windowKeys.isEmpty,
              let content = try? await SCShareableContent.current else { return }
        for (key, payload) in windowKeys {
            guard let raw = payload.targetIdentifier, let id = UInt32(raw) else { continue }
            let exists = content.windows.contains { $0.windowID == id }
            if !exists {
                guard !missingSources.contains(key) else { continue }
                markMissing(key, message: "The captured window is no longer available. Reopen it, or relink the source.")
            } else if missingSources.contains(key)
                        || (!activeSources.contains(key) && sourceErrors[key] != nil) {
                recoverScreen(key, payload: payload)
            }
        }
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
