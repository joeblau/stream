import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamCore
import os.lock

/// G06 (issue #113): lock-protected snapshot of the active output canvas
/// size, published by StreamController. PDF engines read it on the render
/// tick (off-main, under the engine lock) so `.fill` framing crops to the
/// output aspect — never a @MainActor property read.
final class OutputCanvasStore: @unchecked Sendable {
    /// The process-wide live mirror (the SourcePayloadStore pattern).
    static let shared = OutputCanvasStore()

    private var lock = os_unfair_lock_s()
    private var size: CGSize?

    func publish(_ size: CGSize) {
        os_unfair_lock_lock(&lock)
        self.size = size
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> CGSize? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return size
    }
}

/// The physical identity of one capture source, derived from a source
/// definition's payload (or an unbound layer's inline payload). Two layers
/// referencing the same camera device or display produce the SAME key, which
/// is what lets the pool run one capture for any number of layers.
enum CaptureSourceKey: Hashable, Sendable {
    case camera(CameraSourcePayload)
    case screen(ScreenSourcePayload)
    /// C09 (issue #163): a Syphon feed, keyed by the payload's stable
    /// name+app identity (the server instance UUID is volatile and never
    /// part of the key, so an app relaunch re-keys onto the SAME capture).
    case syphon(SyphonSourcePayload)
    /// A02 (issue #97): a media (video file) source, keyed by its REGISTRY
    /// source ID — the persisted security-scoped bookmark lives on the
    /// `SourceDefinition`, and the A01 audio channel is `.media(sourceID)`,
    /// so the registry ID is the one stable identity across payload edits
    /// (loop/trim/relink never re-key playout).
    case media(SourceDefinitionID)
    /// A06 (issue #118): an app/system audio-only capture, keyed by its
    /// payload — mode, target bundle ID, and enablement are all identity, so
    /// retargeting or toggling re-keys the capture deliberately (the C03
    /// privacy-edit pattern). Demand comes from the REGISTRY
    /// (`demandedAppAudio`), never from scene layers.
    case appAudio(AppAudioSourcePayload)
    /// G08 (issue #115): a browser-overlay widget (WKWebView snapshot
    /// capture), keyed by its payload — every field is identity, so a
    /// configuration edit (URL, viewport, fps, CSS, audio route) re-keys the
    /// capture deliberately (the C03 pattern) and the widget reloads.
    case web(WebSourcePayload)
    /// G06 (issue #113): a PDF/slide-deck source, keyed by its REGISTRY
    /// source ID — the P03 asset reference lives on the `SourceDefinition`,
    /// so page state and the document survive payload edits (the A02 media
    /// precedent; `.pdf` payloads carry no physical-capture identity).
    case pdf(SourceDefinitionID)

    /// The system-default camera (no pinned device).
    static let defaultCamera = CaptureSourceKey.camera(CameraSourcePayload())
    /// The system-picker screen source (no pinned display/window).
    static let defaultScreen = CaptureSourceKey.screen(ScreenSourcePayload())

    /// True when nothing about the key pins a concrete device/display.
    var isDefaultSource: Bool {
        switch self {
        case .camera(let payload): return payload.deviceID == nil
        case .screen(let payload): return payload.targetIdentifier == nil
        case .syphon, .media, .appAudio, .web, .pdf: return false
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
    /// capture (image/text/guest/…) produce no key. A02: media layers
    /// demand playout by their registry source ID; an UNBOUND media layer
    /// has no file to play and demands nothing. G08 (issue #115): configured
    /// web layers demand a browser-overlay widget capture.
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
            case .syphon(let syphon): keys.insert(.syphon(syphon))
            case .media:
                // A02 (issue #97): media playout is keyed by the registry
                // source (the bookmark lives there); unbound media layers
                // paint the documented fallback instead.
                if let sourceID = layer.sourceID { keys.insert(.media(sourceID)) }
            case .pdf:
                // G06 (issue #113): PDF page rendering is keyed by the
                // registry source (the asset reference lives there), exactly
                // like media; unbound PDF layers paint nothing.
                if let sourceID = layer.sourceID { keys.insert(.pdf(sourceID)) }
            case .web(let web):
                // G08 (issue #115): a configured widget demands its snapshot
                // capture; an unconfigured one (no URL, no local HTML asset)
                // renders the documented nothing fallback and captures nothing.
                if web.browserOverlay.hasWidgetContent { keys.insert(.web(web)) }
            default: break
            }
        }
        return keys
    }

    /// A06 (issue #118): app-audio sources demand capture by REGISTRATION,
    /// not by scene layers — an enabled registry source keeps capturing no
    /// matter which scene is staged or program, so its mix channel survives
    /// scene switches and Takes untouched. (The W02 pipeline still gates
    /// everything: the controller unions this set into the demand only
    /// while the pipeline runs, and `stopAll` ends every capture with it.)
    static func demandedAppAudio(sources: [SourceDefinition]) -> Set<CaptureSourceKey> {
        Set(sources.compactMap { source in
            guard case .appAudio(let payload) = source.payload, payload.isEnabled
            else { return nil }
            return .appAudio(payload)
        })
    }
}

/// Lock-protected, off-main-readable view of the pool's live latest-frame
/// holders. The composition engines pull "the" screen/camera frame through
/// here exactly as they pulled the single W03 holders; the pool (main actor)
/// replaces the holder arrays whenever a capture instance is created. Stopped
/// captures clear their holder, so a holder list never serves stale pixels.
///
/// C01 (issue #76): alongside the default-source-first arrays (the legacy
/// single-frame read path), the holders are also published KEYED by source
/// identity, so `SceneRenderer` can paint each camera/screen layer from the
/// source its (registry or inline) payload names — two camera layers in one
/// scene show two different cameras. The keyed read falls back to the
/// default-first frame only when the pool has NO capture for the key (e.g.
/// the key names the default device by unique ID, which the pool normalizes
/// onto the default capture); a key the pool DOES hold never substitutes —
/// its stalled frame ages out to the documented paint-nothing fallback.
final class SourceFrameProviders: @unchecked Sendable {
    /// The process-wide live providers. The pool (a StreamController
    /// singleton, like the engines' other process-wide stores —
    /// `ProjectOverlayStore` / `SceneRegistryStore`) publishes here, so the
    /// engines' per-source read path needs no extra wiring at the call site.
    static let shared = SourceFrameProviders()

    private var lock = os_unfair_lock_s()
    private var screenHolders: [LatestScreenFrame] = []
    private var cameraHolders: [LatestCameraFrame] = []
    private var screenHoldersByKey: [CaptureSourceKey: LatestScreenFrame] = [:]
    private var cameraHoldersByKey: [CaptureSourceKey: LatestCameraFrame] = [:]
    /// A02 (issue #97): media playout is PULL-based (the render tick pulls
    /// the frame for the player's current item time), so this maps keys to
    /// the playback engines themselves, not latest-frame holders.
    private var mediaSourcesByKey: [CaptureSourceKey: any MediaFrameSource] = [:]

    func update(screenHolders: [LatestScreenFrame], cameraHolders: [LatestCameraFrame]) {
        os_unfair_lock_lock(&lock)
        self.screenHolders = screenHolders
        self.cameraHolders = cameraHolders
        os_unfair_lock_unlock(&lock)
    }

    /// C01: the keyed holder set, published with (never instead of) the
    /// ordered arrays above.
    func updateKeyed(screenHolders: [CaptureSourceKey: LatestScreenFrame],
                     cameraHolders: [CaptureSourceKey: LatestCameraFrame]) {
        os_unfair_lock_lock(&lock)
        self.screenHoldersByKey = screenHolders
        self.cameraHoldersByKey = cameraHolders
        os_unfair_lock_unlock(&lock)
    }

    /// A02 (issue #97): the keyed media playout sources, published with the
    /// other keyed holder sets (same known-key/never-substitute semantics).
    func updateKeyedMedia(_ sources: [CaptureSourceKey: any MediaFrameSource]) {
        os_unfair_lock_lock(&lock)
        self.mediaSourcesByKey = sources
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

    // MARK: - Per-source routing (C01, issue #76)

    /// True when the pool holds a capture for this exact key — the renderer
    /// checks this before the keyed read so an unknown key (never demanded,
    /// or normalized onto the default capture) falls back to the legacy
    /// default-first frame, while a known key NEVER substitutes another
    /// source's pixels.
    func hasCameraSource(for key: CaptureSourceKey) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return cameraHoldersByKey[key] != nil
    }

    func hasScreenSource(for key: CaptureSourceKey) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return screenHoldersByKey[key] != nil
    }

    /// The freshest frame from the capture for exactly this key (nil while
    /// its frames age out — the documented paint-nothing fallback). Call
    /// only when `hasCameraSource(for:)` is true.
    func cameraFrame(for key: CaptureSourceKey) -> LatestCameraFrame.Frame? {
        os_unfair_lock_lock(&lock)
        let holder = cameraHoldersByKey[key]
        os_unfair_lock_unlock(&lock)
        return holder?.freshest()
    }

    /// The latest frame from the screen capture for exactly this key.
    func screenFrame(for key: CaptureSourceKey) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let holder = screenHoldersByKey[key]
        os_unfair_lock_unlock(&lock)
        return holder?.latest()
    }

    /// Capture delivery counts are read without requesting/pulling any media.
    /// A static screen can deliver zero new frames while the compositor stays paced.
    func deliveryCount(for key: CaptureSourceKey) -> Int? {
        os_unfair_lock_lock(&lock)
        let camera = cameraHoldersByKey[key]
        let screen = screenHoldersByKey[key]
        os_unfair_lock_unlock(&lock)
        return camera?.deliveryTelemetry.snapshot().captured ?? screen?.deliveryTelemetry.snapshot().captured
    }

    // MARK: - Media playout (A02, issue #97)

    /// True when the pool holds a playback engine for this exact media key.
    /// A known key NEVER substitutes another source's frames; its nil reads
    /// (loading, error, Stop end action) are the renderer's documented
    /// paint-nothing fallback.
    func hasMediaSource(for key: CaptureSourceKey) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return mediaSourcesByKey[key] != nil
    }

    /// PULLS the current frame from the media playback for exactly this key
    /// (and tops up the source's mix-engine audio — the render tick is the
    /// playout cadence, so audio and video ride one clock). Call only from
    /// the render tick, and only when `hasMediaSource(for:)` is true.
    func mediaFrame(for key: CaptureSourceKey, canvasSize: CGSize? = nil) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let source = mediaSourcesByKey[key]
        os_unfair_lock_unlock(&lock)
        if let pdf = source as? PDFSourcePlayback { return pdf.pullFrame(canvasSize: canvasSize) }
        return source?.pullFrame()
    }
}

/// C01 (issue #76): the per-source frame read path `SceneRenderer` composites
/// through. Each closure resolves a layer's capture identity
/// (`CaptureSourceKey`, derived from its registry or inline payload) to THAT
/// source's latest frame, with the documented fallbacks: an unknown key reads
/// the default-source-first frame (legacy single-source behavior), a known
/// key with no fresh pixels paints nothing (never a substitute source).
struct SourceFrameLookup: Sendable {
    let camera: @Sendable (CaptureSourceKey) -> LatestCameraFrame.Frame?
    let screen: @Sendable (CaptureSourceKey) -> CVPixelBuffer?
    /// A02 (issue #97): the media playout read path — PULLED per tick from
    /// the pool's per-source playback engines. Nil (no media path wired)
    /// means media layers paint the documented nothing fallback.
    var media: (@Sendable (CaptureSourceKey) -> CVPixelBuffer?)? = nil
    var pdf: (@Sendable (CaptureSourceKey, CGSize) -> CVPixelBuffer?)? = nil
}

/// Holds the newest screen frame for one screen capture. Unlike the pre-W08
/// destructive take, reads are non-destructive: the composition ticks at the
/// output fps using the LATEST sample (issue #65), so a static screen keeps
/// compositing — moving camera overlays included — without ScreenCaptureKit
/// producing fresh frames.
final class LatestScreenFrame: @unchecked Sendable {
    let deliveryTelemetry = FrameTelemetry()
    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?

    func store(_ buffer: CVPixelBuffer) {
        os_unfair_lock_lock(&lock)
        self.buffer = buffer
        deliveryTelemetry.recordCaptured()
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
    /// Recording pins the same normalized physical identity as capture.
    /// Unlike the legacy composition lookup, ISO never falls back to a
    /// different default camera when this exact holder is missing.
    func recordingCaptureKey(for key: CaptureSourceKey) -> CaptureSourceKey { normalized(key) }
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
    /// Shared process-wide (`SourceFrameProviders.shared`) so the engines'
    /// per-source routing needs no controller rewiring.
    let frames = SourceFrameProviders.shared
    /// App/mic audio from every screen capture, fired on the capture's own
    /// ScreenCaptureKit queue (off main) with the source's identity, so the
    /// A01 audio engine can route each source onto its own mix channel. The
    /// controller forwards this to `AudioMixEngine.enqueue`.
    var onScreenAudioSample: (@Sendable (CaptureSourceKey, CMSampleBuffer) -> Void)?
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
    /// C09 (issue #163): one Syphon client per requested syphon key. The
    /// capture owns its frame holder; `publishFrameHolders` folds those
    /// holders into the keyed SCREEN holder map, so the renderer's existing
    /// C01 read path (`frames.screen(key)`) serves syphon layers unchanged.
    private var syphonCaptures: [CaptureSourceKey: SyphonSourceCapture] = [:]
    /// C09: the live Syphon server directory — both the Sources tab's
    /// addable-server list and the missing/recovery signal for syphon
    /// sources (servers appear/disappear like hot-plugged devices, C10).
    let syphonDiscovery = SyphonServerDiscovery()
    /// A02 (issue #97): one playback engine per media key. Instances persist
    /// across demand loss (like screen captures and their remembered
    /// selections): pausing holds the position, so a re-referenced source —
    /// and a Take between scenes sharing it — resumes mid-file and never
    /// restarts playback.
    private var mediaPlaybacks: [CaptureSourceKey: MediaSourcePlayback] = [:]
    /// G06 (issue #113): one PDF page-rendering engine per demanded registry
    /// source, pull-based like media (the render tick is the cadence).
    private var pdfPlaybacks: [CaptureSourceKey: PDFSourcePlayback] = [:]
    /// G06: the P03 asset library PDF engines resolve documents through. Set
    /// once by the dispatcher at startup (`dispatcher.assetLibrary`).
    var assetLibrary: AssetLibraryStore?
    /// G06: PDF engine status mirror — the dispatcher sets this to re-clamp
    /// persisted deck state (`PDFDeckStore.notePageCount`) on document load.
    var onPDFStatus: (@MainActor (SourceDefinitionID, PDFSourceStatus) -> Void)?
    /// G06: per-source PDF load/render state for inspector badges.
    @Published private(set) var pdfStates: [SourceDefinitionID: PDFSourceStatus] = [:]
    /// A06 (issue #118): one audio-only capture per requested app-audio key.
    /// Instances persist across demand loss (like screen captures), so a
    /// re-enabled source restarts without re-resolving anything.
    private var appAudioCaptures: [CaptureSourceKey: AppAudioCapture] = [:]
    /// G08 (issue #115): one browser-overlay widget host per demanded web
    /// key. Unlike screen captures, hosts do NOT persist across demand loss:
    /// an unreferenced widget's page unloads (freeing its WebContent work)
    /// and reloads deterministically on re-entry — there is no remembered
    /// selection to preserve. A Take between scenes sharing a widget never
    /// drops the key from demand, so its page rides through untouched.
    private var webHosts: [CaptureSourceKey: BrowserOverlayHost] = [:]
    /// G08: per-key state-mirror subscriptions, torn down with the host.
    private var webHostCancellables: [CaptureSourceKey: AnyCancellable] = [:]
    /// G08: the per-widget load/error state for the inspector's web section
    /// (badges, failure reasons) — mirrored from each host on the sink.
    @Published private(set) var webStates: [CaptureSourceKey: BrowserOverlayLoadState] = [:]
    /// G08: the program scene identity the scene-entry refresh policy last
    /// evaluated against — a widget "enters" when the program scene changes
    /// while the widget is in it, even though its capture never restarted.
    private var lastProgramWebSceneID: SceneID?
    /// A06: the running-app directory — the Sources tab's app picker AND the
    /// missing/recovery signal for app-audio sources (apps terminate and
    /// relaunch like hot-plugged devices, C10). No TCC permission needed.
    let runningApps = RunningApplicationMonitor()
    /// A06: the per-app bundle-ID set excluded from the system mix at the
    /// last reconcile, so a change (a per-app source added/removed/toggled)
    /// restarts the system capture with the de-duplication intact.
    private var lastSystemMixExclusions: Set<String> = []
    /// A02: the transport UI's per-source status (loaded/playing/paused/
    /// ended/error + position/duration), mirrored from each playback engine.
    @Published private(set) var mediaStates: [SourceDefinitionID: MediaSourceStatus] = [:]
    /// A02: media-source audio, fired on the composition engines' render
    /// tick with each buffer already retimed onto the shared host clock. The
    /// controller forwards this to `AudioMixEngine.enqueue` as `.media(id)`
    /// channels (the media twin of `onScreenAudioSample`).
    var onMediaReachedEnd: ((SourceDefinitionID, Double) -> Void)?
    var onMediaAudioSample: (@Sendable (SourceDefinitionID, CMSampleBuffer) -> Void)?
    /// A06 (issue #118): app/system audio-only captures, fired on each
    /// capture's own ScreenCaptureKit queue (off main) with the source's
    /// identity, so the A01 engine routes each onto its `.application`
    /// channel (the app-audio twin of `onScreenAudioSample`).
    var onAppAudioSample: (@Sendable (CaptureSourceKey, CMSampleBuffer) -> Void)?
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

    init() {
        // C09: Syphon servers announce/retire independently of demand —
        // reconcile syphon sources against every directory change (server
        // quit → MISSING; the same name+app reappearing → auto-recovery).
        syphonDiscovery.$servers.sink { [weak self] servers in
            Task { @MainActor [weak self] in
                self?.handleSyphonServersChanged(servers)
            }
        }.store(in: &cancellables)
        // A06: apps terminate/relaunch independently of demand — reconcile
        // app-audio sources against every directory change (quit → MISSING;
        // the same bundle ID relaunching → auto-recovery), the C10 pattern
        // with the running-app directory as the hot-plug signal.
        runningApps.$runningBundleIDs.sink { [weak self] bundleIDs in
            Task { @MainActor [weak self] in
                self?.handleRunningAppsChanged(bundleIDs)
            }
        }.store(in: &cancellables)
    }

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
        // A06: the system mix excludes apps that carry their own per-app
        // source (no double audio). That set derives from the demand, not
        // from any single key, so when it changes the running system capture
        // restarts with the new exclusion filter.
        let exclusions = systemMixExclusions(in: demand, settings: settings)
        if exclusions != lastSystemMixExclusions {
            lastSystemMixExclusions = exclusions
            for key in demand where requested.contains(key) && activeSources.contains(key) {
                guard case .appAudio(let payload) = key, payload.mode == .system else { continue }
                Task { [weak self] in
                    guard let capture = self?.appAudioCaptures[key] else { return }
                    await capture.stop()
                    await capture.start(with: payload, excludingBundleIDs: exclusions)
                }
            }
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

    /// C03 (issue #78): applies freshly-saved global privacy defaults by
    /// restarting every ACTIVE screen capture with the new effective
    /// privacy — settings changes don't re-key payloads, so without this a
    /// running capture would keep its old cursor/audio flags until it
    /// happened to restart. Remembered selections are reused, so no picker
    /// re-appears; idle/errored sources pick the defaults up on their next
    /// start (every start path reads the latest settings already).
    /// `StreamController.applySavedSettings` is the intended caller.
    func applyPrivacyDefaults(_ settings: StreamSettings) {
        lastReconcileSettings = settings
        for key in requested where activeSources.contains(key) {
            guard case .screen(let payload) = key,
                  let capture = screens[key] else { continue }
            Task { [weak capture] in
                guard let capture else { return }
                await capture.stop()
                if payload.targetIdentifier != nil {
                    await capture.start(matching: payload, defaults: settings)
                } else {
                    await capture.pickAndStart(defaults: settings)
                }
            }
        }
        // A06: the system mix's exclusion filter carries the global privacy
        // exclusion list, so an active system capture restarts on the new
        // defaults too (per-app captures are unaffected — their filter pins
        // exactly one app regardless).
        let exclusions = systemMixExclusions(in: requested, settings: settings)
        lastSystemMixExclusions = exclusions
        for key in requested where activeSources.contains(key) {
            guard case .appAudio(let payload) = key, payload.mode == .system,
                  let capture = appAudioCaptures[key] else { continue }
            Task { [weak capture] in
                guard let capture else { return }
                await capture.stop()
                await capture.start(with: payload, excludingBundleIDs: exclusions)
            }
        }
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
        // The handler value is captured (not the MainActor pool) so the
        // off-main @Sendable closure stays isolation-clean. The controller
        // assigns `onScreenAudioSample` before any capture exists, so the
        // value read here is always the live one.
        let audioHandler = onScreenAudioSample
        capture.onAudioSampleOffMain = { sample in
            audioHandler?(key, sample)
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
                    await capture.start(matching: payload, defaults: settings)
                } else {
                    await capture.pickAndStart(defaults: settings)
                }
            }
        case .syphon(let payload):
            startSyphon(key, payload: payload)
        case .media(let id):
            startMedia(key, id: id)
        case .pdf(let id):
            startPDF(key, id: id)
        case .appAudio(let payload):
            startAppAudio(key, payload: payload, settings: settings)
        case .web(let payload):
            startWeb(key, payload: payload)
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
        case .syphon:
            // Synchronous disconnect; clears its frame holder.
            syphonCaptures[key]?.stop()
        case .media:
            // A02: last reference removed — pause mid-file (the position
            // holds; playout follows demand per the issue's lifecycle
            // criterion). Explicit transport Stop is what rewinds.
            mediaPlaybacks[key]?.pause()
        case .pdf:
            // G06: last reference removed — hold page and document (the
            // engine has nothing to park; pause() is the demand-loss hold).
            pdfPlaybacks[key]?.pause()
        case .appAudio:
            // A06: last reference removed (source disabled/removed, or the
            // pipeline stopped) — stop the capture; the instance and its
            // resolved target survive for the next demand.
            if let capture = appAudioCaptures[key] {
                Task { await capture.stop() }
            }
        case .web:
            // G08: last reference removed — the widget page unloads with the
            // host (no remembered selection to preserve); re-entry reloads.
            webHostCancellables[key] = nil
            webStates[key] = nil
            webHosts[key]?.dispose()
            webHosts[key] = nil
        }
    }

    /// Hands the engines the live holder set, default (unpinned) sources
    /// first so the single-path providers prefer the primary capture. C01:
    /// the same holders are ALSO published keyed by source identity, so the
    /// renderer routes each camera/screen layer to its own source's frames.
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
        // C09: syphon holders join the KEYED screen map only (never the
        // legacy default-first arrays — the single-source legacy behavior
        // stays bit-identical), so `frames.screen(key)` resolves `.syphon`
        // keys with the same known-key/never-substitute semantics.
        frames.updateKeyed(
            screenHolders: screenFrames.merging(syphonCaptures.mapValues(\.frames)) { current, _ in current },
            cameraHolders: cameras.mapValues(\.latest))
        // A02: the keyed media playout sources (pull-based — the render tick
        // reads `frames.media(key)` straight from each playback engine).
        // G06: the PDF engines merge into the same keyed map.
        frames.updateKeyedMedia(mediaPlaybacks.mapValues { $0 as any MediaFrameSource }
            .merging(pdfPlaybacks.mapValues { $0 as any MediaFrameSource }) { _, pdf in pdf })
    }

    /// The capture instance for a syphon key, created (and wired) on first
    /// use and stable thereafter. Mirrors the screen factory's sinks so
    /// per-source active/error state lands in the same published surfaces.
    private func syphonCapture(for key: CaptureSourceKey) -> SyphonSourceCapture {
        if let existing = syphonCaptures[key] { return existing }
        let capture = SyphonSourceCapture()
        syphonCaptures[key] = capture
        capture.$isCapturing.sink { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture else { return }
                if capture.isCapturing {
                    self.activeSources.insert(key)
                    self.sourceErrors[key] = nil
                    self.missingSources.remove(key)
                } else {
                    self.activeSources.remove(key)
                    if let message = capture.errorMessage {
                        self.sourceErrors[key] = message
                    }
                }
            }
        }.store(in: &cancellables)
        // A start that fails before connecting never flips `isCapturing` —
        // mirror terminal error messages too, or the sources UI would read
        // "idle" instead of "error" (the C02 screen pattern).
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
        // C05 (issue #105): the DeviceMonitor ALSO fires this hook when a
        // connected camera's feed suspends (iPhone locked, camera paused in
        // Control Center). A suspended device still resolves, so the missing
        // message can say WHY the feed stopped instead of implying a
        // physical unplug.
        let suspended = AVCaptureDevice(uniqueID: uniqueID)?.isSuspended ?? false
        let message = suspended
            ? "The camera feed is paused — the iPhone is locked or the camera was paused in Control Center. Capture resumes automatically when it returns."
            : "The camera was disconnected. Reconnect it, or relink the source to another camera."
        for key in requested {
            guard case .camera = key,
                  cameraDeviceIDs[key] == uniqueID,
                  !missingSources.contains(key) else { continue }
            markMissing(key, message: message)
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
            Task { [weak capture] in
                await capture?.pickAndStart(defaults: lastReconcileSettings ?? .default)
            }
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
                        await capture.start(matching: payload, defaults: settings)
                    } else if screenHadSelection.contains(key) {
                        await capture.pickAndStart(defaults: settings)
                    }
                }
            case .syphon(let payload):
                missingSources.remove(key)
                startSyphon(key, payload: payload)
            case .media(let id):
                missingSources.remove(key)
                sourceErrors[key] = nil
                startMedia(key, id: id)
            case .appAudio(let payload):
                missingSources.remove(key)
                sourceErrors[key] = nil
                startAppAudio(key, payload: payload, settings: settings)
            case .web(let payload):
                missingSources.remove(key)
                sourceErrors[key] = nil
                startWeb(key, payload: payload)
            case .pdf(let id):
                // G06: re-resolve the asset and reload the document.
                missingSources.remove(key)
                sourceErrors[key] = nil
                startPDF(key, id: id)
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

    /// E05 (issue #109): true while a demanded camera capture is actually
    /// using this physical device (by stable uniqueID) — the camera controls
    /// surface badges live devices, and a hardware control change on an
    /// in-use device lands in preview AND program because the one capture
    /// feeds both engines.
    func isCameraDeviceInUse(_ uniqueID: String) -> Bool {
        requested.contains { key in
            guard case .camera = key, activeSources.contains(key) else { return false }
            return cameraDeviceIDs[key] == uniqueID
        }
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
            guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                markMissing(key, message: "The pinned camera is not connected. Reconnect it, or relink the source to another camera.")
                return
            }
            // C05 (issue #105): a suspended device (locked iPhone, paused
            // camera) opens fine but delivers no frames — go straight to the
            // missing state with the real reason; the DeviceMonitor's
            // suspension KVO restarts capture when the feed returns.
            guard !device.isSuspended else {
                markMissing(key, message: "The camera feed is paused — the iPhone is locked or the camera was paused in Control Center. Capture resumes automatically when it returns.")
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
        // E05 (issue #109): restore the device's persisted hardware control
        // preferences (focus/exposure/white-balance modes) — they live on the
        // physical device and don't survive every capture restart, so each
        // (re)start re-applies them. Capability-gated by the applier: a
        // device that doesn't honor a preference keeps its own state.
        if let uid = cameraDeviceIDs[key],
           let controls = settings.cameraControls[uid],
           let device = AVCaptureDevice(uniqueID: uid) {
            CameraControlApplier.apply(controls, to: device)
        }
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
        case .syphon:
            syphonCaptures[key]?.stop()
        case .media:
            mediaPlaybacks[key]?.pause()
        case .pdf:
            // G06: a missing PDF asset pauses the engine; the deck state and
            // demand survive for repair.
            pdfPlaybacks[key]?.pause()
        case .appAudio:
            if let capture = appAudioCaptures[key] {
                Task { await capture.stop() }
            }
        case .web:
            // G08: no physical device/display ever marks a widget missing,
            // but halt the snapshot clock if one lands here — the frame
            // store keeps the last frame until its freshness window lapses.
            webHosts[key]?.stop()
        }
    }

    /// Restarts a pinned screen source whose target is available again.
    private func recoverScreen(_ key: CaptureSourceKey, payload: ScreenSourcePayload) {
        missingSources.remove(key)
        sourceErrors[key] = nil
        let capture = screenCapture(for: key)
        Task { [weak capture] in
            await capture?.start(matching: payload,
                                 defaults: lastReconcileSettings ?? .default)
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

    // MARK: - Syphon server lifecycle (C09, issue #163)

    /// Starts (or restarts) a syphon source: connects to the live server
    /// matching the payload's stable name+app identity. A server that isn't
    /// publishing right now is MISSING, never an error — creative/titling
    /// apps come and go, and the discovery reconciliation below restarts
    /// capture automatically when the same identity reappears (the C10
    /// pattern, with the server directory as the hot-plug signal).
    private func startSyphon(_ key: CaptureSourceKey, payload: SyphonSourcePayload) {
        sourceErrors[key] = nil
        let capture = syphonCapture(for: key)
        guard capture.start(matching: payload) else {
            markMissing(key, message: "The Syphon server \"\(payload.displayTitle)\" is not running. Launch it — capture resumes automatically when it appears, or relink the source to another server.")
            return
        }
    }

    /// The server directory changed (announce/update/retire). Requested
    /// syphon sources whose server vanished move to MISSING — registry
    /// entry, demand, and layer bindings survive, the frame holder clears
    /// (the renderer's documented fallback paints nothing), and unrelated
    /// sources and every output keep running. Missing sources whose
    /// name+app pair reappears restart by stable identity: an app relaunch
    /// recovers exactly like a device hot-plug, and a DIFFERENT server never
    /// substitutes (that is what the relink action is for).
    private func handleSyphonServersChanged(_ servers: [DiscoveredSyphonServer]) {
        // Builds without the Syphon package never publish servers; the
        // capture's honest unavailable error owns that state instead.
        guard SyphonServerDiscovery.isSupported else { return }
        for key in requested {
            guard case .syphon(let payload) = key else { continue }
            let available = servers.contains { $0.matches(payload) }
            if !available, !missingSources.contains(key) {
                markMissing(key, message: "The Syphon server \"\(payload.displayTitle)\" stopped publishing. Relaunch it — capture resumes automatically when it returns, or relink the source to another server.")
            } else if available, missingSources.contains(key) {
                missingSources.remove(key)
                sourceErrors[key] = nil
                startSyphon(key, payload: payload)
            }
        }
    }

    // MARK: - Media playout (A02, issue #97)
    //
    // Media sources follow the pool's demand model exactly like captures: a
    // playback engine loads on its first scene reference (program, or staged
    // while the monitors are visible) and pauses mid-file when the last
    // reference goes away. The engine instance persists, so a Take between
    // scenes sharing the source — and the preview/program engines reading it
    // simultaneously — never restarts playback: audio and video stay
    // synchronized through scene changes because there is exactly ONE player
    // per source, pulled per tick on the shared host clock.

    /// Starts (or resumes) a media source's playout: resolves the engine
    /// (creating it on first use) and kicks the bookmark-resolution load.
    /// Autoplay is the payload's decision, honored at load completion.
    private func startMedia(_ key: CaptureSourceKey, id: SourceDefinitionID) {
        guard let playback = mediaPlayback(for: key, id: id) else { return }
        sourceErrors[key] = nil
        playback.load()
        // Optimistic like cameras: frames/status age in through mediaStates;
        // a load failure flips the error surface via the status callback.
        activeSources.insert(key)
    }

    /// The playback engine for a media key, created (and wired) on first use
    /// and stable thereafter. The payload provider reads the registry's live
    /// payload index (`SourcePayloadStore`), so loop/end-action edits take
    /// effect at the next loop point and a relink (bookmark change) reloads
    /// the file on the pull path — the source ID key never changes.
    private func mediaPlayback(for key: CaptureSourceKey,
                               id: SourceDefinitionID) -> MediaSourcePlayback? {
        if let existing = mediaPlaybacks[key] { return existing }
        let playback = MediaSourcePlayback(sourceID: id) {
            guard case .media(let payload) = SourcePayloadStore.shared.snapshot()[id]
            else { return nil }
            return payload
        }
        // The handler value is captured (not the MainActor pool) so the
        // engine-tick @Sendable closure stays isolation-clean. The controller
        // assigns `onMediaAudioSample` before any playback exists, so the
        // value read here is always the live one (the C01 screen pattern).
        let audioHandler = onMediaAudioSample
        playback.onAudioSample = { sample in
            audioHandler?(id, sample)
        }
        playback.onReachedEnd = { [weak self] sourceID, time in
            Task { @MainActor [weak self] in self?.onMediaReachedEnd?(sourceID, time) }
        }
        playback.onStatus = { [weak self] sourceID, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mediaStates[sourceID] = status
                if status.phase == .error {
                    self.activeSources.remove(key)
                    self.sourceErrors[key] = status.errorMessage
                } else if status.phase == .playing || status.phase == .ready {
                    self.sourceErrors[key] = nil
                }
            }
        }
        mediaPlaybacks[key] = playback
        publishFrameHolders()
        return playback
    }

    // MARK: - Media transport (W05 dispatcher commands)

    /// The playback engine for a registry media source, creating it on
    /// explicit transport intent (play/restart) — audition before the source
    /// is referenced anywhere. Explicit transport acts on the ONE shared
    /// instance, so it can never fork program vs preview playback.
    func playMedia(_ id: SourceDefinitionID) {
        guard let playback = mediaPlayback(for: .media(id), id: id) else { return }
        playback.load()
        playback.play()
    }

    func pauseMedia(_ id: SourceDefinitionID) {
        mediaPlaybacks[.media(id)]?.pause()
    }

    func stopMedia(_ id: SourceDefinitionID) {
        mediaPlaybacks[.media(id)]?.stop()
    }

    func restartMedia(_ id: SourceDefinitionID) {
        guard let playback = mediaPlayback(for: .media(id), id: id) else { return }
        playback.load()
        playback.restart()
    }

    func seekMedia(_ id: SourceDefinitionID, toSeconds seconds: Double) {
        mediaPlaybacks[.media(id)]?.seek(toSeconds: seconds)
    }

    func restorePausedMediaPosition(_ id: SourceDefinitionID, seconds: Double) {
        mediaPlayback(for: .media(id), id: id)?.restorePausedPosition(seconds: seconds)
    }

    /// The current status for one media source (idle when never loaded) —
    /// the transport UI's read path.
    func mediaStatus(for id: SourceDefinitionID) -> MediaSourceStatus {
        mediaStates[id] ?? MediaSourceStatus()
    }

    // MARK: - PDF sources (G06, issue #113)

    /// Starts (or resumes) a PDF source's page rendering: resolves the engine
    /// (creating it on first use) and kicks the asset-resolution load.
    private func startPDF(_ key: CaptureSourceKey, id: SourceDefinitionID) {
        guard let playback = pdfPlayback(for: key, id: id) else { return }
        sourceErrors[key] = nil
        playback.load()
        // Optimistic like media: state ages in through pdfStates; a load
        // failure flips the error surface via the status callback.
        activeSources.insert(key)
    }

    /// The page-rendering engine for a PDF key, created (and wired) on first
    /// use and stable thereafter — page state is per source and shared by
    /// both canvases, so the instance must survive Takes.
    private func pdfPlayback(for key: CaptureSourceKey,
                             id: SourceDefinitionID) -> PDFSourcePlayback? {
        if let existing = pdfPlaybacks[key] { return existing }
        guard let assetLibrary else { return nil }
        let playback = PDFSourcePlayback(sourceID: id, assetLibrary: assetLibrary)
        // The provider runs on the RENDER TICK (off-main, under the engine
        // lock) — read the lock-protected canvas snapshot, never a
        // @MainActor property.
        playback.canvasSizeProvider = { OutputCanvasStore.shared.snapshot() }
        playback.onStatus = { [weak self] sourceID, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pdfStates[sourceID] = status
                if status.phase == .error {
                    self.activeSources.remove(key)
                    self.sourceErrors[key] = status.errorMessage
                } else if status.phase == .ready {
                    self.sourceErrors[key] = nil
                }
                self.onPDFStatus?(sourceID, status)
            }
        }
        pdfPlaybacks[key] = playback
        publishFrameHolders()
        return playback
    }

    /// Reloads a PDF source's document after a same-identity asset content
    /// replacement (P03 relink/replace keeps the asset identifier).
    func reloadPDF(_ id: SourceDefinitionID) {
        pdfPlaybacks[.pdf(id)]?.load()
    }

    // MARK: - App audio (A06, issue #118)
    //
    // App-audio sources follow the pool's demand model with ONE difference:
    // their demand comes from the registry (registered + enabled), not from
    // visible layers, so capture survives every scene switch and Take. Quit/
    // relaunch is the C10 hot-plug pattern with the running-app directory as
    // the signal; the audio itself flows off-main to the engine's
    // `.application` channels, which the A04 mixer owns — scene
    // `AudioBinding`s deliberately never address them (mixer-only gain).

    /// Starts (or restarts) an app-audio capture. A target app that isn't
    /// running is MISSING (auto-recovery on relaunch), never an error and
    /// never a substitution — checked against the permission-free running-app
    /// directory before any ScreenCaptureKit work.
    private func startAppAudio(_ key: CaptureSourceKey, payload: AppAudioSourcePayload,
                               settings: StreamSettings) {
        sourceErrors[key] = nil
        let capture = appAudioCapture(for: key)
        if payload.mode == .application, let bundleID = payload.bundleID,
           !runningApps.runningBundleIDs.contains(bundleID) {
            markMissing(key, message: "\(payload.displayTitle) is not running. Launch it — capture resumes automatically, or relink the source to another app.")
            return
        }
        let exclusions = systemMixExclusions(in: requested, settings: settings)
        lastSystemMixExclusions = exclusions
        Task { [weak capture] in
            await capture?.start(with: payload, excludingBundleIDs: exclusions)
        }
    }

    /// The apps the SYSTEM mix must exclude: every app carrying its own
    /// enabled per-app source (so system + per-app never double) plus the
    /// global privacy exclusion list (the C03 defaults applied to audio).
    /// The studio itself is excluded by `AppAudioCapture` on top.
    private func systemMixExclusions(in keys: Set<CaptureSourceKey>,
                                     settings: StreamSettings) -> Set<String> {
        var exclusions = Set(settings.captureExcludedBundleIDs)
        for key in keys {
            guard case .appAudio(let payload) = key,
                  payload.mode == .application,
                  let bundleID = payload.bundleID else { continue }
            exclusions.insert(bundleID)
        }
        return exclusions
    }

    /// The capture instance for an app-audio key, created (and wired) on
    /// first use and stable thereafter. Mirrors the screen factory's sinks so
    /// per-source active/error state lands in the same published surfaces.
    private func appAudioCapture(for key: CaptureSourceKey) -> AppAudioCapture {
        if let existing = appAudioCaptures[key] { return existing }
        let capture = AppAudioCapture()
        appAudioCaptures[key] = capture
        // The handler value is captured (not the MainActor pool) so the
        // off-main @Sendable closure stays isolation-clean. The controller
        // assigns `onAppAudioSample` before any capture exists, so the value
        // read here is always the live one (the C01 screen pattern).
        let audioHandler = onAppAudioSample
        capture.onAudioSampleOffMain = { sample in
            audioHandler?(key, sample)
        }
        capture.$isCapturing.sink { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture else { return }
                if capture.isCapturing {
                    self.activeSources.insert(key)
                    self.sourceErrors[key] = nil
                    self.missingSources.remove(key)
                } else {
                    self.activeSources.remove(key)
                    if let message = capture.errorMessage {
                        self.sourceErrors[key] = message
                    }
                }
            }
        }.store(in: &cancellables)
        // A start that fails before capturing never flips `isCapturing` —
        // mirror terminal error messages too (the C02 screen pattern), and
        // probe Screen Recording permission: an app-audio error can mean the
        // permission was toggled off in System Settings (the W06 hook).
        capture.$errorMessage.sink { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture,
                      let message = capture.errorMessage else { return }
                if !capture.isCapturing {
                    self.sourceErrors[key] = message
                }
                self.onScreenCaptureError?()
            }
        }.store(in: &cancellables)
        return capture
    }

    /// The running-app directory changed (launch/terminate). Requested
    /// app-audio sources whose target vanished move to MISSING — registry
    /// entry and enablement survive — and missing sources whose bundle ID
    /// relaunches restart by stable identity: an app relaunch recovers
    /// exactly like a device hot-plug, and a DIFFERENT app never substitutes
    /// (that is what the relink action is for). System-mix sources have no
    /// single target app and are untouched.
    private func handleRunningAppsChanged(_ running: Set<String>) {
        for key in requested {
            guard case .appAudio(let payload) = key,
                  payload.mode == .application,
                  let bundleID = payload.bundleID else { continue }
            if !running.contains(bundleID), !missingSources.contains(key) {
                markMissing(key, message: "\(payload.displayTitle) quit. Relaunch it — capture resumes automatically when it returns, or relink the source to another app.")
            } else if running.contains(bundleID), missingSources.contains(key) {
                missingSources.remove(key)
                sourceErrors[key] = nil
                startAppAudio(key, payload: payload,
                              settings: lastReconcileSettings ?? .default)
            }
        }
    }

    // MARK: - Browser overlay widgets (G08, issue #115)
    //
    // Web sources follow the pool's demand model exactly like captures: the
    // widget's WKWebView loads on its first scene/overlay reference and
    // unloads when the last reference goes away. Frames flow through
    // `BrowserOverlayFrameStore` (latest-wins, freshness-windowed), never the
    // keyed holder maps — the renderer's `.web` branch pulls by the payload's
    // `browserOverlayStoreKey` (see WebOverlayIntegration.swift). Web keys
    // carry no audio channel: widget audio is the G07-documented systemMix/
    // helperApp story, not a capture the A01 engine pulls samples from.

    /// Starts (or restarts) a widget host. A payload edit re-keys the demand
    /// (the C03 deliberate re-key pattern), so this always builds a FRESH
    /// host on the new key — the old key's host is torn down by `stop(_:)`.
    private func startWeb(_ key: CaptureSourceKey, payload: WebSourcePayload) {
        sourceErrors[key] = nil
        let configuration = payload.browserOverlay
        guard let storeKey = payload.browserOverlayStoreKey else {
            sourceErrors[key] = "The web source has no widget URL or local HTML asset."
            return
        }
        webHostCancellables[key] = nil
        webHosts[key]?.dispose()
        let host = BrowserOverlayHost(configuration: configuration, storeKey: storeKey)
        webHosts[key] = host
        webHostCancellables[key] = host.$loadState.sink { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.webStates[key] = state
                switch state {
                case .ready:
                    self.activeSources.insert(key)
                    self.sourceErrors[key] = nil
                case .failed(let message):
                    self.activeSources.remove(key)
                    self.sourceErrors[key] = message
                case .loading, .idle:
                    self.activeSources.remove(key)
                }
            }
        }
        host.start()
    }

    /// The widget host for a demanded web key (nil while unreferenced) — the
    /// inspector's runtime controls (Reload, Replay Alert, live metrics)
    /// reach through here.
    func webHost(for key: CaptureSourceKey) -> BrowserOverlayHost? {
        webHosts[key]
    }

    /// The scene-entry refresh signal — wired from
    /// `StreamController.publishSceneToProgram` (orchestrator hook 3 in
    /// WebOverlayIntegration.swift). When the PROGRAM scene's identity
    /// changes, every web widget in it applies its `sceneEntryRefresh`
    /// policy. The capture itself never restarts across a Take (demand is
    /// unchanged); this is the deliberate content-level refresh on top.
    /// `layers` must be the already S06-flattened visible program layers.
    func noteWebWidgetSceneEntries(sceneID: SceneID,
                                   layers: [LayerNode],
                                   sources: [SourceDefinition]) {
        defer { lastProgramWebSceneID = sceneID }
        guard lastProgramWebSceneID != sceneID else { return }
        for key in CaptureSourceKey.demanded(layers: layers, sources: sources) {
            guard case .web = key else { continue }
            webHosts[key]?.noteSceneEntry()
        }
    }

    /// Collapses keys that name the SAME physical device the default source
    /// already covers, so "the default camera" and "the default camera by
    /// unique ID" never open the device twice.
    /// Passive readiness probe: never pulls media playout (that would alter
    /// its render cadence). Camera reads enforce the existing freshness TTL.
    func frameAvailability(for key: CaptureSourceKey) -> Bool? {
        let key = normalized(key)
        switch key {
        case .camera: return frames.cameraFrame(for: key) != nil
        case .screen: return frames.screenFrame(for: key) != nil
        default: return nil
        }
    }

    private func normalized(_ key: CaptureSourceKey) -> CaptureSourceKey {
        guard case .camera(let payload) = key, let deviceID = payload.deviceID,
              let defaultDevice = AVCaptureDevice.default(for: .video),
              defaultDevice.uniqueID == deviceID else { return key }
        return .camera(CameraSourcePayload())
    }
}
