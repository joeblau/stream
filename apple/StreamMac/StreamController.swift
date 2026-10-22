import CryptoKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import StreamCore
import os
import os.lock

/// The heart of the macOS app: owns the capture sources (screen, camera, mic),
/// drives the `CompositionEngine` that renders the program scene onto the
/// output-profile canvas, and routes engine frames to the outputs (preview,
/// publisher, recording) as independent subscribers.
///
/// W03 (issue #66): preview and program are separate compositions. This
/// controller owns TWO engines — the program engine (composites the
/// `PreviewProgramModel`'s `programScene` snapshot; its frames feed the
/// publisher, the recording, and the PROGRAM monitor) and a lightweight
/// preview engine (composites `stagedScene` for the PREVIEW monitor only).
/// The preview engine ticks independently, so preview rendering work never
/// touches the program engine's cadence; both pull the same read-only
/// latest-frame source holders, so a Take restarts no capture and no clock.
///
/// W08 (issue #65): rendering lives in the `CompositionEngine` actor — a
/// Metal/Core Image compositor ticking at the profile fps on a shared
/// monotonic clock, broadcasting timestamped frames through bounded,
/// drop-oldest per-subscriber queues. Nothing on this main-actor controller
/// renders pixels anymore; it only configures the engines (scene, canvas,
/// fps) and manages subscriptions.
///
/// W07 (issue #64): the canvas is owned by the persisted `OutputProfile`, not
/// by the first arriving source frame — see `activeProfile`/`stagedProfile`
/// for the staged-vs-active application rules.
///
/// W02 (issue #62): preview, streaming, and recording are INDEPENDENT session
/// state machines (see SessionState.swift). The streaming machine is folded
/// from the publisher's own `PublisherEvent`s — LIVE only on an acknowledged
/// publish — so stopping preview or closing the window never silently kills an
/// active output: the engine stays up while ANY output demands frames.
///
/// S05 (issue #73): capture lifetime is registry-driven. Scenes no longer ask
/// for "the camera"/"the screen" — visible layers resolve through the
/// `SceneStore` source registry into `CaptureSourceKey`s (one per physical
/// device/display), and the `CaptureSourcePool` runs exactly one capture per
/// key while ≥1 layer in the staged OR program scene references it. A Take
/// between scenes sharing a source leaves that capture running (no flicker),
/// and a failure to start surfaces in the pool's per-source error state.
///
/// C10 (issue #79): device hot-plug, permission loss, and relinking. The
/// `DeviceMonitor` watches camera/display/audio availability; the pool marks
/// hot-unplugged sources MISSING (registry entry and demand survive, the
/// renderer paints nothing, unrelated sources and outputs keep running) and
/// resumes capture when the same stable identity returns. Screen-capture
/// errors probe Screen Recording permission (W06's `probeScreenAccess`), and
/// permission transitions retry blocked sources or mark revoked ones. A
/// relink is a registry `updateSource` — the `$sources` observation below
/// re-runs demand reconciliation so the replacement device/display takes
/// over every bound layer's capture.
///
/// One ordered video consumer serializes `appendVideo` into the publisher (a
/// `Task` per frame could reorder buffers); program audio reaches the publisher
/// through the A01 audio engine's program-bus tap (bounded, drop-oldest), which
/// lands on the same ordered audio ingress the iOS pipeline uses — pre-mixed,
/// so nothing is processed twice.
@MainActor
final class StreamController: ObservableObject {
    /// Streaming (publishing) output lifecycle — read `streamState`, never a bool.
    @Published private(set) var streamState: StreamSessionState = .idle
    /// On-screen monitor lifecycle (W03: both studio monitors). Independent
    /// from streaming/recording.
    @Published private(set) var previewState: PreviewSessionState = .idle
    @Published private(set) var previewResourceLevel: DesktopResourceBudget.PreviewLevel = .normal
    @Published private var monitorDeliveryFailures: [String: String] = [:]
    var previewResourceNotice: String? { monitorDeliveryFailures.values.sorted().first ?? previewResourceLevel.notice }
    /// The latest STAGED composition for the PREVIEW monitor, ~30 fps (W03:
    /// rendered by the preview engine, so staged edits never touch program).
    @Published private(set) var previewImage: CGImage?
    /// The latest PROGRAM composition for the PROGRAM monitor, ~30 fps.
    @Published private(set) var programImage: CGImage?
    @Published var errorMessage: String?
    @Published private(set) var isRehearsing = false
    private var rehearsalOwnsPreview = false
    private var rehearsalObserver: AnyCancellable?
    private var rehearsalToken: UUID?
    private weak var rehearsalRecorder: RecordingController?
    private var rehearsalStopRequested = false


    /// Convenience for UI; `streamState` carries the full picture.
    var isLive: Bool { streamState.isLive }
    var isPreviewing: Bool { previewState == .active }

    let resilience: DesktopResilienceCoordinator
    @Published private(set) var sourceFailoverStatus: [String] = []
    /// StudioRuntime wires the recorder stop; the lifecycle callback requests
    /// flushing immediately, without claiming to delay system sleep.
    var stopRecordingForLifecycle: (() -> Void)?
    private let resilientFrames: ResilientSourceFrames
    let guestVideoFrames: GuestVideoFrameStore
    private var guestLease: GuestReceiveLease?
    private var pendingGuestLease: GuestReceiveLease?
    private var lastGuestAdmissionGeneration: UInt64 = 0
    private var lastIssuedGuestGeneration: UInt64 = 0
    /// The dispatcher supplies current unsaved live mixer edits. A controller
    /// without that owner uses its loaded project settings.
    var guestMixerSettings: (() -> MixerSettings)?
    private var guestRegistration = UUID()
    private var guestMediaRetired = false
    #if STREAM_NATIVE_VALIDATION
    /// Owned synthetic PCM fixture only; never requests capture or OS consent.
    var guestTalkbackFixtureCapture: ((AudioChannelID) -> Bool)?
    #endif
    private var resilienceTask: Task<Void, Never>?
    private var failureTracker = SourceFailureTracker<CaptureSourceKey>()
    private var resilienceDemand: Set<CaptureSourceKey> = []
    private var fallbackOriginalScene: Scene?
    private var fallbackSceneID: SceneID?
    @Published private(set) var privacySlateActive = false
    private var privacySlateScene: Scene?
    private let privacyGate: ProgramPrivacyGate
    private var programBusGain: Float = 1

    let destinations: DestinationSession
    let sceneStore: SceneStore
    /// The S05 keyed capture pool (issue #73): one physical capture per
    /// source identity, started/stopped purely by scene demand. Exposes the
    /// per-source error state (`sourceErrors`), the C10 missing state
    /// (`missingSources`), and the engines' frame read path (`frames`).
    let capturePool = CaptureSourcePool()
    /// C10 (issue #79): camera/display/audio availability watcher. The pool
    /// subscribes through its hooks (wired in `init`); SwiftUI reads the
    /// published device lists for source health and relink pickers.
    let deviceMonitor = DeviceMonitor()
    /// Compatibility read for the diagnostics row: the capture instance behind
    /// the system-picker screen source. The pool vends a stable instance, so
    /// existing reads (`controller.screenCapture.isCapturing`) keep working.
    var screenCapture: ScreenSourceCapture { capturePool.screenCapture(for: .defaultScreen) }
    let audio = MacAudioInput()
    /// The A01 audio engine (issue #82): mixes every timestamped source (mic,
    /// per-screen-source audio, future media/NDI/guests) onto the same
    /// monotonic host clock the video engines anchor on, and fans the program
    /// mix out to the publisher and the recorder through independent bounded
    /// taps. Runs with the W02 pipeline demand.
    private let audioEngine: AudioMixEngine
    /// A07 (issue #119): headphone monitoring — plays the engine's MONITOR
    /// bus (same routing as program, own master gain, A04 solo-in-place) to
    /// the selected output device. Read by the settings UI for the device
    /// list and monitor state; driven by `applySavedSettings`.
    let monitorOutput = MonitorOutput()
    /// A07: the UID of the enabled INPUT device that is also the current
    /// monitor OUTPUT (feedback risk — the monitor signal would be re-captured
    /// electrically). Nil when monitoring is safe or off. Surfaced in the
    /// settings Audio section and the StudioState snapshot.
    @Published private(set) var monitorFeedbackRiskDeviceUID: String?
    /// A09 (issue #121): the latest feedback/echo diagnostics — per-mic howl
    /// risk from the tap-fed detectors, duplicate capture/feedback routes
    /// with concrete repairs, and the voice-isolation state. Refreshed by the
    /// diagnostics poll loop while the pipeline runs; surfaced in the
    /// settings Audio section and the StudioState snapshot.
    @Published private(set) var feedbackDiagnostics = FeedbackDiagnostics()
    /// A09: whether the macOS Voice Isolation mic mode is active on the
    /// default mic's capture device (nil = unknown or mode not preferred).
    /// Mic modes are user-controlled (the API is read-only), so Stream
    /// reports and guides rather than applying DSP itself.
    @Published private(set) var voiceIsolationActive: Bool?
    /// A09: capture-thread side of the feedback detectors (tap sinks feed it;
    /// the main actor only polls its readings).
    private let feedbackAnalyzer = FeedbackAnalyzer()
    private var feedbackDiagnosticsTask: Task<Void, Never>?
    private var feedbackMonitorTap: AudioTapSubscription?
    private var feedbackMicTaps: [AudioChannelID: AudioTapSubscription] = [:]
    /// A09: the last logged diagnostics signature, so support logs see
    /// transitions, not a 2 Hz repeat of the same warning set.
    private var lastLoggedFeedbackSignature = ""

    /// The W08 program composition engine: composites the program snapshot and
    /// fans frames out to the publisher, the recording, and the PROGRAM
    /// monitor. Pulls the latest screen/camera frames through the
    /// lock-protected holders below; runs only while the W02 pipeline demand
    /// is > 0.
    private let guestProgramReturnAuthority = NativeGuestProgramReturnAuthority()
    private weak var guestReturnVideoSink: NativeGuestMediaSink?
    private var guestReturnVideoRemovals: Set<UUID> = []
    private var guestSecondaryReturnTokens: Set<UUID> = []
    private var guestCleanReturnTokens: Set<UUID> = []
    private let engine: CompositionEngine
    private var programGeometryCommand: Task<Void, Never>?
    private var secondaryGeometryCommand: Task<Void, Never>?
    private var programGeometryGeneration = UUID()
    private var secondaryGeometryGeneration = UUID()
    /// The W03 preview engine: composites the STAGED scene for the PREVIEW
    /// monitor only. Same source providers, independent tick — preview work
    /// can never delay or re-anchor the program engine.
    private let previewEngine: CompositionEngine
    @Published private(set) var secondaryPreviewImage: CGImage?
    @Published private(set) var secondaryProgramImage: CGImage?
    @Published private(set) var activeSecondaryProfile = OutputProfile(canvasWidth: 720, canvasHeight: 1280, frameRate: 24)
    private var secondaryMonitorsEnabled = false
    private var secondaryPreviewSubscription: OptionalMonitorDelivery?
    private var secondaryProgramSubscription: OptionalMonitorDelivery?
    /// The W03 staged/program scene model; the engines follow its snapshots.
    private let previewProgram: PreviewProgramModel
    let destinationOutputs: DestinationOutputController
    /// One stable namespace for every raw-output isolation domain in this
    /// workspace. An output activation uses a separate fresh generation.
    var rawVideoResourceWorkspaceID: UUID { destinationOutputs.rawVideoResourceWorkspaceID }
    @Published private(set) var managedStart: ManagedYouTubeStartCoordinator?
    @Published private(set) var managedStartHasEntries = false
    private weak var managedStartAccounts: ProviderAccountSession?
    private var managedStartClosed = false
    private var managedStartEntriesObserver: AnyCancellable?
    private var managedStartAuthorityObserver: AnyCancellable?
    let ending = StudioEndingCoordinator()
    /// Captures + engine are up. Independent from preview: an active stream
    /// or recording keeps the pipeline running with the preview off (W02).
    private var isPipelineRunning = false
    /// Recording outputs share capture/audio but own their bounded video taps.
    private var recordingDemand = 0
    private var secondaryRecordingDemand = 0
    private var recordingEncoderReservations = StudioEncoderReservations()
    private var secondaryRecordingController: RecordingController?
    private weak var secondaryRecordingChat: StudioChatCoordinator?
    var secondaryRecorder: RecordingController {
        if let existing = secondaryRecordingController { return existing }
        let recorder = RecordingController(outputCanvas: .secondary)
        recorder.loadPreferences(directory: DesktopStorage.projectDirectory)
        if let secondaryRecordingChat { recorder.bindChat(secondaryRecordingChat) }
        secondaryRecordingController = recorder
        return recorder
    }
    func bindSecondaryRecordingChat(_ chat: StudioChatCoordinator) {
        secondaryRecordingChat = chat; secondaryRecordingController?.bindChat(chat)
    }
    func stopSecondaryRecording(completion: (() -> Void)? = nil) {
        if let secondaryRecordingController { secondaryRecordingController.stop(completion: completion) }
        else { completion?() }
    }
    var secondaryRecordingActiveOutputURLs: Set<URL> {
        secondaryRecordingController?.activeOutputURLs ?? []
    }
    func reserveRecordingEncoders(_ id: UUID, count: Int, canvas: OutputCanvas) -> String? {
        if canvas == .secondary {
            guard secondaryCanvasAvailable else { return "Take a configured secondary layout to Program before starting this video output." }
            guard IsolatedVideoBudget.current.qualified else { return "Additional canvas video output is not yet qualified on this Mac class. Run the native multi-encoder qualification first." }
            if let error = canvasStartError(destinations: [.init(name: "Secondary Recording", canvas: .secondary)]) { return error }
        }
        return recordingEncoderReservations.reserve(id, encoders: count, publishing: activePublishingEncoderCount)
    }
    func releaseRecordingEncoders(_ id: UUID) {
        recordingEncoderReservations.release(id)
        // A cancelled countdown/preflight never acquired pipeline demand, so
        // it must also release staged geometry without waiting for a stop tap.
        promoteStagedProfileIfOutputsIdle()
    }
    private var virtualCameraDemand = 0
    private var secondaryVirtualCameraDemand = 0
    private var virtualCameraController: VirtualCameraOutputController?
    var virtualCameraOutput: VirtualCameraOutputController {
        if let existing = virtualCameraController { return existing }
        let output = VirtualCameraOutputController { [weak self] format, referenceCanvas in
            guard let self, !self.resilience.isLocked else { throw CancellationError() }
            let canvas = self.outputCanvas(for: self.virtualCameraController?.feed, destinationID: self.virtualCameraController?.selectedDestinationID)
            if canvas == .secondary, !self.secondaryCanvasAvailable { throw CancellationError() }
            if canvas == .secondary, let error = self.canvasStartError(destinations: [.init(name: "Virtual Camera", canvas: .secondary)]) {
                throw VirtualCameraProducer.Failure(message: error)
            }
            let domain = StableFrameDomainID(workspace: self.rawVideoResourceWorkspaceID, kind: .virtualCamera,
                outputID: "virtual-camera", plane: canvas == .secondary ? .secondary : .program)
            let generation = UUID(), token = UUID()
            let engine = self.engine
            let sourceRequest = try engine.sourceFrameResourceRequest(
                canvasSize: canvas == .secondary ? self.activeSecondaryProfile.canvasSize : self.activeProfile.canvasSize, canvas: canvas)
            let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([sourceRequest, .init(domain: domain,
                descriptor: .init(width: format.width, height: format.height, capacity: 4), sessionGeneration: generation)])
            guard let bank = receipt.bank(for: domain), let sourceBank = receipt.bank(for: sourceRequest.domain) else {
                RawVideoResourceCoordinator.shared.rollback(receipt)
                throw RawVideoResourceFailure.unknownReservation
            }
            let sourceReceipt: RawVideoResourceReceipt
            do { sourceReceipt = try receipt.selecting(domain: sourceRequest.domain) }
            catch { RawVideoResourceCoordinator.shared.rollback(receipt); throw error }
            let privateReceipt: RawVideoResourceReceipt
            do { privateReceipt = try receipt.selecting(domain: domain) }
            catch {
                RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
                RawVideoResourceCoordinator.shared.rollback(receipt)
                throw error
            }
            let state = VirtualCameraFrameInstallState()
            let cadence = FrameDeliveryCameraCadence()
            self.virtualCameraDemand += 1
            if canvas == .secondary { self.secondaryVirtualCameraDemand += 1 }
            self.updatePipelineDemand()
            return VirtualCameraFrameAdmission(bank: bank, cadence: cadence, install: { [weak self] sink in
                guard let self, !self.resilience.isLocked, !state.cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                let cancellation = state.cancellation
                let lease = try await engine.installFrameDelivery(token: token, domain: domain, generation: generation,
                    bank: bank, sourceBank: sourceBank, sourceReceipt: sourceReceipt,
                    transfer: .virtualCameraBGRA(referenceCanvas: referenceCanvas, cadence: cadence), capacity: 1, cancellation: cancellation,
                    canvas: canvas, authorized: { !cancellation.isCancelled }) { sink($0.sampleBuffer) }
                state.lease = lease
                guard !cancellation.isCancelled, !Task.isCancelled, !self.resilience.isLocked else {
                    await engine.removeFrameDelivery(lease)
                    throw CancellationError()
                }
            }, cancel: { [weak self] in
                state.cancellation.cancel()
                guard !state.cancelled else { return }
                state.cancelled = true
                let lease = state.lease
                Task { @MainActor [weak self] in
                    if let lease { await engine.removeFrameDelivery(lease) }
                    else { await engine.cancelFrameDelivery(token: token) }
                    // Never-exposed preparation can roll back; every escaped
                    // pixel keeps its complete old-generation reservation.
                    RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
                    RawVideoResourceCoordinator.shared.rollback(privateReceipt)
                    RawVideoResourceCoordinator.shared.rollback(receipt)
                    guard let self else { return }
                    self.virtualCameraDemand = max(0, self.virtualCameraDemand - 1)
                    if canvas == .secondary { self.secondaryVirtualCameraDemand = max(0, self.secondaryVirtualCameraDemand - 1) }
                    self.promoteStagedProfileIfOutputsIdle()
                    self.updatePipelineDemand()
                }
            })
        }
        virtualCameraController = output
        return output
    }
    func stopVirtualCameraOutput() { virtualCameraController?.stop() }
    private var externalDisplayDemand = 0
    private var secondaryExternalDisplayDemand = 0
    private var cleanExternalDisplayDemand = 0
    private let externalDisplayScreens: @MainActor () -> [ExternalDisplayDescriptor]
    private let externalDisplaySurface: @MainActor (ExternalDisplayDescriptor) -> (any ExternalDisplaySurface)?
    private var externalDisplayController: ExternalDisplayOutputController?
    private var externalDisplayRetirement: Task<Void, Never>?
    var externalDisplayOutput: ExternalDisplayOutputController {
        if let existing = externalDisplayController { return existing }
        let output = ExternalDisplayOutputController(screensProvider: externalDisplayScreens, surfaceFactory: externalDisplaySurface, startError: { [weak self] feed in
            guard let self else { return "The studio is unavailable." }
            return self.externalDisplayStartError(feed, destinationID: self.externalDisplayController?.selectedDestinationID)
        }) { [weak self] request, sink in
            guard let self else { throw CancellationError() }
            await self.externalDisplayRetirement?.value
            try Task.checkCancellation()
            let feed = request.feed
            if let error = self.externalDisplayStartError(feed, destinationID: request.selectedDestinationID) {
                throw OptionalFrameDeliveryFailure(message: error)
            }
            let canvas = self.outputCanvas(for: feed, destinationID: request.selectedDestinationID)
            let sourceProfile = canvas == .secondary ? self.activeSecondaryProfile : self.activeProfile
            let targetProfile = request.profile ?? sourceProfile
            try self.validateExternalDisplayTarget(request)
            let domain = StableFrameDomainID(workspace: self.rawVideoResourceWorkspaceID, kind: .externalDisplay,
                outputID: "external-display", plane: feed == .clean ? .clean : canvas == .secondary ? .secondary : .program)
            let cleanPermit = feed == .clean ? ExternalCleanRenderPermit() : nil
            // Atomic source4 + private5 admission precedes pipeline demand and
            // the controller's later native surface construction.
            let delivery = try OptionalFrameDelivery(engine: self.engine, domain: domain,
                width: targetProfile.canvasWidth, height: targetProfile.canvasHeight,
                sourceSize: sourceProfile.canvasSize, transfer: .aspectFitBGRA, canvas: canvas,
                clean: feed == .clean, authorized: { cleanPermit?.isActive ?? true })
            let converter = ExternalProgramImageConverter()
            self.externalDisplayDemand += 1
            if cleanPermit != nil { self.cleanExternalDisplayDemand += 1 }
            if canvas == .secondary { self.secondaryExternalDisplayDemand += 1 }
            let cancellation = OptionalOutputCancellation { [weak self] in
                cleanPermit?.finish(); delivery.finish()
                let retirement = Task { @MainActor [weak self] in
                    await delivery.finishAndWait()
                    guard let self else { return }
                    self.externalDisplayDemand = max(0, self.externalDisplayDemand - 1)
                    if cleanPermit != nil { self.cleanExternalDisplayDemand = max(0, self.cleanExternalDisplayDemand - 1) }
                    if canvas == .secondary { self.secondaryExternalDisplayDemand = max(0, self.secondaryExternalDisplayDemand - 1) }
                    self.promoteStagedProfileIfOutputsIdle()
                    self.updatePipelineDemand()
                }
                self?.externalDisplayRetirement = retirement
            }
            self.updatePipelineDemand()
            do {
                return try await withTaskCancellationHandler {
                    try await self.awaitFrameDeliveryGeometry(canvas: canvas, expectedSize: sourceProfile.canvasSize)
                    try Task.checkCancellation()
                    try self.validateExternalDisplayTarget(request)
                    if let error = self.externalDisplayStartError(feed, destinationID: request.selectedDestinationID) {
                        throw OptionalFrameDeliveryFailure(message: error)
                    }
                    try await delivery.install { frame in
                        if let image = converter.image(frame) { sink(image) }
                    }
                    try Task.checkCancellation()
                    try self.validateExternalDisplayTarget(request)
                    return { cancellation.finish() }
                } onCancel: {
                    cleanPermit?.finish()
                    delivery.finish()
                }
            } catch {
                cancellation.finish()
                throw error
            }
        }
        externalDisplayController = output
        return output
    }
    func stopExternalDisplayOutput() { externalDisplayController?.stop() }
    /// The PREVIEW monitor's preview-engine subscription (staged composition).
    private var previewMonitorSubscription: OptionalMonitorDelivery?
    /// The PROGRAM monitor's program-engine subscription (registered while the
    /// monitors are visible; the publisher/recording have their own sinks).
    private var programMonitorSubscription: OptionalMonitorDelivery?
    /// Converts staged-composition frames to CGImages, off the main actor.
    /// Converts program-composition frames to CGImages, off the main actor.
    private let resourcePreviewThrottle = DesktopPreviewThrottle()
    private var previewGeometryCommand: Task<Void, Never>?
    private var previewGeometryGeneration = UUID()
    private var resourceBudgetCoordinator: DesktopResourceBudgetCoordinator?

    private var settings: StreamSettings = .default
    private let settingsStore = DesktopSettingsStore()
    /// The W06 permission center (issue #69), shared with the app root. C10:
    /// status transitions drive capture recovery (a re-granted permission
    /// retries the sources its denial blocked; a camera revocation marks the
    /// affected sources), and screen-capture errors trigger its revocation
    /// probe.
    private let permissions: PermissionsManager
    /// The permission statuses seen at the last change fold, so only real
    /// transitions act (`$statuses` republishes on every refresh).
    private var lastPermissionStatuses: [PermissionsManager.Kind: PermissionsManager.Status] = [:]
    private var permissionRecoveryRevisions: [PermissionsManager.Kind: UUID] = [:]
    /// Hardware + destination gating for the output profile (W07); the single
    /// auditable capability place lives in StreamCore's OutputCapabilities.
    private let capabilities = OutputCapabilities.current
    /// The canvas + fps the pipeline renders at RIGHT NOW (W07, issue #64).
    /// Owned by the persisted `StreamSettings.outputProfile`, never derived
    /// from the first source frame: sources are aspect-fit into this fixed
    /// canvas, so a source's native size changing mid-program never resizes
    /// the output. Changes apply only at a compatible output (re)start.
    @Published private(set) var activeProfile: OutputProfile
    /// A profile edit waiting for the active stream/recording to end; non-nil
    /// means "applies on next session". The settings UI marks this state.
    @Published private(set) var stagedProfile: OutputProfile?
    private var cancellables: Set<AnyCancellable> = []

    init(sceneStore: SceneStore, previewProgram: PreviewProgramModel,
         permissions: PermissionsManager,
         audioEngine: AudioMixEngine = AudioMixEngine(),
         externalDisplayScreens: @escaping @MainActor () -> [ExternalDisplayDescriptor] = ExternalDisplayOutputController.systemDisplays,
         externalDisplaySurface: @escaping @MainActor (ExternalDisplayDescriptor) -> (any ExternalDisplaySurface)? = { NativeExternalDisplaySurface(display: $0) },
         publisherFactory: @escaping (StreamCore.StreamProtocol) -> any Publisher = { transport in
             switch transport {
             case .rtmp, .rtmps: return RTMPPublisher()
             case .srt, .whip: return SessionPublisher(protocol: transport)
             }
         }) {
        self.audioEngine = audioEngine
        self.externalDisplayScreens = externalDisplayScreens
        self.externalDisplaySurface = externalDisplaySurface
        self.sceneStore = sceneStore
        self.previewProgram = previewProgram
        self.permissions = permissions
        self.destinationOutputs = DestinationOutputController(factory: publisherFactory)
        // The persisted profile is the canvas authority from launch, so the
        // preview opens at the configured geometry before any source frame
        // ever arrives.
        let persisted = settingsStore.load()
        self.destinations = DestinationSession(settings: persisted)
        self.resilience = DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"))
        self.programBusGain = persisted.mixer.mutedBuses.contains(AudioBus.program.rawValue) ? 0 : Float(persisted.mixer.busGains[AudioBus.program.rawValue] ?? 1)
        self.settings = persisted
        self.activeProfile = persisted.outputProfile
        self.capturePool.browserAudioMixer = audioEngine

        // The engines pull source pixels off-main through the pool's frame
        // providers; they never touch this controller's MainActor state. Both
        // engines share the same read-only providers (W03: one capture feeds
        // both the staged preview and the outgoing program; S05: the pool
        // keys those captures by source identity).
        let frames = capturePool.frames
        let guestFrames = GuestVideoFrameStore()
        self.guestVideoFrames = guestFrames
        let resilientFrames = ResilientSourceFrames(raw: SourceFrameLookup(
            camera: { key in frames.hasCameraSource(for: key) ? frames.cameraFrame(for: key) : frames.freshestCameraFrame() },
            screen: { key in frames.hasScreenSource(for: key) ? frames.screenFrame(for: key) : frames.latestScreenFrame() },
            media: { key in frames.hasMediaSource(for: key) ? frames.mediaFrame(for: key) : nil },
            guest: { payload, time in
                guard let slot = payload.slotID else { return nil }
                return guestFrames.pixels(slot: slot, role: payload.role == .camera ? .camera : .screen,
                                          at: time, program: true)
            }))
        self.resilientFrames = resilientFrames
        let privacyGate = ProgramPrivacyGate()
        self.privacyGate = privacyGate
        self.engine = CompositionEngine(
            screenProvider: { frames.latestScreenFrame() },
            cameraProvider: { frames.freshestCameraFrame() },
            frameLookup: resilientFrames.lookup,
            overlayContextProvider: { privacyGate.overlays() },
            annotationProvider: { privacyGate.annotations() },
            canvasSize: persisted.outputProfile.canvasSize,
            frameRate: persisted.outputProfile.frameRate,
            frameOverrideProvider: { privacyGate.sceneSnapshot() })
        self.previewEngine = CompositionEngine(
            screenProvider: { frames.latestScreenFrame() },
            cameraProvider: { frames.freshestCameraFrame() },
            frameLookup: SourceFrameLookup(
                camera: { key in frames.hasCameraSource(for: key) ? frames.cameraFrame(for: key) : frames.freshestCameraFrame() },
                screen: { key in frames.hasScreenSource(for: key) ? frames.screenFrame(for: key) : frames.latestScreenFrame() },
                media: { key in frames.hasMediaSource(for: key) ? frames.mediaFrame(for: key) : nil },
                pdf: { key, size in frames.mediaFrame(for: key, canvasSize: size) },
                guest: { payload, time in
                    guard let slot = payload.slotID else { return nil }
                    return guestFrames.pixels(slot: slot, role: payload.role == .camera ? .camera : .screen,
                                              at: time, program: false)
                }),
            // G11 (issue #117): preview shows annotations as SwiftUI chrome in
            // CanvasInteractionView — painting them into the image too would
            // double-draw them.
            annotationProvider: { .empty },
            canvasSize: persisted.outputProfile.canvasSize,
            frameRate: persisted.outputProfile.frameRate)
        OutputCanvasStore.shared.publish(persisted.outputProfile.canvasSize)
        resilience.stopOutputs = { [weak self] in
            guard let self else { return }
            self.audioEngine.cancelGuestTalkback()
            self.stopStream(); self.stopRecordingForLifecycle?(); self.stopSecondaryRecording(); self.stopExternalDisplayOutput(); self.stopVirtualCameraOutput(); self.stopPreview()
            self.resilientFrames.clear()
        }
        resilience.showOfflineSlate = { [weak self] in self?.enterPrivacySlate() }
        resilience.startPreview = { [weak self] in self?.startPreview() }
        resilience.refreshSources = { [weak self] in
            self?.permissions.refresh(); self?.reconcileSourceDemand()
            self?.handlePermissionChange(resumeAvailable: true)
        }
        resilience.$policy.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconcileSourceDemand(); self?.evaluateSourceResilience() }
        }.store(in: &cancellables)

        // W03: scene edits and selection changes reach the engines ONLY
        // through the preview/program model's snapshots — never straight from
        // SceneStore — so staged work can't leak into the outgoing program.
        previewProgram.$stagedScene
            .sink { [weak self] scene in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileSourceDemand()
                    let engine = self.previewEngine
                    self.updateSecondaryGeometryIfIdle()
                    Task { await engine.updateScene(scene) }
                }
            }
            .store(in: &cancellables)
        previewProgram.$programScene
            .sink { [weak self] scene in
                Task { @MainActor [weak self] in
                    guard let self, let scene else { return }
                    if self.privacySlateActive, let slate = self.privacySlateScene, scene.id != slate.id {
                        // A Take while the privacy hold is active may update the
                        // restore target, but cannot show private pixels on air.
                        self.fallbackOriginalScene = scene
                        self.previewProgram.setResilienceProgram(slate)
                        return
                    }
                    self.reconcileSourceDemand()
                    self.publishSceneToProgram(scene)
                }
            }
            .store(in: &cancellables)

        // C10 (issue #79): device hot-plug and permission-loss wiring.
        // The DeviceMonitor reports stable identities; the pool moves exactly
        // the affected sources between active and missing.
        let capturePool = self.capturePool
        deviceMonitor.onCameraDisconnected = { uniqueID in
            capturePool.handleCameraDisconnected(uniqueID)
        }
        deviceMonitor.onCameraConnected = { uniqueID in
            capturePool.handleCameraConnected(uniqueID)
        }
        deviceMonitor.onDisplaysChanged = { displayIDs in
            capturePool.handleDisplaysChanged(displayIDs: displayIDs)
        }
        // A05 (issue #84): audio input hot-plug routes to the audio input
        // layer — the DeviceMonitor is the one availability watcher, so
        // MacAudioInput keeps no notifications of its own. An unplug stops
        // only that device's channel; a return on the same uniqueID resumes.
        let audio = self.audio
        deviceMonitor.onAudioDeviceConnected = { _ in
            audio.noteAudioDeviceConnected()
        }
        deviceMonitor.onAudioDeviceDisconnected = { _ in
            audio.noteAudioDeviceDisconnected()
        }
        // W06's noted wiring: a screen-capture error (start failure or
        // mid-capture stop) probes Screen Recording permission — preflight
        // lags a System Settings revocation, so the probe is what flips the
        // source's repair state honestly.
        capturePool.onScreenCaptureError = { [permissions] in
            Task { await permissions.probeScreenAccess() }
        }
        // Relink closes the capture loop here: a registry update (S05
        // `updateSource`/`relinkSource`) re-keys the demand, so the old
        // source's capture stops and the replacement's starts.
        sceneStore.$sources
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileSourceDemand()
                }
            }
            .store(in: &cancellables)
        // Permission transitions: a re-grant retries blocked sources (and
        // mic capture), a camera revocation marks the affected sources —
        // other sources and outputs keep running untouched.
        lastPermissionStatuses = permissions.statuses
        if permissions.status(for: .microphone) == .denied {
            audioEngine.denyCapturePermission(.microphone)
            audio.setPermissionAvailable(false)
        }
        if permissions.status(for: .screenCapture) == .denied {
            audioEngine.denyCapturePermission(.screenCapture)
            capturePool.noteScreenPermissionRevoked()
        }
        permissions.$statuses
            .sink { [weak self] statuses in
                // This @Published property is written only by its MainActor
                // owner. Fold the emitted value (willSet), preserving every
                // deny/regrant edge before another capture callback can run.
                MainActor.assumeIsolated {
                    self?.handlePermissionChange(snapshot: statuses)
                }
            }
            .store(in: &cancellables)

        // Capture callbacks may arrive on ScreenCaptureKit / audio queues.
        // Screen video frames land in the pool's per-source holders (wired
        // inside the pool). A01 (issue #82): ALL source audio — the mic and
        // every screen capture's app audio, each under its own stable channel
        // ID — flows into the audio engine's nonisolated, lock-confined
        // ingest; the engine mixes once and the publisher/recorder tap the
        // program bus (below), replacing the old direct enqueueMic/enqueueApp
        // path. Both hand-offs fire off the main actor.
        let publisherBox = destinationOutputs.fanout
        let audioEngine = self.audioEngine
        capturePool.onScreenAudioSample = { key, sample in
            audioEngine.enqueue(.capture(key), sample)
        }
        // A02 (issue #97): media-source audio (pulled on the composition
        // tick, already retimed onto the shared host clock) rides the same
        // ingest, keyed by registry source ID — the `.media` channel kind.
        capturePool.onMediaAudioSample = { id, sample in
            audioEngine.enqueue(.media(id), sample)
        }
        // A06 (issue #118): app/system audio-only captures ride the same
        // ingest, keyed by the target's bundle ID — the `.application`
        // channel kind the A01 engine and A04 mixer already define. These
        // channels are mixer-owned (never scene-bound): no S05
        // `AudioBinding` addresses them, so their level is the persisted
        // mixer fader, independent of every scene.
        capturePool.onAppAudioSample = { key, sample in
            guard case .appAudio(let payload) = key else { return }
            audioEngine.enqueue(.application(bundleID: payload.channelBundleID), sample)
        }
        audio.onMicSampleOffMain = { sample in
            audioEngine.enqueue(.microphone(deviceUID: nil), sample)
        }
        // A05 (issue #84): additional input devices feed their own
        // UID-pinned channels the same way (buffers arrive already
        // channel-mapped from the device's own capture queue).
        audio.onDeviceSampleOffMain = { uid, sample in
            audioEngine.enqueue(.microphone(deviceUID: uid), sample)
        }
        // The publisher output taps the program bus once for the controller's
        // lifetime: the tap's bounded mailbox sheds chunks rather than ever
        // stalling the mix, and chunks are simply dropped while no publisher
        // owns the session (same contract as the publisher video sink below).
        addProgramAudioTap { [publisherBox] sample in
            publisherBox.enqueueAudio(sample)
        }
        // A07 (issue #119): the monitor output taps the MONITOR bus once for
        // the controller's lifetime, the same way — while monitoring is off
        // the player sheds chunks at negligible cost, so enabling/disabling
        // never re-keys the engine's tap table. The monitor path is a
        // read-only tap: it can never feed back into the mix by construction.
        addMonitorAudioTap { [monitorOutput] sample in
            monitorOutput.play(sample)
        }
        monitorOutput.applyConfiguration(enabled: persisted.monitoringEnabled,
                                         deviceUID: persisted.monitorOutputDeviceUID)
        monitorOutput.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateMonitorFeedbackRisk()
                }
            }
            .store(in: &cancellables)

        // Raw video is registered per independent publisher/shared encoder
        // lineage. Installation ACK precedes publisher.start; there is no
        // aggregate publisher stream retaining compositor-backed samples.
        let engine = self.engine
        destinationOutputs.frameDelivery = .init(sourceRequest: { size, canvas in
            try engine.sourceFrameResourceRequest(canvasSize: size, canvas: canvas)
        }, install: { [weak self] token, domain, generation, bank, sourceBank, sourceReceipt, transfer, canvas, cancellation, authorized, sink in
            guard let self, let sourceBank, sourceReceipt != nil else { throw CancellationError() }
            try await self.awaitFrameDeliveryGeometry(canvas: canvas,
                expectedSize: CGSize(width: sourceBank.descriptor.width, height: sourceBank.descriptor.height))
            return try await engine.installFrameDelivery(token: token, domain: domain, generation: generation,
                bank: bank, sourceBank: sourceBank, sourceReceipt: sourceReceipt,
                transfer: transfer, capacity: 2, cancellation: cancellation, canvas: canvas, authorized: authorized, sink: sink)
        }, remove: { lease, _ in _ = await engine.removeFrameDelivery(lease) },
           cancel: { token, _ in await engine.cancelFrameDelivery(token: token) },
           statistics: { lease, _ in await engine.frameDeliveryStatistics(lease) })
        destinationOutputs.startIsCurrent = { [weak self] destination in
            guard let self else { return false }
            return !self.resilience.isLocked && !self.isRehearsing &&
                self.destinations.saved.first(where: { $0.id == destination.id }) == destination
        }
        destinationOutputs.stateDidChange = { [weak self] in self?.destinationsDidChange() }
        // A10 (issue #122): push the persisted delays/ducking onto the
        // engines once, so the first pipeline start is already aligned — the
        // engine-side maps (registry delays, delay lines, duck config) all
        // survive (re)starts, so this covers every later start too.
        syncDelays(persisted)
        syncDucking(persisted.ducking)
        resourceBudgetCoordinator = DesktopResourceBudgetCoordinator(
            reportURL: DesktopStorage.machineDirectory.appendingPathComponent("resource-budget.v1.json"),
            metrics: { [weak self] in
                guard let self else { return CompositionMetrics() }
                return await self.engine.metricsSnapshot()
            }, apply: { [weak self] in self?.applyResourcePreviewBudget($0) })
    }

    /// Live encode/uplink metrics for the stats HUD, straight from the publisher.
    func statsSnapshot() async -> LiveStats? {
        await destinationOutputs.statsSnapshot()
    }

    func diagnosticSnapshot() async -> StudioDiagnosticSnapshot {
        var snapshot = StudioDiagnosticSnapshot()
        snapshot.profileWidth = activeProfile.canvasWidth
        snapshot.profileHeight = activeProfile.canvasHeight
        snapshot.targetFPS = activeProfile.frameRate
        snapshot.program = await engine.metricsSnapshot()
        snapshot.preview = await previewEngine.metricsSnapshot()
        snapshot.programKernel = await engine.kernelMetricsSnapshot()
        snapshot.previewKernel = await previewEngine.kernelMetricsSnapshot()
        snapshot.programClock = destinationOutputs.fanout.programClock.snapshot()
        snapshot.secondaryClock = destinationOutputs.fanout.secondaryClock.snapshot()
        snapshot.streamState = switch streamState {
        case .idle: "idle"
        case .connecting: "connecting"
        case .live: "live"
        case .reconnecting: "reconnecting"
        case .stopping: "stopping"
        case .failed: "failed"
        }
        for source in sceneStore.sources.prefix(256) {
            if case .guest(let payload) = source.payload {
                let health = guestVideoFrames.sourceHealth(slot: payload.slotID,
                    role: payload.role == .camera ? .camera : .screen,
                    at: CMClockGetTime(CMClockGetHostTimeClock()))
                snapshot.sources.append(.init(id: source.id.description, kind: source.payload.kind,
                    state: health.state, deliveredFrames: health.deliveredFrames))
                continue
            }
            var keys = CaptureSourceKey.demanded(layers: [LayerNode(name: "", sourceID: source.id, payload: source.payload, transform: .fullscreen)], sources: sceneStore.sources)
            if case .appAudio(let payload) = source.payload { keys.insert(.appAudio(payload)) }
            let state: String
            if keys.contains(where: { capturePool.sourceErrors[$0] != nil }) { state = "failed" }
            else if !keys.isDisjoint(with: capturePool.missingSources) { state = "unavailable" }
            else if !keys.isDisjoint(with: capturePool.activeSources) { state = "capturing" }
            else { state = keys.isEmpty ? "ready" : "inactive" }
            let count = keys.compactMap { SourceFrameProviders.shared.deliveryCount(for: $0) }.first
            let clock = keys.map { SourceFrameProviders.shared.captureClock(for: $0) }.first { $0.state != .unsupported } ?? .unsupported
            snapshot.sources.append(.init(id: source.id.description, kind: source.payload.kind, state: state, deliveredFrames: count, captureClock: clock))
        }
        snapshot.outputs = await destinationOutputs.diagnosticsSnapshot()
        let audio = await audioEngine.statsSnapshot()
        // Runtime labels identify the affected local channel. Only the bounded
        // redacted export boundary serializes these; it pseudonymizes every
        // audio key consistently across clocks/underruns/tap drops per bundle.
        snapshot.audioUnderruns = Dictionary(uniqueKeysWithValues: audio.channels.map { ($0.key, $0.value.underrunFrames) })
        snapshot.audioTapDrops = audio.tapDrops
        snapshot.sourceAudioClocks = audioEngine.sourceClockSnapshots(videoReference: destinationOutputs.fanout.programClock)
        snapshot.resourcePreviewLevel = previewResourceLevel.rawValue
        if let resource = resourceBudgetCoordinator?.latestSnapshot {
            snapshot.resourceSampleAgeMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - resource.uptime) * 1_000
            if resourceBudgetCoordinator?.hasCPUDelta == true { snapshot.resourceCPUCapacityPercent = resource.cpuFraction * 100 }
            snapshot.currentResidentBytes = resource.residentBytes
            snapshot.physicalFootprintBytes = resource.physicalFootprintBytes
            snapshot.metalAllocatedBytes = resource.metalAllocatedBytes
            snapshot.mainActorDelayMilliseconds = resource.mainActorDelayMilliseconds
        }
        if let metal = resourceBudgetCoordinator?.metalCapabilities {
            snapshot.metalUnifiedMemory = metal.unifiedMemory
            snapshot.metalRecommendedWorkingSetBytes = metal.recommendedWorkingSetBytes
            snapshot.metalCounterSetCount = metal.counterSets.count
        }
        snapshot.sampleProcess()
        return snapshot
    }

    // MARK: - Frame subscriptions (W08 fan-out)

    /// Opaque handle for an engine frame subscription. Cheap to create on the
    /// caller's side; register/cancel are delivered to the engine actor
    /// asynchronously and are race-safe (a cancel landing before its register
    /// is still honored).
    struct FrameSubscription: Hashable, Sendable {
        fileprivate let token = UUID()
    }

    /// Subscribes an output to composited program frames. The sink runs on the
    /// subscription's own bounded (default 2, drop-oldest) serial queue — a
    /// slow consumer sheds its own frames and can never stall the engine or
    /// the other outputs.
    @discardableResult
    func addFrameSink(capacity: Int = 2,
                      canvas: OutputCanvas = .program,
                      sink: @escaping @Sendable (CompositedFrame) -> Void) -> FrameSubscription {
        let subscription = FrameSubscription()
        Task { await engine.addSink(token: subscription.token, capacity: capacity, canvas: canvas, sink: sink) }
        return subscription
    }

    /// Await only the existing authoritative geometry command. Output startup
    /// never overwrites geometry from a captured plan or polls/retries a bank.
    func awaitFrameDeliveryGeometry(canvas: OutputCanvas = .program, expectedSize: CGSize) async throws {
        let generation = canvas == .program ? programGeometryGeneration : secondaryGeometryGeneration
        let command = canvas == .program ? programGeometryCommand : secondaryGeometryCommand
        await command?.value
        try Task.checkCancellation()
        let actualSize = await engine.frameDeliveryCanvasSize(canvas: canvas)
        try Task.checkCancellation()
        let currentGeneration = canvas == .program ? programGeometryGeneration : secondaryGeometryGeneration
        let currentSize = canvas == .program ? activeProfile.canvasSize : activeSecondaryProfile.canvasSize
        guard generation == currentGeneration, currentSize == expectedSize, actualSize == expectedSize else {
            throw RawVideoResourceFailure.sessionConflict
        }
    }

    func sourceFrameResourceRequest(canvasSize: CGSize, canvas: OutputCanvas = .program,
                                    clean: Bool = false) throws -> RawVideoResourceRequest {
        try engine.sourceFrameResourceRequest(canvasSize: canvasSize, canvas: canvas, clean: clean)
    }

    /// The caller has already synchronously admitted this exact bank. The
    /// returned lease acknowledges registration, before any opaque output start.
    func installFrameDelivery(token: UUID, domain: StableFrameDomainID, generation: UUID,
                              bank: RawVideoResourceBank, sourceBank: RawVideoResourceBank?, sourceReceipt: RawVideoResourceReceipt?,
                              transfer: FrameDeliveryTransfer = .copyBGRA,
                              capacity: Int = 2, canvas: OutputCanvas = .program, clean: Bool = false,
                              cancellation: FrameDeliveryCancellation,
                              authorized: @escaping @Sendable () -> Bool = { true },
                              sink: @escaping @Sendable (CompositedFrame) -> Void) async throws -> FrameDeliveryLease {
        guard let sourceBank, sourceReceipt != nil else { throw FrameDeliveryFailure.invalidBank }
        try await awaitFrameDeliveryGeometry(canvas: canvas,
            expectedSize: CGSize(width: sourceBank.descriptor.width, height: sourceBank.descriptor.height))
        return try await engine.installFrameDelivery(token: token, domain: domain, generation: generation,
            bank: bank, sourceBank: sourceBank, sourceReceipt: sourceReceipt,
            transfer: transfer, capacity: capacity, cancellation: cancellation, canvas: canvas, clean: clean, authorized: authorized, sink: sink)
    }
    @discardableResult
    func removeFrameDelivery(_ lease: FrameDeliveryLease) async -> FrameDeliveryStatistics { await engine.removeFrameDelivery(lease) }
    func cancelFrameDelivery(token: UUID) async { await engine.cancelFrameDelivery(token: token) }
    func frameDeliveryStatistics(_ lease: FrameDeliveryLease) async -> FrameDeliveryStatistics { await engine.frameDeliveryStatistics(lease) }

    @discardableResult
    func addCleanFrameSink(capacity: Int = 1, authorized: @escaping @Sendable () -> Bool = { true }, sink: @escaping @Sendable (CompositedFrame) -> Void) -> FrameSubscription {
        let subscription = FrameSubscription()
        Task { await engine.addCleanSink(token: subscription.token, capacity: capacity, authorized: authorized, sink: sink) }
        return subscription
    }

    func removeFrameSink(_ subscription: FrameSubscription) {
        Task { await engine.removeSink(subscription.token) }
    }

    // MARK: - Program audio taps (A01 fan-out, issue #82)

    /// Opaque handle for a program-bus audio tap; same race-safe
    /// register/cancel contract as `FrameSubscription`.
    struct AudioTapSubscription: Hashable, Sendable {
        fileprivate let token = UUID()
    }

    /// Taps the audio engine's PROGRAM bus (the master mix: every routed
    /// source, post-fader, 48 kHz stereo). Each tap is an independent bounded
    /// (~85 ms default), drop-oldest queue on its own serial queue, so the
    /// recorder and the publisher keep flowing independently and a slow
    /// consumer sheds only its own chunks (the W02 rule, applied to audio).
    @discardableResult
    func addProgramAudioTap(capacity: Int = 8,
                            sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription {
        let subscription = AudioTapSubscription()
        Task { await audioEngine.addTap(bus: .program, token: subscription.token,
                                        capacity: capacity, sink: sink) }
        return subscription
    }

    /// A07 (issue #119): taps the audio engine's MONITOR bus — the same
    /// channel routing as program with its own master gain and the A04
    /// monitor-only solo applied. Used by the headphone-monitoring output;
    /// same bounded, drop-oldest, race-safe contract as the program taps.
    @discardableResult
    func addMonitorAudioTap(capacity: Int = 8,
                            sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription {
        let subscription = AudioTapSubscription()
        Task { await audioEngine.addTap(bus: .monitor, token: subscription.token,
                                        capacity: capacity, sink: sink) }
        return subscription
    }

    private var isolatedCaptureSubscriptions: [AudioTapSubscription: CaptureSourceKey] = [:]
    struct RecordingVideoSubscription: Hashable { let id = UUID() }
    private var isolatedVideoCaptureSubscriptions: [RecordingVideoSubscription: CaptureSourceKey] = [:]

    func recordingVideoSources() -> [RecordingVideoSource] {
        let defaults = [SourceDefinition(name: "Default Camera", payload: .camera(CameraSourcePayload())),
                        SourceDefinition(name: "Selected Screen", payload: .screen(ScreenSourcePayload()))]
        let catalog = [("video.defaultCamera", defaults[0]), ("video.defaultScreen", defaults[1])] + sceneStore.sources.compactMap { source -> (String, SourceDefinition)? in
            switch source.payload { case .camera, .screen, .guest: return ("source.\(source.id)", source); default: return nil }
        }
        return catalog.map { id, source in
            if case .guest(let payload) = source.payload {
                let available = guestLease?.slot == payload.slotID && payload.slotID != nil
                return .init(id: id, name: source.name, isAvailable: available,
                             unsupportedReason: available ? nil : "Register this guest slot before recording.")
            }
            guard let key = Self.videoCaptureKey(source.payload) else {
                return .init(id: id, name: source.name, isAvailable: false, unsupportedReason: "Guest video capture is not implemented.")
            }
            let normalized = capturePool.recordingCaptureKey(for: key)
            let available: Bool
            switch normalized {
            case .camera: available = capturePool.frames.cameraFrame(for: normalized) != nil
            case .screen: available = capturePool.frames.screenFrame(for: normalized) != nil
            default: available = false
            }
            return .init(id: id, name: source.name, isAvailable: available)
        }
    }

    func addRecordingVideoSource(targetID: String,
                                 deliveryProvider: @escaping @Sendable () -> RecordingVideoFrameDelivery? = { nil }) -> (RecordingVideoSubscription, IsolatedVideoSource)? {
        let source: SourceDefinition?
        switch targetID {
        case "video.defaultCamera": source = .init(name: "Default Camera", payload: .camera(CameraSourcePayload()))
        case "video.defaultScreen": source = .init(name: "Selected Screen", payload: .screen(ScreenSourcePayload()))
        default:
            source = sceneStore.sources.first { "source.\($0.id)" == targetID }
        }
        guard let source else { return nil }
        if case .guest(let payload) = source.payload {
            guard let lease = guestLease, payload.slotID == lease.slot,
                  let worker = RecordingVideoSourceFactory.makeGuest(source: source, lease: lease, frames: guestVideoFrames, deliveryProvider: deliveryProvider) else { return nil }
            return (RecordingVideoSubscription(), worker)
        }
        guard let key = Self.videoCaptureKey(source.payload) else { return nil }
        let recordingKey = capturePool.recordingCaptureKey(for: key)
        if case .camera(let payload) = recordingKey, payload.deviceID == nil { return nil }
        let token = RecordingVideoSubscription()
        isolatedVideoCaptureSubscriptions[token] = recordingKey; reconcileSourceDemand()
        return (token, RecordingVideoSourceFactory.make(source: source,
            key: recordingKey, frames: capturePool.frames, deliveryProvider: deliveryProvider))
    }
    func removeRecordingVideoSource(_ subscription: RecordingVideoSubscription) {
        isolatedVideoCaptureSubscriptions.removeValue(forKey: subscription); reconcileSourceDemand()
    }
    private static func videoCaptureKey(_ payload: LayerPayload) -> CaptureSourceKey? {
        switch payload { case .camera(let camera): return .camera(camera); case .screen(let screen): return .screen(screen); default: return nil }
    }

    func removeAudioTap(_ subscription: AudioTapSubscription) {
        Task { await audioEngine.removeTap(subscription.token) }
        if isolatedCaptureSubscriptions.removeValue(forKey: subscription) != nil { reconcileSourceDemand() }
    }

    /// Ephemeral qualification capability, never restored from a saved source or ISO selection.
    var browserAudioChannels: Set<AudioChannelID> { capturePool.browserAudioChannels }
    var browserAudioMixerSettings: (() -> MixerSettings?)?

    /// Stable registry source IDs survive rename/retarget. Non-registry mixer
    /// channels use their stable mic/device/media/app/guest identities.
    func recordingAudioSources() async -> [RecordingAudioSource] {
        let statistics = await audioEngine.statsSnapshot()
        let active = Set(await audioEngine.levelsSnapshot().channels.keys)
        var result = AudioBus.allCases.map {
            RecordingAudioSource(id: "bus.\($0.rawValue)", name: "\($0.rawValue.capitalized) Bus", isBus: true, isAvailable: true)
        }
        var seen: Set<AudioChannelID> = []
        func add(_ id: String, _ name: String, _ channel: AudioChannelID) {
            guard seen.insert(channel).inserted else { return }
            result.append(RecordingAudioSource(id: id, name: name, isBus: false,
                isAvailable: (statistics.channels[channel.label]?.receivedFrames ?? 0) > 0
                    && (channel != .application(bundleID: BrowserWidgetAudioIdentity.helperBundleID) || active.contains(channel))))
        }
        for channel in browserAudioChannels {
            add("channel.\(channel.label)", BrowserWidgetAudioIdentity.channelTitle, channel)
        }
        add("channel.mic.default", "Microphone", .microphone(deviceUID: nil))
        for input in audio.additionalInputs {
            add("channel.mic.\(input.deviceUID)", audio.deviceNamesByUID[input.deviceUID] ?? "Audio Input", .microphone(deviceUID: input.deviceUID))
        }
        for source in sceneStore.sources {
            let id = "source.\(source.id)"
            if let target = resolveRecordingAudioTarget(id), let channel = target.channel { add(id, source.name, channel) }
        }
        for channel in active.sorted(by: { $0.label < $1.label }) where !seen.contains(channel) {
            switch channel {
            case .microphone(let uid): add("channel.\(channel.label)", audio.deviceNamesByUID[uid ?? ""] ?? "Microphone", channel)
            case .media(let id): add("channel.\(channel.label)", "Media / Sound \(id.description.prefix(8))", channel)
            case .application(let bundle):
                guard bundle != BrowserWidgetAudioIdentity.helperBundleID else { continue }
                add("channel.\(channel.label)", bundle.components(separatedBy: ".").last ?? "Application", channel)
            case .guest(let id): add("channel.\(channel.label)", "Guest \(id.prefix(8))", channel)
            case .capture: break // Registered sources provide a stable, secret-free ID.
            }
        }
        return result
    }

    func addRecordingAudioTap(targetID: String, processing: IsolatedAudioProcessing,
                              sink: @escaping @Sendable (CMSampleBuffer) -> Void) -> AudioTapSubscription? {
        guard let target = resolveRecordingAudioTarget(targetID) else { return nil }
        let subscription = AudioTapSubscription()
        if let bus = target.bus {
            Task { await audioEngine.addTap(bus: bus, token: subscription.token, capacity: 16, sink: sink) }
        } else if let channel = target.channel {
            Task { await audioEngine.addIsolatedTap(channel: channel, token: subscription.token,
                capacity: 16, processing: processing, sink: sink) }
        }
        if let demand = target.demand {
            isolatedCaptureSubscriptions[subscription] = demand
            reconcileSourceDemand()
        }
        return subscription
    }

    private func resolveRecordingAudioTarget(_ id: String) -> (bus: AudioBus?, channel: AudioChannelID?, demand: CaptureSourceKey?)? {
        if id.hasPrefix("bus."), let bus = AudioBus(rawValue: String(id.dropFirst(4))) { return (bus, nil, nil) }
        if id.hasPrefix("source."), let uuid = UUID(uuidString: String(id.dropFirst(7))),
           let source = sceneStore.sources.first(where: { $0.id.rawValue == uuid }) {
            switch source.payload {
            case .screen(let payload): return (nil, .capture(.screen(payload)), .screen(payload))
            case .appAudio(let payload):
                guard payload.channelBundleID != BrowserWidgetAudioIdentity.helperBundleID else { return nil }
                return (nil, .application(bundleID: payload.channelBundleID), .appAudio(payload))
            case .media: return (nil, .media(source.id), .media(source.id))
            case .guest(let payload):
                guard let slot = payload.slotID, let channel = audioEngine.registeredGuestChannelID(slot: slot) else { return nil }
                return (nil, channel, nil)
            default: return nil
            }
        }
        guard id.hasPrefix("channel.") else { return nil }
        let label = String(id.dropFirst(8))
        if label.hasPrefix("mic.") {
            let uid = String(label.dropFirst(4)); return (nil, .microphone(deviceUID: uid == "default" ? nil : uid), nil)
        }
        if label.hasPrefix("media."), let uuid = UUID(uuidString: String(label.dropFirst(6))) { return (nil, .media(SourceDefinitionID(uuid)), nil) }
        if label.hasPrefix("app.") {
            let channel = AudioChannelID.application(bundleID: String(label.dropFirst(4)))
            if channel == .application(bundleID: BrowserWidgetAudioIdentity.helperBundleID), !browserAudioChannels.contains(channel) { return nil }
            return (nil, channel, nil)
        }
        if label.hasPrefix("guest."), let slot = UUID(uuidString: String(label.dropFirst(6))),
           let channel = audioEngine.registeredGuestChannelID(slot: slot) { return (nil, channel, nil) }
        return nil
    }

    /// Loss/underrun counters for the audio engine (per channel + per tap),
    /// for the stats HUD and diagnostics.
    func audioStatsSnapshot() async -> AudioEngineStatistics {
        await audioEngine.statsSnapshot()
    }

    /// A07/A09: monitor playback counters (scheduled/played/dropped/queue
    /// depth) — the feedback-diagnostics attach point for the monitor path.
    var monitorStatistics: MonitorPlaybackStatistics { monitorOutput.statistics }

    // MARK: - A04 mixer surface (issue #83)

    /// The dispatcher's mixer channel gains, mirrored here so engine
    /// (re)starts and settings applies re-apply the FULL mixer state — a
    /// mixer-muted mic stays muted across pipeline restarts instead of the
    /// engine's settings-derived gain silently unmuting it.
    private var mixerGains: [AudioChannelID: (volume: Float, isMuted: Bool)] = [:]
    /// A05 (issue #84): the additional (UID-pinned) mic channels currently
    /// registered on the audio engine, so settings applies can diff and
    /// sync them without tearing down channels that keep running.
    private var additionalMicChannelIDs: Set<AudioChannelID> = []
    /// A08 (issue #120): each mic/media channel's FX insert box, keyed by channel
    /// ID. Boxes outlive settings applies so a chain edit lands as a
    /// parameter update on the RUNNING processor (no capture restart);
    /// they rebuild only when the engine (re)starts or the channel leaves.
    private var channelFXBoxes: [AudioChannelID: ChannelFXInsertBox] = [:]
    private var soundboardAudioReferences: [AudioChannelID: Int] = [:]
    private var mediaAudioChannelIDs: Set<AudioChannelID> = []
    private let mediaAudioDemand = MediaAudioChannelDemand()

    func retainSoundboardAudioChannel(_ id: SourceDefinitionID) {
        let channel = AudioChannelID.media(id)
        soundboardAudioReferences[channel, default: 0] += 1
        if isPipelineRunning { reconcileSourceDemand() }
    }
    func releaseSoundboardAudioChannel(_ id: SourceDefinitionID) {
        let channel = AudioChannelID.media(id)
        if let count = soundboardAudioReferences[channel], count > 1 { soundboardAudioReferences[channel] = count - 1 }
        else { soundboardAudioReferences[channel] = nil }
        if isPipelineRunning { reconcileSourceDemand() }
        else if soundboardAudioReferences[channel] == nil {
            channelFXBoxes[channel] = nil; mediaAudioChannelIDs.remove(channel)
            updateMediaAudioDemand()
            let demand = mediaAudioDemand
            Task { await audioEngine.removeChannel(channel, ifCurrent: { demand.matches(channel, identity: nil) }) }
        }
    }
    func applySoundboardChannelGain(_ id: AudioChannelID, volume: Float) {
        applyMixerChannelGain(id, volume: volume,
            isMuted: mixerGains[id]?.isMuted ?? settings.mixer.channelMutes[id.label] ?? false)
    }

    /// Media and soundboard inserts use the same pre-fader mixer seam as the
    /// microphone. Repeated demand/metadata refreshes never reset a live ring.
    private func syncMediaAudioChannels(_ wanted: Set<AudioChannelID>) {
        let added = wanted.subtracting(mediaAudioChannelIDs)
        let removed = mediaAudioChannelIDs.subtracting(wanted)
        guard !added.isEmpty || !removed.isEmpty else { return }
        mediaAudioChannelIDs = wanted
        for id in removed { channelFXBoxes[id] = nil }
        for id in added { channelFXBoxes[id] = ChannelFXInsertBox(chain: settings.channelFX[id.label] ?? .preset(.off)) }
        updateMediaAudioDemand()
        let boxes = channelFXBoxes, audioEngine = self.audioEngine, demand = mediaAudioDemand
        Task {
            for id in removed { await audioEngine.removeChannel(id, ifCurrent: { demand.matches(id, identity: nil) }) }
            for id in added {
                guard let box = boxes[id] else { continue }
                await audioEngine.addChannel(id, ifCurrent: { demand.matches(id, identity: box.demandID) },
                    resetInsert: { box.reset() }, insert: { box.process($0) })
            }
        }
    }
    private func updateMediaAudioDemand() {
        mediaAudioDemand.replace(Dictionary(uniqueKeysWithValues: mediaAudioChannelIDs.compactMap { id in
            channelFXBoxes[id].map { (id, $0.demandID) }
        }))
    }

    /// Live mixer channel gain (ramped). The dispatcher owns mixer state;
    /// this is its write path for non-scene-bound channels (the mic today,
    /// media/app/guest channels as those surfaces land). Capture channels are
    /// scene-bound (S05 `AudioBinding`s drive them from the program scene)
    /// and intentionally have no write path here.
    func applyMixerChannelGain(_ id: AudioChannelID, volume: Float, isMuted: Bool) {
        mixerGains[id] = (volume, isMuted)
        // Registry media also carries Program scene ownership. Its fader
        // multiplies that binding; touching a staged source cannot open it.
        if case .media(let sourceID) = id, soundboardAudioReferences[id] == nil,
           sceneStore.source(withID: sourceID)?.payload.isMedia == true {
            applyProgramAudioBindings()
            return
        }
        Task { await audioEngine.setChannelGain(id, volume: volume, isMuted: isMuted) }
    }

    /// Live mixer master gain for one bus (program/monitor/aux). The
    /// dispatcher folds bus mutes into the value it passes (0 while muted).
    func applyMixerBusGain(_ bus: AudioBus, gain: Float) {
        if bus == .program { programBusGain = gain }
        let effective = bus == .program && privacySlateActive ? 0 : gain
        Task { await audioEngine.setBusGain(bus, gain: effective) }
    }

    /// Live monitor-only solo toggle for one channel (any kind — solo is
    /// mixer state, so capture channels solo too; program is never affected).
    func applyMixerSolo(_ id: AudioChannelID, soloed: Bool) {
        Task { await audioEngine.setChannelSolo(id, soloed: soloed) }
    }

    /// Live mixer aux/guest-return send for one channel.
    func applyMixerAuxSend(_ id: AudioChannelID, gain: Float) {
        Task { await audioEngine.setChannelAuxSend(id, gain: gain) }
    }

    /// The engine's latest meter snapshot, for the mixer UI's ~20 Hz poll.
    func mixerLevels() async -> AudioEngineLevels {
        await audioEngine.levelsSnapshot()
    }

    /// Existing preview-only geometry intents retain their order. A view never
    /// reconfigures Program to obtain a compatible private bank.
    @discardableResult
    private func schedulePreviewGeometry(_ operation: @escaping @Sendable (CompositionEngine) async -> Void) -> Task<Void, Never> {
        let previous = previewGeometryCommand, engine = previewEngine, generation = UUID()
        previewGeometryGeneration = generation
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation(engine)
            guard let self, self.previewGeometryGeneration == generation else { return }
            self.refreshOptionalMonitorsAfterGeometry()
        }
        previewGeometryCommand = task
        return task
    }
    private func awaitPreviewFrameDeliveryGeometry(canvas: OutputCanvas, expectedSize: CGSize) async throws {
        let generation = previewGeometryGeneration, command = previewGeometryCommand
        await command?.value
        try Task.checkCancellation()
        guard previewState == .active, previewGeometryGeneration == generation else { throw CancellationError() }
        let actual = await previewEngine.frameDeliveryCanvasSize(canvas: canvas)
        try Task.checkCancellation()
        guard previewState == .active, previewGeometryGeneration == generation, actual == expectedSize else {
            throw RawVideoResourceFailure.sessionConflict
        }
    }
    /// Program/secondary command owners call this only after their fenced ACK.
    func refreshOptionalMonitorsAfterGeometry() {
        guard previewState == .active else { return }
        refreshPrimaryMonitors(replacePending: true)
        refreshSecondaryMonitors(replacePending: true)
    }

    private enum MonitorEndpoint: String, Sendable { case preview, program, secondaryPreview, secondaryProgram }

    private func monitorDelivery(_ endpoint: MonitorEndpoint) -> OptionalMonitorDelivery? {
        switch endpoint {
        case .preview: previewMonitorSubscription
        case .program: programMonitorSubscription
        case .secondaryPreview: secondaryPreviewSubscription
        case .secondaryProgram: secondaryProgramSubscription
        }
    }
    private func setMonitorDelivery(_ value: OptionalMonitorDelivery?, for endpoint: MonitorEndpoint) {
        switch endpoint {
        case .preview: previewMonitorSubscription = value
        case .program: programMonitorSubscription = value
        case .secondaryPreview: secondaryPreviewSubscription = value
        case .secondaryProgram: secondaryProgramSubscription = value
        }
    }
    private func setMonitorImage(_ value: CGImage?, for endpoint: MonitorEndpoint) {
        switch endpoint {
        case .preview: previewImage = value
        case .program: programImage = value
        case .secondaryPreview: secondaryPreviewImage = value
        case .secondaryProgram: secondaryProgramImage = value
        }
    }
    private func retireMonitor(_ endpoint: MonitorEndpoint) {
        monitorDelivery(endpoint)?.finish()
        setMonitorDelivery(nil, for: endpoint)
        setMonitorImage(nil, for: endpoint)
        monitorDeliveryFailures.removeValue(forKey: endpoint.rawValue)
    }
    private func configureMonitor(_ endpoint: MonitorEndpoint, engine: CompositionEngine,
                                  size: CGSize, canvas: OutputCanvas, plane: StableFrameDomainID.Plane,
                                  replacePending: Bool = false) {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        if let existing = monitorDelivery(endpoint), existing.width == width, existing.height == height,
           !replacePending || existing.installTask == nil { return }
        let previousDelivery = monitorDelivery(endpoint)?.delivery
        retireMonitor(endpoint)
        let identity = UUID()
        let monitor = OptionalMonitorDelivery(id: identity, width: width, height: height) { [weak self] image in
            guard let self, self.monitorDelivery(endpoint)?.id == identity else { return }
            self.setMonitorImage(image, for: endpoint)
        }
        setMonitorDelivery(monitor, for: endpoint)
        let converter = monitor.converter, handoff = monitor.handoff, throttle = resourcePreviewThrottle
        monitor.installTask = Task { @MainActor [weak self, weak monitor] in
            guard let monitor else { return }
            do {
                await previousDelivery?.finishAndWait()
                try Task.checkCancellation()
                guard let self, self.monitorDelivery(endpoint) === monitor else { monitor.finish(); return }
                if endpoint == .preview || endpoint == .secondaryPreview {
                    try await self.awaitPreviewFrameDeliveryGeometry(canvas: canvas, expectedSize: size)
                } else {
                    try await self.awaitFrameDeliveryGeometry(canvas: canvas, expectedSize: size)
                }
                let actualSize = await engine.frameDeliveryCanvasSize(canvas: canvas)
                try Task.checkCancellation()
                guard self.monitorDelivery(endpoint) === monitor else { monitor.finish(); return }
                guard actualSize == size else {
                    // Known geometry-change callers refresh again after their
                    // existing engine update ACK. Never change Program for a view.
                    throw FrameDeliveryFailure.invalidBank
                }
                let domain = StableFrameDomainID(workspace: self.rawVideoResourceWorkspaceID, kind: .monitor,
                    outputID: endpoint.rawValue, plane: plane)
                let delivery = try OptionalFrameDelivery(engine: engine, domain: domain,
                    width: width, height: height, sourceSize: actualSize, canvas: canvas)
                monitor.delivery = delivery
                try await delivery.install(shouldTransfer: {
                    converter.admitsFrame(throttleNanoseconds: throttle.nanoseconds)
                }) { frame in
                    if let image = converter.makeImage(frame) { handoff.enqueue(image) }
                }
                guard self.monitorDelivery(endpoint) === monitor else { monitor.finish(); return }
                monitor.installTask = nil
                self.monitorDeliveryFailures.removeValue(forKey: endpoint.rawValue)
            } catch {
                monitor.finish()
                guard let self, self.monitorDelivery(endpoint) === monitor else { return }
                self.setMonitorDelivery(nil, for: endpoint)
                self.setMonitorImage(nil, for: endpoint)
                if !(error is CancellationError), !Task.isCancelled {
                    self.monitorDeliveryFailures[endpoint.rawValue] = "Studio monitor unavailable: \(error.localizedDescription)"
                }
            }
        }
    }
    private func refreshPrimaryMonitors(replacePending: Bool = false) {
        guard previewState == .active else { return }
        configureMonitor(.preview, engine: previewEngine, size: resourcePreviewSize(activeProfile.canvasSize),
                         canvas: .program, plane: .preview, replacePending: replacePending)
        configureMonitor(.program, engine: engine, size: activeProfile.canvasSize,
                         canvas: .program, plane: .program, replacePending: replacePending)
    }

    // MARK: - Preview / stream lifecycle

    func startPreview() {
        guard previewState == .idle else { return }
        settings = settingsStore.load()
        applyOutputProfile(settings.outputProfile)
        previewState = .active
        refreshPrimaryMonitors()
        refreshSecondaryMonitors()
        if isPipelineRunning {
            // The pipeline is already up for a stream/recording — join it with
            // the preview engine (startPipeline covers the 0 → 1 case below).
            startPreviewEngine()
        }
        updatePipelineDemand()
    }

    /// Stops the on-screen monitors ONLY. An active stream or recording keeps
    /// running (issue #62): the pipeline demand check below keeps captures and
    /// the program engine alive for the outputs still consuming frames.
    func stopPreview() {
        guard previewState == .active else { return }
        retireMonitor(.preview)
        retireMonitor(.program)
        previewState = .idle
        refreshSecondaryMonitors()
        previewImage = nil
        programImage = nil
        schedulePreviewGeometry { await $0.stop() }
        updatePipelineDemand()
    }

    /// (Re)starts the preview engine on the current staged composition. Only
    /// called while the monitors are visible and the pipeline is running.
    private func startPreviewEngine() {
        let staged = previewProgram.stagedScene
        let canvasSize = resourcePreviewSize(activeProfile.canvasSize)
        let fps = min(encodeFrameRate, previewResourceLevel.maximumFrameRate)
        schedulePreviewGeometry { await $0.run(scene: staged, canvasSize: canvasSize, frameRate: fps) }
    }

    private func resourcePreviewSize(_ size: CGSize) -> CGSize {
        let scale = min(1, Double(previewResourceLevel.maximumLongEdge) / Double(max(size.width, size.height)))
        return CGSize(width: max(16, Int(size.width * scale) / 2 * 2),
                      height: max(16, Int(size.height * scale) / 2 * 2))
    }

    /// Optional rasters/conversions only. Active Program, its source clock,
    /// publisher identities, recording geometry and encoder counts are untouched.
    func applyResourcePreviewBudget(_ level: DesktopResourceBudget.PreviewLevel) {
        guard level != previewResourceLevel else { return }
        previewResourceLevel = level; resourcePreviewThrottle.set(level)
        guard previewState == .active else { return }
        refreshPrimaryMonitors()
        refreshSecondaryMonitors()
        guard isPipelineRunning else { return }
        let canvasSize = resourcePreviewSize(activeProfile.canvasSize)
        let secondarySize = resourcePreviewSize(secondaryStagedProfile.canvasSize)
        let fps = min(encodeFrameRate, level.maximumFrameRate)
        schedulePreviewGeometry {
            await $0.setOutput(canvasSize: canvasSize, frameRate: fps)
            await $0.setSecondaryOutput(canvasSize: secondarySize)
        }
    }

    var secondaryStagedProfile: OutputProfile {
        guard let layout = previewProgram.stagedScene?.secondaryCanvas, layout.isValid else { return activeSecondaryProfile }
        return layout.profile(frameRate: activeProfile.frameRate)
    }
    var secondaryCanvasAvailable: Bool {
        previewProgram.programScene?.secondaryCanvas?.isValid == true
    }
    func profileForOutputDestination(_ destination: StreamDestination?) -> OutputProfile? {
        guard let destination else { return nil }
        if destination.canvas == .secondary && !secondaryCanvasAvailable { return nil }
        return destination.effectiveProfile(program: destination.canvas == .secondary ? activeSecondaryProfile : activeProfile)
    }
    private func outputCanvas(for feed: ExternalDisplayFeed?, destinationID: UUID?) -> OutputCanvas {
        if feed == .secondaryCanvas { return .secondary }
        if feed == .selectedCanvas, let destination = destinations.saved.first(where: { $0.id == destinationID }) {
            return destination.canvas ?? .program
        }
        return .program
    }
    private var secondaryProgramOutputDemanded: Bool {
        destinationOutputs.usesSecondaryCanvas || secondaryRecordingDemand > 0 ||
            secondaryVirtualCameraDemand > 0 || secondaryExternalDisplayDemand > 0 || !guestSecondaryReturnTokens.isEmpty
    }
    var secondaryCanvasDemanded: Bool {
        (secondaryMonitorsEnabled && previewState == .active) || secondaryProgramOutputDemanded
    }
    func setSecondaryMonitorsEnabled(_ enabled: Bool) {
        secondaryMonitorsEnabled = enabled
        updateSecondaryGeometryIfIdle()
        refreshSecondaryMonitors()
        reconcileSourceDemand()
    }
    private func refreshSecondaryMonitors(replacePending: Bool = false) {
        // New monitor demand takes priority over an optional guest raster.
        // Revocation also disables Clean rendering before its VT drain ends.
        if cleanReturnDemanded, let error = cleanReturnStartError {
            if guestReturnVideoSink?.returnVideoSource == .clean { guestReturnVideoSink?.stopProgramReturn() }
            if cleanExternalDisplayDemand > 0, externalDisplayController?.feed == .clean {
                externalDisplayController?.stop(reason: error)
            }
        }
        if secondaryMonitorsEnabled, previewState == .active {
            configureMonitor(.secondaryPreview, engine: previewEngine,
                size: resourcePreviewSize(secondaryStagedProfile.canvasSize), canvas: .secondary, plane: .secondary, replacePending: replacePending)
            configureMonitor(.secondaryProgram, engine: engine,
                size: activeSecondaryProfile.canvasSize, canvas: .secondary, plane: .secondary, replacePending: replacePending)
        } else {
            retireMonitor(.secondaryPreview)
            retireMonitor(.secondaryProgram)
        }
    }
    private func updateSecondaryGeometryIfIdle() {
        let previewSize = resourcePreviewSize(secondaryStagedProfile.canvasSize)
        schedulePreviewGeometry { await $0.setSecondaryOutput(canvasSize: previewSize) }
        guard !outputsOwnProfile else { return }
        let layout = previewProgram.programScene?.secondaryCanvas
        activeSecondaryProfile = layout?.isValid == true
            ? layout!.profile(frameRate: activeProfile.frameRate)
            : OutputProfile(canvasWidth: 720, canvasHeight: 1280, frameRate: activeProfile.frameRate)
        let size = activeSecondaryProfile.canvasSize
        let previous = secondaryGeometryCommand
        let generation = UUID(); secondaryGeometryGeneration = generation
        secondaryGeometryCommand = Task { [weak self, engine] in
            await previous?.value
            await engine.setSecondaryOutput(canvasSize: size)
            guard let self, self.secondaryGeometryGeneration == generation else { return }
            self.refreshOptionalMonitorsAfterGeometry()
        }
    }

    func prepareForProjectChange() async {
        guard !outputSessionActive else { return }
        stopExternalDisplayOutput()
        stopPreview()
        await scheduleProgramEngineStop().value
        await schedulePreviewGeometry { await $0.stop() }.value
        await audioEngine.stop()
        capturePool.stopAll()
        audio.stop()
    }

    var maximumPublishingEncoders: () -> Int? = { nil }

    /// Runtime-owned provider boundary; no cached key or remote UI state can
    /// authorize a managed publisher. All output command routes reach the
    /// same startDestination gate below.
    func bindManagedStart(accounts: ProviderAccountSession) {
        guard !managedStartClosed, managedStartAccounts !== accounts else { return }
        managedStart?.shutdown()
        managedStartAccounts = accounts
        let coordinator = ManagedYouTubeStartCoordinator(generation: { [weak accounts] in
            await accounts?.recoveryAuthorizationGeneration(.youtube)
        }, read: { [weak accounts] request, generation in
            guard let accounts else { throw ProviderFailure(.authorization) }
            return try await accounts.managedReadRequest(request, expectedGeneration: generation)
        }, current: { [weak self] id in self?.managedStartContext(id) }, publish: { [weak self] context, credentials in
            self?.publishReviewedManagedDestination(context, credentials: credentials) ?? false
        })
        managedStart = coordinator
        managedStartEntriesObserver = coordinator.$entries.sink { [weak self] entries in
            self?.managedStartHasEntries = !entries.isEmpty
        }
        // Published intent precedes asynchronous vault replacement. Cancel
        // immediately as well as checking the generation at every read.
        managedStartAuthorityObserver = accounts.$managedReadRevision.dropFirst().sink { [weak coordinator] _ in
            coordinator?.cancelAll()
        }
    }

    /// A runtime owns this counter across room creation, ending and rejoin.
    /// Allocated generations stay consumed even when preparation is canceled.
    func issueGuestReceiveGeneration() -> UInt64? {
        guard !guestMediaRetired else { return nil }
        let previous = max(lastIssuedGuestGeneration, lastGuestAdmissionGeneration)
        guard previous < UInt64.max else { return nil }
        lastIssuedGuestGeneration = previous + 1
        return lastIssuedGuestGeneration
    }

    /// Creates an inlet only after the complete persisted-mixer admission
    /// transaction succeeds. Cancellation/replacement can never return a sink
    /// for an older lease or undo a newer registered peer.
    func makeGuestMediaSink(_ lease: GuestReceiveLease, name: String) async -> NativeGuestMediaSink? {
        guard !Task.isCancelled, guestLease != lease, pendingGuestLease != lease,
              await registerGuestMedia(lease, name: name) else { return nil }
        guard !Task.isCancelled, !guestMediaRetired, guestLease == lease else {
            removeGuestMedia(lease)
            return nil
        }
        let sink = NativeGuestMediaSink(registered: lease, video: guestVideoFrames, audio: audioEngine)
        guestReturnVideoSink = sink
        let program = engine, authority = guestProgramReturnAuthority
        for source in NativeInterviewReturnVideoSource.allCases {
            let canvas: OutputCanvas = source == .secondary ? .secondary : .program
            let maximumProfile: NativeGuestReturnVideoProfile = IsolatedVideoBudget.current.qualified ? .high : .low
            let delivery = GuestReturnFrameDelivery()
            let capability = NativeGuestProgramReturnSource(maximumProfile: maximumProfile, authority: authority, install: { [weak self, weak sink] token, consume in
                let preparation = await MainActor.run { () -> GuestReturnFrameDelivery.Preparation? in
                    guard let self, let sink, sink.videoTokenIsCurrent(token), self.isPipelineRunning,
                          self.guestLease == lease,
                          source != .clean || self.cleanReturnStartError == nil,
                          delivery.isVacant,
                          self.reserveRecordingEncoders(token, count: 1, canvas: canvas) == nil else { return nil }
                    let size = canvas == .secondary ? self.activeSecondaryProfile.canvasSize : self.activeProfile.canvasSize
                    let domain = StableFrameDomainID(workspace: self.rawVideoResourceWorkspaceID, kind: .guestReturn,
                        outputID: "return-\(source.rawValue)-ingress",
                        plane: source == .clean ? .clean : canvas == .secondary ? .secondary : .program)
                    do {
                        let sourceRequest = try program.sourceFrameResourceRequest(canvasSize: size, canvas: canvas, clean: source == .clean)
                        let encoderPlan = try GuestReturnVideoResources.plan(workspace: self.rawVideoResourceWorkspaceID,
                            outputID: "return-\(source.rawValue)", generation: token,
                            sourceSize: size, maximumProfile: maximumProfile)
                        // Source4 + private ingress5 + every possible adaptive
                        // conversion raster are committed before installation
                        // can expose pixels or the sender can create VT.
                        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([sourceRequest,
                            .init(domain: domain,
                                descriptor: .init(width: Int(size.width), height: Int(size.height), capacity: 5),
                                sessionGeneration: token)] + encoderPlan.requests)
                        do {
                            guard let bank = receipt.bank(for: domain) else { throw FrameDeliveryFailure.invalidBank }
                            let resources = try GuestReturnVideoResources(plan: encoderPlan, receipt: receipt)
                            let sourceReceipt = try receipt.selecting(domain: sourceRequest.domain)
                            let preparation = GuestReturnFrameDelivery.Preparation(token: token, generation: token,
                                domain: domain, receipt: receipt, sourceReceipt: sourceReceipt, bank: bank, resources: resources)
                            guard delivery.begin(preparation) else {
                                RawVideoResourceCoordinator.shared.rollback(sourceReceipt)
                                throw FrameDeliveryFailure.cancelled
                            }
                            if source == .clean { self.guestCleanReturnTokens.insert(token) }
                            if canvas == .secondary {
                                self.guestSecondaryReturnTokens.insert(token)
                                self.reconcileSourceDemand()
                            }
                            return preparation
                        } catch {
                            RawVideoResourceCoordinator.shared.rollback(receipt)
                            throw error
                        }
                    } catch {
                        self.releaseRecordingEncoders(token)
                        return nil
                    }
                }
                guard let preparation else { return false }
                do {
                    guard let self else { throw FrameDeliveryFailure.cancelled }
                    try await self.awaitFrameDeliveryGeometry(canvas: canvas,
                        expectedSize: CGSize(width: preparation.bank.descriptor.width, height: preparation.bank.descriptor.height))
                    let installed = try await program.installFrameDelivery(token: token, domain: preparation.domain,
                        generation: preparation.generation, bank: preparation.bank,
                        sourceBank: preparation.sourceReceipt.banks.first, sourceReceipt: preparation.sourceReceipt,
                        capacity: 1, cancellation: preparation.cancellation, canvas: canvas, clean: source == .clean,
                        authorized: { [weak sink] in sink?.videoTokenIsCurrent(token) == true }) { consume($0.sampleBuffer) }
                    guard delivery.adopt(installed, preparation: preparation) else {
                        await program.removeFrameDelivery(installed)
                        RawVideoResourceCoordinator.shared.rollback(preparation.receipt)
                        RawVideoResourceCoordinator.shared.rollback(preparation.sourceReceipt)
                        return false
                    }
                    let current = await MainActor.run { [weak self, weak sink] in
                        self?.guestLease == lease && self?.isPipelineRunning == true
                            && sink?.videoTokenIsCurrent(token) == true
                    }
                    if !current || Task.isCancelled {
                        preparation.cancellation.cancel()
                        await program.removeFrameDelivery(installed)
                        // Sender teardown retains the encoder reservation until
                        // its serial codec owner has actually closed.
                        return false
                    }
                    return true
                } catch {
                    _ = delivery.remove(token: token)
                    RawVideoResourceCoordinator.shared.rollback(preparation.receipt)
                    RawVideoResourceCoordinator.shared.rollback(preparation.sourceReceipt)
                    await MainActor.run {
                        guard let self else { return }
                        self.guestSecondaryReturnTokens.remove(token); self.guestCleanReturnTokens.remove(token)
                        self.releaseRecordingEncoders(token)
                        if canvas == .secondary { self.reconcileSourceDemand() }
                    }
                    return false
                }
            }, remove: { [weak self] token in
                let reserved = await MainActor.run {
                    guard let self, self.recordingEncoderReservations.recordings[token] != nil else { return false }
                    return self.guestReturnVideoRemovals.insert(token).inserted
                }
                if let preparation = delivery.remove(token: token) {
                    if let installed = preparation.lease { await program.removeFrameDelivery(installed) }
                    else { await program.cancelFrameDelivery(token: token) }
                    RawVideoResourceCoordinator.shared.rollback(preparation.receipt)
                    RawVideoResourceCoordinator.shared.rollback(preparation.sourceReceipt)
                }
                guard reserved else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.guestSecondaryReturnTokens.remove(token); self.guestCleanReturnTokens.remove(token)
                    self.releaseRecordingEncoders(token); self.guestReturnVideoRemovals.remove(token)
                    if canvas == .secondary { self.reconcileSourceDemand() }
                }
            }, videoResources: { delivery.resources(for: $0) })
            if source == .program { sink.bindProgramReturn(capability) }
            else if source == .secondary { sink.bindSecondaryReturn(capability) }
            else { sink.bindCleanReturn(capability) }
        }
        return sink
    }

    /// Called only after session admission. Receipts cannot create slots or
    /// channels. Registration survives a pipeline restart but not retirement.
    @discardableResult
    func registerGuestMedia(_ lease: GuestReceiveLease, name: String) async -> Bool {
        guard !guestMediaRetired, lease.generation > 0 else { return false }
        guard sceneStore.guestSlots.contains(where: { $0.id == lease.slot }) || sceneStore.guestSlots.count < 16 else { return false }
        if guestLease == lease { return true }
        // The one-peer runtime uses a monotonic session generation. Canceled
        // requests consume their generation, so a stale completion cannot
        // remove a later retry sharing the exact same lease.
        guard lease.generation > lastGuestAdmissionGeneration else { return false }
        if let pending = pendingGuestLease {
            guard pending.slot == lease.slot, lease.generation > pending.generation else { return false }
        }
        if let current = guestLease {
            guard current.slot == lease.slot, lease.generation > current.generation else { return false }
            guestVideoFrames.remove(current)
            _ = audioEngine.removeGuest(current)
            guestLease = nil
        }
        lastGuestAdmissionGeneration = lease.generation
        let ticket = UUID(); guestRegistration = ticket; pendingGuestLease = lease
        let channel = AudioMixEngine.guestChannelID(for: lease)
        let mixer = guestMixerSnapshot(channel: channel)
        // Gain, mute, solo and aux are seeded in the registration transaction.
        // A restored mute starts at zero, and an older rejected lease cannot
        // change the newer channel's mixer state through generic-ID awaits.
        guard await audioEngine.registerGuest(lease, initialMixer: mixer) else {
            if guestRegistration == ticket { pendingGuestLease = nil }
            return false
        }
        guard !guestMediaRetired, guestRegistration == ticket,
              guestMixerValues(mixer, channel: channel) == guestMixerValues(guestMixerSnapshot(channel: channel), channel: channel),
              guestVideoFrames.register(lease) else {
            if guestRegistration == ticket { pendingGuestLease = nil }
            _ = audioEngine.removeGuest(lease); return false
        }
        pendingGuestLease = nil; guestLease = lease
        mixerGains[channel] = (Float(max(0, min(mixer.channelVolumes[channel.label] ?? 1, 2))),
                              mixer.channelMutes[channel.label] ?? false)
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        if !sceneStore.guestSlots.contains(where: { $0.id == lease.slot }) {
            sceneStore.replaceGuestSlot(.init(id: lease.slot, name: title.isEmpty ? "Guest" : title))
        }
        sceneStore.ensureGuestSources(slotID: lease.slot, name: title.isEmpty ? "Guest" : title)
        return true
    }

    private func guestMixerSnapshot(channel: AudioChannelID) -> MixerSettings {
        var mixer = guestMixerSettings?() ?? settings.mixer
        if guestMixerSettings == nil, let liveGain = mixerGains[channel] {
            mixer.channelVolumes[channel.label] = Double(liveGain.volume)
            mixer.channelMutes[channel.label] = liveGain.isMuted ? true : nil
        }
        return mixer
    }
    private func guestMixerValues(_ mixer: MixerSettings, channel: AudioChannelID) -> [Double] {
        [max(0, min(2, mixer.channelVolumes[channel.label] ?? 1)),
         mixer.channelMutes[channel.label] == true ? 1 : 0,
         mixer.soloedChannels.contains(channel.label) ? 1 : 0,
         max(0, min(1, mixer.channelAuxSends[channel.label] ?? 0))]
    }

    /// Both callback paths validate the common clock generation without
    /// introducing a main-actor task for every decoded frame.
    nonisolated func receiveGuestVideo(_ frame: GuestVideoFrame) {
        _ = guestVideoFrames.receive(frame)
    }
    nonisolated func registeredGuestAudioChannel(slot: UUID) -> AudioChannelID? {
        audioEngine.registeredGuestChannelID(slot: slot)
    }
    nonisolated func receiveGuestAudio(_ frame: GuestAudioFrame) {
        guard audioEngine.validateGuestFrame(frame),
              guestVideoFrames.acceptClock(lease: frame.lease, mapping: frame.mappingGeneration) else { return }
        _ = audioEngine.enqueueGuest(frame)
    }

    @discardableResult
    func setGuestMediaRouting(_ lease: GuestReceiveLease, programAllowed: Bool, monitorAllowed: Bool) -> Bool {
        guard !guestMediaRetired, guestLease == lease else { return false }
        if !programAllowed { guestVideoFrames.allowProgram(false, lease: lease) }
        guard audioEngine.setGuestRouting(lease, programAllowed: programAllowed, monitorAllowed: monitorAllowed),
              !guestMediaRetired, guestLease == lease else { return false }
        guestVideoFrames.allowProgram(programAllowed, lease: lease)
        return true
    }

    /// The native session owner grants capture separately and forwards an
    /// acknowledged share-end/revoke here. A frame never grants itself access.
    func setGuestScreenEnabled(_ enabled: Bool, lease: GuestReceiveLease) {
        guard !guestMediaRetired, guestLease == lease else { return }
        if enabled { guestVideoFrames.enable(.screen, lease: lease) }
        else { guestVideoFrames.disable(.screen, lease: lease) }
    }
    func guestTalkbackSourceAvailable(_ source: AudioChannelID) -> Bool {
        guard case .microphone = source, isPipelineRunning, !guestMediaRetired,
              !resilience.isLocked, !privacySlateActive else { return false }
        #if STREAM_NATIVE_VALIDATION
        if let guestTalkbackFixtureCapture { return guestTalkbackFixtureCapture(source) }
        #endif
        return permissions.status(for: .microphone) == .granted
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && audio.isCapturing(source)
    }
    @discardableResult func beginGuestTalkback(_ lease: GuestReceiveLease, source: AudioChannelID, press: UUID) -> Bool {
        guard guestLease == lease, guestTalkbackSourceAvailable(source) else { return false }
        return audioEngine.beginGuestTalkback(lease, source: source, press: press)
    }
    @discardableResult func endGuestTalkback(_ lease: GuestReceiveLease, press: UUID) -> Bool {
        audioEngine.endGuestTalkback(lease, press: press)
    }
    func guestTalkbackIsActive(_ lease: GuestReceiveLease, source: AudioChannelID, press: UUID) -> Bool {
        guestLease == lease && audioEngine.guestTalkbackIsActive(lease, source: source, press: press)
    }
    func removeGuestMedia(_ lease: GuestReceiveLease) {
        guard guestLease == lease || pendingGuestLease == lease else { return }
        guestRegistration = UUID(); pendingGuestLease = nil
        if guestLease == lease { guestLease = nil }
        guestVideoFrames.remove(lease); _ = audioEngine.removeGuest(lease)
    }
    func retireGuestMedia() {
        guestMediaRetired = true; guestRegistration = UUID(); pendingGuestLease = nil; guestLease = nil
        guestVideoFrames.retire(); audioEngine.retireGuestAdmissions()
    }

    func shutdownManagedStart() {
        managedStartClosed = true
        managedStart?.shutdown()
        managedStartEntriesObserver = nil; managedStartAuthorityObserver = nil
        managedStartHasEntries = false
    }

    private func managedStartContext(_ id: UUID) -> ManagedYouTubeStartContext? {
        guard !managedStartClosed, !resilience.isLocked, !isRehearsing,
              destinationOutputs.isPublishingAllowed, !(destinationOutputs.states[id]?.isActive ?? false),
              let accounts = managedStartAccounts,
              let destination = destinations.saved.first(where: { $0.id == id }),
              destination.providerBinding != nil, canvasStartError(destinations: [destination]) == nil else { return nil }
        let base = settingsStore.load()
        let canvas = destination.canvas == .secondary ? activeSecondaryProfile : base.outputProfile
        return .init(destination: destination, settings: base, canvasProfile: canvas, authorityRevision: accounts.managedReadRevision)
    }

    private func publishReviewedManagedDestination(_ context: ManagedYouTubeStartContext,
                                                  credentials: DestinationCredentials) -> Bool {
        guard managedStartContext(context.destination.id) == context else { return false }
        return publishDestination(context.destination, credentials: credentials, base: context.settings)
    }

    func goLive() {
        guard !resilience.isLocked else { errorMessage = "Unlock this Mac before starting public outputs."; return }
        guard !isRehearsing else { errorMessage = "End local rehearsal before public Go Live."; return }
        guard streamState.canStart else { return }
        settings = settingsStore.load()
        let planned = outputEncodingPlan(program: settings.outputProfile)
        if let error = recordingEncoderReservations.publishingError(current: activePublishingEncoderCount, starting: planned.encoderSessions) {
            errorMessage = error; return
        }
        if let limit = maximumPublishingEncoders(), activePublishingEncoderCount + planned.encoderSessions > limit {
            errorMessage = "Selected destinations exceed the encoder budget reserved by isolated recording. Stop isolated recording or reduce destinations."
            return
        }
        settings = settingsStore.load()
        if let error = canvasStartError(destinations: destinations.enabled) { errorMessage = error; return }
        let plan = outputEncodingPlan(program: settings.outputProfile)
        guard plan.issues.isEmpty else { errorMessage = plan.issues.joined(separator: "\n"); return }
        // Keep the program and recording canvas unchanged. Every destination's
        // encoder receives its own output geometry from its adapted settings.
        destinationOutputs.sharedEncodingEnabled = destinations.sharesFixedH264AAC
        destinationOutputs.sharedSourceFrameRate = activeProfile.frameRate
        let immediate = destinations.enabled.compactMap { destination -> DestinationOutputController.VideoStartInput? in
            guard destination.providerBinding == nil,
                  !(destinationOutputs.states[destination.id]?.isActive ?? false) else { return nil }
            let canvasProfile = destination.canvas == .secondary ? activeSecondaryProfile : settings.outputProfile
            let credentials = destinations.savedCredentials(for: destination.id)
            guard DestinationValidator.startErrors(destination, credentials: credentials, program: canvasProfile).isEmpty else { return nil }
            var base = settings; base.outputProfile = canvasProfile
            let adapted = DestinationValidator.settings(destination, credentials: credentials, base: base)
            return .init(destination: destination, settings: adapted, sourceSize: canvasProfile.canvasSize)
        }
        destinationOutputs.withPreparedVideoResources(immediate) {
            for destination in destinations.enabled { startDestination(destination.id) }
        }
    }

    func startDestination(_ id: UUID) {
        guard !resilience.isLocked else { errorMessage = "Unlock this Mac before starting public outputs."; return }
        guard !isRehearsing else { errorMessage = "End local rehearsal before starting a public destination."; return }
        guard let destination = destinations.saved.first(where: { $0.id == id }) else { return }
        guard !(destinationOutputs.states[id]?.isActive ?? false) else { return }
        let base = settingsStore.load()
        if let error = canvasStartError(destinations: [destination]) {
            errorMessage = error; destinationOutputs.recordFailure(destination, message: error); return
        }
        if destination.providerBinding != nil {
            guard let managedStart, let context = managedStartContext(id) else {
                let message = "This managed destination needs a current account and native event review before sending video. No saved key was used."
                errorMessage = message; destinationOutputs.recordFailure(destination, message: message); return
            }
            managedStart.request(context)
            return
        }
        let credentials = destinations.savedCredentials(for: id)
        _ = publishDestination(destination, credentials: credentials, base: base)
    }

    /// The factory boundary is synchronous and common to manual and reviewed
    /// starts, preserving aggregate/shared encoder and dual-canvas checks.
    @discardableResult
    private func publishDestination(_ destination: StreamDestination, credentials: DestinationCredentials,
                                    base: StreamSettings) -> Bool {
        let id = destination.id
        guard !resilience.isLocked, !isRehearsing, destinationOutputs.isPublishingAllowed,
              !(destinationOutputs.states[id]?.isActive ?? false),
              destinations.saved.first(where: { $0.id == id }) == destination else { return false }
        if let error = canvasStartError(destinations: [destination]) {
            errorMessage = error; destinationOutputs.recordFailure(destination, message: error); return false
        }
        let canvasProfile = destination.canvas == .secondary ? activeSecondaryProfile : base.outputProfile
        let errors = DestinationValidator.startErrors(destination, credentials: credentials, program: canvasProfile)
        guard errors.isEmpty else {
            let message = errors.joined(separator: "\n")
            errorMessage = message
            destinationOutputs.recordFailure(destination, message: message)
            return false
        }
        let activeDestinations = destinations.saved.filter {
            destinationOutputs.states[$0.id]?.isActive == true && $0.id != id
        } + [destination]
        let plan = DestinationEncodingPlan(destinations: activeDestinations.map(destinationForEncodingPlan), program: base.outputProfile,
            measuredUplinkMbps: destinations.measuredUplinkMbps > 0 ? destinations.measuredUplinkMbps : nil,
            measuredSessionLimit: destinations.measuredSessionLimit > 0 ? destinations.measuredSessionLimit : nil,
            shareH264AAC: destinations.sharesFixedH264AAC, sourceFrameRate: activeProfile.frameRate)
        guard plan.issues.isEmpty else {
            destinationOutputs.recordFailure(destination, message: plan.issues.joined(separator: "\n"))
            return false
        }
        var canvasBase = base; canvasBase.outputProfile = canvasProfile
        let adapted = DestinationValidator.settings(destination, credentials: credentials, base: canvasBase)
        destinationOutputs.sharedEncodingEnabled = destinations.sharesFixedH264AAC
        destinationOutputs.sharedSourceFrameRate = activeProfile.frameRate
        let additional = destinationOutputs.additionalEncoderSessions(destination: destination, settings: adapted)
        if let error = recordingEncoderReservations.publishingError(current: activePublishingEncoderCount, starting: additional) {
            errorMessage = error; destinationOutputs.recordFailure(destination, message: error); return false
        }
        if let limit = maximumPublishingEncoders(), activePublishingEncoderCount + additional > limit {
            let message = "This destination exceeds the encoder budget reserved by isolated recording. Stop isolated recording or reduce destinations."
            errorMessage = message; destinationOutputs.recordFailure(destination, message: message); return false
        }
        resilience.acknowledgeManualRestart()
        return destinationOutputs.start(destination, settings: adapted, sourceSize: canvasProfile.canvasSize)
    }

    func stopDestination(_ id: UUID) { managedStart?.cancel(id); destinationOutputs.stop(id) }
    func retryDestination(_ id: UUID) {
        guard !(destinationOutputs.states[id]?.isActive ?? false) else { return }
        startDestination(id)
    }
    func stopStream() { managedStart?.cancelAll(); destinationOutputs.stopAll() }

    private func destinationsDidChange() {
        streamState = destinationOutputs.aggregateState
        if streamState.isLive { errorMessage = nil }
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
        reconcileSourceDemand()
    }

    func outputEncodingPlan(program: OutputProfile) -> DestinationEncodingPlan {
        DestinationEncodingPlan(destinations: destinations.enabled.map(destinationForEncodingPlan), program: program,
            measuredUplinkMbps: destinations.measuredUplinkMbps > 0 ? destinations.measuredUplinkMbps : nil,
            measuredSessionLimit: destinations.measuredSessionLimit > 0 ? destinations.measuredSessionLimit : nil,
            shareH264AAC: destinations.sharesFixedH264AAC, sourceFrameRate: activeProfile.frameRate)
    }
    private func destinationForEncodingPlan(_ destination: StreamDestination) -> StreamDestination {
        guard destination.canvas == .secondary, destination.followsProgramProfile else { return destination }
        var copy = destination; copy.followsProgramProfile = false; copy.outputProfile = activeSecondaryProfile
        return copy
    }
    var cleanReturnDemanded: Bool { !guestCleanReturnTokens.isEmpty || cleanExternalDisplayDemand > 0 }
    private var cleanReturnStartError: String? {
        CompositorWorkloadBudget.cleanStartError(program: activeProfile,
            secondary: secondaryCanvasDemanded ? activeSecondaryProfile : nil,
            qualified: IsolatedVideoBudget.current.qualified)
    }
    private func validateExternalDisplayTarget(_ request: ExternalDisplayFeedRequest) throws {
        switch request.feed {
        case .program, .clean:
            guard request.profile == activeProfile else { throw RawVideoResourceFailure.sessionConflict }
        case .secondaryCanvas:
            guard secondaryCanvasAvailable, request.profile == activeSecondaryProfile else {
                throw RawVideoResourceFailure.sessionConflict
            }
        case .selectedCanvas:
            guard let id = request.selectedDestinationID, let destination = destinations.saved.first(where: { $0.id == id }),
                  request.profile == profileForOutputDestination(destination) else {
                throw RawVideoResourceFailure.sessionConflict
            }
        }
    }
    private func externalDisplayStartError(_ feed: ExternalDisplayFeed, destinationID: UUID?) -> String? {
        guard !resilience.isLocked else { return "Unlock this Mac before starting external output." }
        if feed == .clean { return cleanReturnStartError }
        if outputCanvas(for: feed, destinationID: destinationID) == .secondary {
            return canvasStartError(destinations: [.init(name: "External Display", canvas: .secondary)])
        }
        return nil
    }
    private func canvasStartError(destinations selected: [StreamDestination]) -> String? {
        guard selected.contains(where: { $0.canvas == .secondary }) else { return nil }
        guard secondaryCanvasAvailable else { return "Take a configured secondary layout to Program before starting this output." }
        return CompositorWorkloadBudget.secondaryStartError(program: activeProfile,
            secondary: activeSecondaryProfile, cleanDemanded: cleanReturnDemanded)
    }

    func beginLocalRehearsal(recorder: RecordingController) {
        guard !isRehearsing, !streamState.isActive, destinationOutputs.activeCount == 0, activePublishingEncoderCount == 0,
              !recorder.state.isActive, reservedRecordingEncoderCount == 0 else { return }
        let token = UUID()
        rehearsalToken = token
        rehearsalRecorder = recorder
        rehearsalStopRequested = false
        rehearsalOwnsPreview = previewState == .idle
        // Reserve local rehearsal before capture, countdown or asynchronous
        // writer preparation can yield. A Preparing recorder is not yet
        // Recording, but public publishers must already be blocked.
        isRehearsing = true
        managedStart?.cancelAll()
        destinationOutputs.isPublishingAllowed = false
        rehearsalObserver = recorder.$state.sink { [weak self, weak recorder] _ in
            // Published sends before the stored state changes. Inspect the
            // current state on the next turn, and reject old-session callbacks.
            Task { @MainActor [weak self, weak recorder] in
                guard let self, let recorder, self.rehearsalToken == token,
                      !recorder.state.isActive else { return }
                self.stopLocalRehearsal(recorder: recorder, token: token)
            }
        }
        if rehearsalOwnsPreview { startPreview() }
        recorder.start(stream: self)
        if !recorder.state.isActive { stopLocalRehearsal(recorder: recorder, token: token) }
    }

    func endLocalRehearsal(recorder: RecordingController) {
        guard rehearsalRecorder === recorder, let token = rehearsalToken else { return }
        stopLocalRehearsal(recorder: recorder, token: token)
    }

    private func stopLocalRehearsal(recorder: RecordingController, token: UUID) {
        guard rehearsalToken == token, !rehearsalStopRequested else { return }
        rehearsalStopRequested = true
        // The completion includes countdown/preflight cancellation, the
        // current writer, isolated tracks and any previous segment finalizing.
        // Publishing remains blocked until all recording ownership is released.
        recorder.stop { [weak self] in
            guard let self, self.rehearsalToken == token else { return }
            self.rehearsalObserver = nil
            self.rehearsalToken = nil
            self.rehearsalRecorder = nil
            self.rehearsalStopRequested = false
            if self.rehearsalOwnsPreview { self.stopPreview() }
            self.rehearsalOwnsPreview = false
            self.isRehearsing = false
            self.destinationOutputs.isPublishingAllowed = true
        }
    }

    func preflightFacts(programAudioPeak: Float?, assetAvailability: (AssetID) -> AssetAvailability = { _ in .unknown }) -> StreamPreflightFacts {
        var facts = StreamPreflightFacts()
        let scene = previewProgram.programScene
        let checksSecondary = destinations.enabled.contains { $0.canvas == .secondary } ||
            secondaryProgramOutputDemanded || secondaryRecordingController?.state.isActive == true
        let sceneIndex = SceneGraph.index(sceneStore.scenes)
        var layers = scene.map { SceneGraph.flattenedVisibleLayers(of: $0, in: sceneIndex) } ?? []
        if checksSecondary, let scene {
            layers += SceneGraph.flattenedVisibleLayers(of: scene.composition(for: .secondary), in: sceneIndex)
        }
        layers += sceneStore.overlays.filter { $0.isVisible && !(scene?.hiddenOverlayIDs.contains($0.id) ?? false) }
        // A linked layer can be visible on both canvases while one physical
        // source owns its capture/permission state. Independent secondary
        // visibility must still participate when Program hides that layer.
        var checkedLayers = Set<LayerID>()
        layers = layers.filter { checkedLayers.insert($0.id).inserted }
        func checkAsset(_ identifier: String?, hasBookmark: Bool, description: String) {
            if let identifier, let uuid = UUID(uuidString: identifier) {
                switch assetAvailability(AssetID(uuid)) {
                case .available: break
                case .unknown: facts.unverifiedSources.append("\(description) asset availability has not been verified.")
                case .missing: facts.missingSources.append("\(description) asset is missing or its access was revoked; relink it in Assets.")
                }
            } else if !hasBookmark {
                facts.missingSources.append("\(description) has no configured asset.")
            } else {
                facts.unverifiedSources.append("\(description) uses a linked file; verify it in the local rehearsal.")
            }
        }
        for layer in layers {
            let payload = layer.sourceID.flatMap { id in sceneStore.sources.first { $0.id == id } }?.payload ?? layer.payload
            switch payload {
            case .image(let image): checkAsset(image.assetIdentifier, hasBookmark: image.bookmarkData != nil, description: "Image")
            case .media(let media):
                if layer.sourceID == nil { facts.missingSources.append("A media layer is not linked to a registered source.") }
                checkAsset(media.assetIdentifier, hasBookmark: media.bookmarkData != nil, description: "Media")
            case .pdf(let pdf): checkAsset(pdf.assetIdentifier, hasBookmark: false, description: "Slide deck")
            case .web(let web):
                if !web.browserOverlay.hasWidgetContent { facts.missingSources.append("A browser source has no configured content.") }
                if let asset = web.browserOverlay.localHTMLAssetIdentifier { checkAsset(asset, hasBookmark: false, description: "Browser HTML") }
            default: break
            }
        }
        if case .image(let image) = scene?.background ?? sceneStore.defaultBackground {
            checkAsset(image.assetIdentifier, hasBookmark: image.bookmarkData != nil, description: "Background image")
        }
        if let uid = settings.preferredAudioInputUID, !deviceMonitor.connectedAudioDeviceIDs.contains(uid) {
            facts.missingSources.append("The selected microphone is disconnected; relink it in Audio.")
        }
        for input in settings.audioInputs where input.isEnabled && !deviceMonitor.connectedAudioDeviceIDs.contains(input.deviceUID) {
            facts.missingSources.append("An enabled additional audio input is disconnected; relink it in Audio.")
        }
        let demanded = CaptureSourceKey.demanded(layers: layers, sources: sceneStore.sources)
            .union(CaptureSourceKey.demandedAppAudio(sources: sceneStore.sources))
        var required: Set<PermissionsManager.Kind> = []
        if settings.micVolume > 0 { required.insert(.microphone) }
        for key in demanded {
            switch key {
            case .camera(let camera):
                required.insert(.camera)
                if let id = camera.deviceID, !deviceMonitor.connectedCameraIDs.contains(id) {
                    facts.missingSources.append("A configured camera is disconnected.")
                } else if camera.deviceID == nil && deviceMonitor.connectedCameraIDs.isEmpty {
                    facts.missingSources.append("No camera is connected.")
                }
            case .screen(let screen):
                required.insert(.screenCapture)
                if screen.target == .display, let rawID = screen.targetIdentifier,
                   let displayID = UInt32(rawID), !deviceMonitor.connectedDisplayIDs.contains(displayID) {
                    facts.missingSources.append("A configured display is disconnected.")
                }
            case .appAudio: required.insert(.screenCapture)
            default: break
            }
            if isPipelineRunning, capturePool.frameAvailability(for: key) == false {
                facts.unverifiedSources.append("A camera or screen source has not delivered a usable frame; verify it in Sources.")
            }
            if capturePool.problem(for: key) != nil || capturePool.isMissing(key) {
                // Source errors can carry private paths/URLs. Show a safe repair
                // instruction; the source inspector contains the detailed status.
                facts.missingSources.append("A program source reports an availability problem; repair it in Sources.")
            }
        }
        facts.permissionIssues = required.sorted { $0.rawValue < $1.rawValue }.compactMap { kind in
            if permissions.status(for: kind) == .unavailable { return "\(kind.title) is temporarily unavailable; retry after unlocking this Mac and checking the display." }
            return permissions.status(for: kind) == .granted ? nil : "\(kind.title) permission is required; repair it in Settings."
        }
        facts.sourceCount = layers.count
        facts.previewRunning = isPipelineRunning
        facts.programAudioPeak = programAudioPeak
        facts.destinationCount = destinations.enabled.count
        for destination in destinations.enabled {
            let managed = destination.providerBinding != nil
            let credentials = managed ? DestinationCredentials() : destinations.savedCredentials(for: destination.id)
            var errors = DestinationValidator.errors(destination, credentials: credentials)
            if destination.providerBinding?.provider == .youtube {
                facts.unverifiedSources.append("\(destination.name): Start requires a fresh owned event/bound-stream review and explicit sending-video consent.")
            } else if managed {
                errors.append("Managed start review is unavailable for this provider. Review its external controls and explicitly use a manual destination.")
            } else {
                if credentials.endpoint.isEmpty { errors.append("Missing endpoint URL.") }
                if destination.transport.requiresKey && credentials.streamKey.isEmpty { errors.append("Missing stream key.") }
            }
            facts.destinationErrors += errors.map { "\(destination.name): \($0)" }
            let canvasProfile = destination.canvas == .secondary ? activeSecondaryProfile : settings.outputProfile
            let profile = destination.effectiveProfile(program: canvasProfile)
            facts.profileErrors += (destination.ingestLimits ?? .conservative(for: destination.transport))
                .errors(profile: profile, codec: destination.videoCodec,
                        keyframeSeconds: destination.keyframeSeconds ?? 2, audioBitrate: destination.audioBitrate)
            if !destination.transport.supports(destination.videoCodec) {
                facts.profileErrors.append("\(destination.name): unsupported transport codec.")
            }
            if !capabilities.hardwareTier.fits(width: profile.canvasWidth, height: profile.canvasHeight) ||
                profile.frameRate > capabilities.hardwareMaxFrameRate {
                facts.profileErrors.append("\(destination.name): exceeds this Mac's estimated hardware limits.")
            }
        }
        if !capabilities.hardwareTier.fits(width: activeProfile.canvasWidth, height: activeProfile.canvasHeight) ||
            activeProfile.frameRate > capabilities.hardwareMaxFrameRate {
            facts.profileErrors.append("Program canvas exceeds this Mac's estimated hardware limits.")
        }
        if checksSecondary {
            if let error = canvasStartError(destinations: [.init(name: "Secondary preflight", canvas: .secondary)]) {
                facts.profileErrors.append(error)
            }
            if !capabilities.hardwareTier.fits(width: activeSecondaryProfile.canvasWidth, height: activeSecondaryProfile.canvasHeight) ||
                activeSecondaryProfile.frameRate > capabilities.hardwareMaxFrameRate {
                facts.profileErrors.append("Secondary canvas exceeds this Mac's estimated hardware limits.")
            }
        }
        let plan = outputEncodingPlan(program: settings.outputProfile)
        // Count active/finalizing encoder owners even when their destinations
        // no longer appear in the saved plan. Recording reservations remain
        // separate so the checklist applies the combined studio limit once.
        facts.encoderCount = max(plan.encoderSessions, activePublishingEncoderCount)
        facts.recordingEncoderReservations = recordingEncoderReservations.recordingCount
        facts.sharedH264AAC = destinations.sharesFixedH264AAC
        facts.testedEncoderBudget = destinations.measuredSessionLimit > 0 ? destinations.measuredSessionLimit : nil
        facts.requiredUplinkMbps = plan.requiredUplinkMbps
        facts.measuredUplinkMbps = destinations.measuredUplinkMbps > 0 ? destinations.measuredUplinkMbps : nil
        return facts
    }

    // MARK: - Pipeline demand (preview / stream / recording independence)

    /// RecordingController subscribes to the engine's frames here so its
    /// output keeps the render pipeline alive even with the preview off
    /// (and vice versa).
    func noteRecordingStarted(canvas: OutputCanvas = .program) {
        recordingDemand += 1
        if canvas == .secondary { secondaryRecordingDemand += 1 }
        updatePipelineDemand()
    }

    func noteRecordingStopped(canvas: OutputCanvas = .program) {
        recordingDemand = max(0, recordingDemand - 1)
        if canvas == .secondary { secondaryRecordingDemand = max(0, secondaryRecordingDemand - 1) }
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    private var pipelineNeeded: Bool {
        previewState == .active || streamState.isActive || recordingDemand > 0 || externalDisplayDemand > 0 || virtualCameraDemand > 0
    }

    private func updatePipelineDemand() {
        if pipelineNeeded, !isPipelineRunning {
            startPipeline()
        } else if !pipelineNeeded, isPipelineRunning {
            stopPipeline()
        }
        if isPipelineRunning {
            reconcileSourceDemand()
            applyProgramAudioBindings()
        }
    }

    // MARK: - Output profile (staged vs active, W07)

    /// True when an output owns the encode geometry: resolution/fps edits made
    /// now must wait for the next session (encoders can't be re-dimensioned
    /// mid-program, and the recording writer's input is locked to the size of
    /// its first frame).
    private var outputsOwnProfile: Bool {
        streamState.isActive || destinationOutputs.encoderSessionCount > 0 || recordingDemand > 0 || !recordingEncoderReservations.recordings.isEmpty || externalDisplayDemand > 0 || virtualCameraDemand > 0
    }

    /// Public read for the W04 settings session: while this is true,
    /// connection and canvas/fps edits stage for the next session.
    var outputSessionActive: Bool { outputsOwnProfile }
    var reservedRecordingEncoderCount: Int { recordingEncoderReservations.recordingCount }
    var activePublishingEncoderCount: Int { destinationOutputs.encoderSessionCount }

    /// Applies a just-saved settings snapshot from the shared settings
    /// session (W04, issue #67). Updates the controller's working copy so no
    /// consumer reads a stale snapshot, then applies what is safe RIGHT NOW:
    /// the output profile follows the W07 staged/active rules, a mic-volume
    /// change reaches the live mix in place (the engine ramps the mic
    /// channel's gain — no click, no encoder reconfigure), and a
    /// preferred-input change restarts mic capture only while no output owns
    /// the session. Everything else (connection, bitrate, codec, voice
    /// polish) is read at the next session start, exactly as before.
    func applySavedSettings(_ newSettings: StreamSettings) {
        let previous = settings
        if newSettings.audioInputs != previous.audioInputs || newSettings.preferredAudioInputUID != previous.preferredAudioInputUID {
            audioEngine.cancelGuestTalkback()
        }
        settings = newSettings
        applyOutputProfile(newSettings.outputProfile,
                           destination: newSettings.selectedProtocol)
        if newSettings.micVolume != previous.micVolume {
            let volume = Float(max(0, min(newSettings.micVolume, 2)))
            // A04: a settings Apply must not clear a mixer mic mute.
            let muted = mixerGains[.microphone(deviceUID: nil)]?.isMuted ?? false
            mixerGains[.microphone(deviceUID: nil)] = (volume, muted)
            Task { await audioEngine.setChannelGain(.microphone(deviceUID: nil),
                                                    volume: volume, isMuted: muted) }
        }
        if newSettings.preferredAudioInputUID != previous.preferredAudioInputUID,
           isPipelineRunning, !outputsOwnProfile {
            startAudioInput()
        }
        // A05 (issue #84): additional-input enable/mapping edits are a LIVE
        // surface — they apply in place even while an output owns the encode
        // geometry (a new mic channel joins the running mix; nothing about
        // the encoder or the canvas changes). The exclusion re-check also
        // covers a preferred-input change: the device the default mic
        // channel now uses must never double-capture as its own channel.
        if newSettings.audioInputs != previous.audioInputs
            || newSettings.preferredAudioInputUID != previous.preferredAudioInputUID {
            if isPipelineRunning {
                audio.startAdditionalInputs(newSettings.audioInputs,
                                            excludingDeviceUID: newSettings.preferredAudioInputUID)
                syncAdditionalMicChannels()
            }
        }
        // A08 (issue #120): per-channel FX chain edits (and the legacy
        // voice-polish toggle they fall back to) are a LIVE surface — the
        // new chain lands on each channel's RUNNING insert as parameter
        // updates, so a rack edit or a settings Apply never restarts
        // capture, resets a ring, or gaps the audio.
        if newSettings.channelFX != previous.channelFX
            || newSettings.voicePolishEnabled != previous.voicePolishEnabled {
            syncChannelFXChains()
        }
        // A07 (issue #119): monitoring enable/device are LIVE session state —
        // the player retargets in place (engine restart on a real device
        // change), independent of the encode-geometry ownership rules above.
        if newSettings.monitoringEnabled != previous.monitoringEnabled
            || newSettings.monitorOutputDeviceUID != previous.monitorOutputDeviceUID {
            monitorOutput.applyConfiguration(enabled: newSettings.monitoringEnabled,
                                             deviceUID: newSettings.monitorOutputDeviceUID)
        }
        // A09 (issue #121): the echo handling mode is live session state like
        // monitoring — an edit refreshes the voice-isolation state report in
        // place (mic modes are read-only for apps; Stream guides, not sets).
        if newSettings.echoHandlingMode != previous.echoHandlingMode {
            refreshEchoHandlingState()
        }
        // A10 (issue #122): A/V delay and ducking edits are LIVE session
        // state (the mixer/A07 precedent) — engine-side read-window shifts
        // and ramped gain automation, no capture restart, no clock re-anchor.
        if newSettings.audioDelaysMs != previous.audioDelaysMs
            || newSettings.videoDelaysMs != previous.videoDelaysMs {
            syncDelays(newSettings)
        }
        if newSettings.ducking != previous.ducking {
            syncDucking(newSettings.ducking)
        }
        updateMonitorFeedbackRisk()
        capturePool.applyPrivacyDefaults(newSettings)
    }

    /// Entry point for settings edits (W04: `applySavedSettings(_:)` routes
    /// here after the shared settings session persists; the controller's own
    /// `settings` snapshot is also refreshed at session start). With a stream
    /// or recording active the edit is STAGED and surfaces via `stagedProfile`
    /// ("applies on next session"); otherwise it applies immediately,
    /// reconfiguring the preview pipeline in place.
    func applyOutputProfile(_ profile: OutputProfile,
                            destination proto: StreamCore.StreamProtocol? = nil) {
        let clamped = capabilities.clampedToHardware(profile)
        if outputsOwnProfile {
            stagedProfile = clamped == activeProfile ? nil : clamped
            return
        }
        setActiveProfile(clamped)
    }

    private func setActiveProfile(_ profile: OutputProfile) {
        let changed = profile != activeProfile
        activeProfile = profile
        updateSecondaryGeometryIfIdle()
        refreshPrimaryMonitors()
        stagedProfile = nil
        // G06 (issue #113): PDF `.fill` framing reads the output canvas off
        // the render tick via the lock-protected snapshot.
        OutputCanvasStore.shared.publish(profile.canvasSize)
        // Align the scene graph's canvas reference (S01) with the output
        // canvas; transforms are normalized, so layers are not repositioned.
        sceneStore.setCanvasSize(profile.canvasSize)
        guard changed, isPipelineRunning else { return }
        // Live output change (only possible while no stream/recording owns the
        // geometry): the engines re-anchor their clocks and re-pool their
        // buffers at the new canvas/fps on the next tick.
        let canvasSize = profile.canvasSize
        let fps = encodeFrameRate
        let previous = programGeometryCommand
        let generation = UUID(); programGeometryGeneration = generation
        programGeometryCommand = Task { [weak self, engine] in
            await previous?.value
            await engine.setOutput(canvasSize: canvasSize, frameRate: fps)
            guard let self, self.programGeometryGeneration == generation else { return }
            self.refreshOptionalMonitorsAfterGeometry()
        }
        let previewEngine = self.previewEngine
        let previewSize = resourcePreviewSize(canvasSize)
        let previewFPS = min(fps, previewResourceLevel.maximumFrameRate)
        schedulePreviewGeometry { await $0.setOutput(canvasSize: previewSize, frameRate: previewFPS) }
    }

    /// Applies a staged profile once no stream/recording owns the geometry.
    /// Safe to call from every session-end path; a no-op unless staged + idle.
    private func promoteStagedProfileIfOutputsIdle() {
        guard !outputsOwnProfile else { return }
        if let stagedProfile { setActiveProfile(stagedProfile) }
        updateSecondaryGeometryIfIdle()
    }

    private func startPipeline() {
        guestProgramReturnAuthority.change(active: true)
        isPipelineRunning = true
        resourceBudgetCoordinator?.start()
        resilienceTask = Task { [weak self] in
            while !Task.isCancelled && self != nil {
                self?.evaluateSourceResilience()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        startAudioEngine()
        startAudioInput()
        reconcileSourceDemand()
        let program = previewProgram.programScene
        let canvasSize = activeProfile.canvasSize
        let fps = encodeFrameRate
        let previous = programGeometryCommand
        let generation = UUID(); programGeometryGeneration = generation
        programGeometryCommand = Task { [weak self, engine] in
            await previous?.value
            await engine.run(scene: program, canvasSize: canvasSize, frameRate: fps)
            guard let self, self.programGeometryGeneration == generation else { return }
            self.refreshOptionalMonitorsAfterGeometry()
        }
        if previewState == .active {
            startPreviewEngine()
        }
    }

    /// Starts the A01 audio engine and routes the microphone channel: the
    /// mic's A08 FX chain runs as the channel's INSERT (its position moved
    /// here from the publisher's per-track path, so the mix is processed
    /// exactly once — the A08 FX seam), and the settings mic volume becomes
    /// the channel's program gain. The insert box ALWAYS registers, even
    /// with the chain Off (zero-cost passthrough), so a rack edit can enable
    /// FX live without an engine restart. Capture-source channels
    /// self-register on their first audio buffer and get their S05 binding
    /// gains from `applyProgramAudioBindings`.
    private func startAudioEngine() {
        let audioEngine = self.audioEngine
        let settings = self.settings
        // A04: the dispatcher's mixer gain for the mic (fader + mute) wins
        // over the raw settings volume once one has been pushed.
        let micMixerGain = mixerGains[.microphone(deviceUID: nil)]
        let micID = AudioChannelID.microphone(deviceUID: nil)
        // A08: the engine (re)start wiped every channel, so all insert boxes
        // are rebuilt fresh from settings.
        channelFXBoxes = [micID: ChannelFXInsertBox(chain: settings.fxChain(forChannelLabel: micID.label))]
        mediaAudioChannelIDs = []; mediaAudioDemand.replace([:])
        let micBox = channelFXBoxes[micID]!
        Task {
            await audioEngine.run()
            await audioEngine.setBusGain(.program, gain: self.privacySlateActive ? 0 : self.programBusGain)
            await audioEngine.addChannel(micID, resetInsert: { micBox.reset() }) { sample in
                micBox.process(sample)
            }
            await audioEngine.setChannelGain(.microphone(deviceUID: nil),
                                             volume: micMixerGain?.volume
                                                ?? Float(max(0, min(settings.micVolume, 2))),
                                             isMuted: micMixerGain?.isMuted ?? false)
        }
        // A05 (issue #84): the engine (re)start wiped every channel, so the
        // additional mic channels all register fresh from settings.
        additionalMicChannelIDs = []
        syncAdditionalMicChannels()
        applyProgramAudioBindings()
        // A09 (issue #121): the engine (re)start wiped every tap-fed channel,
        // so the feedback diagnostics re-register their reference/mic taps
        // and start with fresh detector state.
        startFeedbackDiagnostics()
    }

    /// A05 (issue #84): the additional (UID-pinned) mic channels the current
    /// settings enable — excluding the device the DEFAULT mic channel
    /// already captures (the legacy preferred input), which must never
    /// double-capture as its own channel.
    private func wantedAdditionalMicChannels() -> Set<AudioChannelID> {
        Set(settings.audioInputs.compactMap { selection -> AudioChannelID? in
            guard selection.isEnabled,
                  selection.deviceUID != settings.preferredAudioInputUID else { return nil }
            return .microphone(deviceUID: selection.deviceUID)
        })
    }

    /// A05 (issue #84): diffs the enabled additional mic channels against
    /// the engine registration and syncs it — newly enabled devices get a
    /// channel with their OWN A08 FX insert instance (per-channel processing
    /// state; the A08 FX seam) and their mirrored mixer gain;
    /// disabled/relinked-away channels are torn down. Channels that keep
    /// running are untouched (no ring/FX reset on an unrelated edit).
    private func syncAdditionalMicChannels() {
        let wanted = wantedAdditionalMicChannels()
        let added = wanted.subtracting(additionalMicChannelIDs)
        let removed = additionalMicChannelIDs.subtracting(wanted)
        guard !added.isEmpty || !removed.isEmpty else { return }
        additionalMicChannelIDs = wanted
        let audioEngine = self.audioEngine
        let settings = self.settings
        let gains = mixerGains
        for id in removed {
            channelFXBoxes[id] = nil
        }
        for id in added {
            channelFXBoxes[id] = ChannelFXInsertBox(chain: settings.fxChain(forChannelLabel: id.label))
        }
        let boxes = channelFXBoxes
        Task {
            for id in removed {
                await audioEngine.removeChannel(id)
            }
            for id in added {
                let box = boxes[id]!
                await audioEngine.addChannel(id, resetInsert: { box.reset() }) { sample in
                    box.process(sample)
                }
                await audioEngine.setChannelGain(id,
                                                 volume: gains[id]?.volume ?? 1,
                                                 isMuted: gains[id]?.isMuted ?? false)
            }
        }
        // A09 (issue #121): the diagnostics' isolated mic taps follow the
        // same channel diff, so every mic channel gets a howl detector.
        for id in removed { removeFeedbackMicTap(id) }
        for id in added { addFeedbackMicTap(id) }
    }

    /// A08 (issue #120): pushes each channel's CURRENT effective chain (the
    /// persisted per-channel chain, else the legacy voice-polish mapping)
    /// onto its running insert box — a live parameter update, never a
    /// capture restart or ring reset. Called from `applySavedSettings` when
    /// `channelFX` or the legacy `voicePolishEnabled` toggle changed.
    private func syncChannelFXChains() {
        for (id, box) in channelFXBoxes {
            if case .media = id { box.update(settings.channelFX[id.label] ?? .preset(.off)) }
            else { box.update(settings.fxChain(forChannelLabel: id.label)) }
        }
    }

    /// A11 (issue #123): the hosted Audio Units running in one channel's FX
    /// graph, keyed by chain-slot ID (empty while the channel is idle or
    /// when no slot loaded). The FX rack binds its generic parameter editor
    /// to these; the handles' parameter tree / fullState are the unit's
    /// thread-safe surface.
    func hostedAudioUnitHandles(forChannelLabel label: String) -> [UUID: HostedAudioUnitHandle] {
        channelFXBoxes.first(where: { $0.key.label == label })?.value.hostedAudioUnitHandles() ?? [:]
    }

    /// Starts mic capture on the preferred input from settings, falling back
    /// to the system default when none is chosen or the chosen device is gone.
    private func startAudioInput() {
        audio.start(preferredDeviceUID: settings.preferredAudioInputUID)
        // A05 (issue #84): arm every enabled additional input device; the
        // device the default mic channel uses is excluded so it never
        // captures twice.
        audio.startAdditionalInputs(settings.audioInputs,
                                    excludingDeviceUID: settings.preferredAudioInputUID)
        // A09 (issue #121): mic capture (re)started — re-read the OS mic mode
        // on the device now in use.
        refreshEchoHandlingState()
    }

    /// Stop participates in both source-plane command chains. An older run
    /// cannot reach the actor after this stop and reanimate a retired pipeline.
    @discardableResult
    private func scheduleProgramEngineStop() -> Task<Void, Never> {
        let program = programGeometryCommand, secondary = secondaryGeometryCommand
        programGeometryGeneration = UUID(); secondaryGeometryGeneration = UUID()
        let engine = self.engine
        let command = Task {
            await program?.value
            await secondary?.value
            await engine.stop()
        }
        programGeometryCommand = command; secondaryGeometryCommand = command
        return command
    }

    private func stopPipeline() {
        resourceBudgetCoordinator?.stop()
        mediaAudioChannelIDs = []; mediaAudioDemand.replace([:])
        channelFXBoxes = channelFXBoxes.filter { if case .media = $0.key { return false }; return true }
        audioEngine.cancelGuestTalkback()
        guestProgramReturnAuthority.change(active: false)
        guestReturnVideoSink?.stopProgramReturn()
        isPipelineRunning = false
        resilienceTask?.cancel(); resilienceTask = nil
        failureTracker.resetObservations()
        resilientFrames.clear()
        _ = scheduleProgramEngineStop()
        schedulePreviewGeometry { await $0.stop() }
        let audioEngine = self.audioEngine
        Task { await audioEngine.stop() }
        // A09 (issue #121): stop the diagnostics poll and drop the taps with
        // the pipeline (the next start re-registers them fresh).
        stopFeedbackDiagnostics()
        capturePool.stopAll()
        audio.stop()
        promoteStagedProfileIfOutputsIdle()
    }

    /// A07 (issue #119): flags the feedback-risk routing combination — the
    /// device the monitor is ACTUALLY playing through is also an enabled
    /// capture input (the preferred mic or an enabled A05 additional input).
    /// The monitor signal would be re-captured electrically and loop into the
    /// program mix. CoreAudio device UIDs and `AVCaptureDevice.uniqueID`s are
    /// the same strings on macOS, so the comparison is direct. Runs on
    /// settings applies and on every monitor-state change.
    private func updateMonitorFeedbackRisk() {
        guard monitorOutput.isEnabled,
              let effectiveUID = monitorOutput.effectiveDeviceUID else {
            monitorFeedbackRiskDeviceUID = nil
            return
        }
        var inputUIDs = Set(settings.audioInputs.filter(\.isEnabled).map(\.deviceUID))
        if let preferred = settings.preferredAudioInputUID {
            inputUIDs.insert(preferred)
        }
        monitorFeedbackRiskDeviceUID = inputUIDs.contains(effectiveUID) ? effectiveUID : nil
    }

    // MARK: - Scene → source routing (S05, issue #73)

    /// Reconciles physical captures with what the two compositions actually
    /// reference: the UNION of the program snapshot and — only while the
    /// monitors are visible — the staged scene. Visible layers resolve through
    /// the `SceneStore` source registry into `CaptureSourceKey`s (the registry
    /// is the identity authority; unbound layers fall back to their inline
    /// payload), and the pool starts a capture on its first reference, stops
    /// it when the last reference goes away, and leaves a capture both scenes
    /// share running across a Take (no flicker/black frames).
    ///
    /// The union is what makes staged work leak-proof at the source level
    /// (W03): staging a camera-only scene never stops the screen capture the
    /// outgoing program is still using, and a staged scene's sources don't get
    /// picked/started while the monitors are off. Screen capture uses the
    /// system content picker on FIRST use, so a staged switch into a screen
    /// layout may need one user confirmation; a cancel simply leaves the scene
    /// showing its other source, and restarts of an unchanged source reuse the
    /// remembered selection instead of re-prompting.
    private func currentBrowserAudioMixer() -> MixerSettings? {
        if let current = browserAudioMixerSettings { return current() }
        return settings.mixer
    }
    private func prepareBrowserAudioMixer() async -> BrowserWidgetHelperSession.MixerPreparation? {
        // Live commands can run while the engine actor is awaited. Never let an
        // older seed replace their newer intent and then open the privacy gate.
        for _ in 0..<8 {
            guard let snapshot = currentBrowserAudioMixer() else { return nil }
            let prepared = await audioEngine.prepareClosedApplicationMixer(.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID), mixer: snapshot)
            guard prepared else { return nil }
            if currentBrowserAudioMixer() == snapshot {
                return .init(isCurrent: { [weak self] in self?.currentBrowserAudioMixer() == snapshot })
            }
        }
        return nil // Sustained churn remains unavailable, with no unbounded preparation work.
    }

    private func reconcileSourceDemand() {
        guard isPipelineRunning else { return }
        let staged = previewState == .active ? previewProgram.stagedScene : nil
        // S06: expand nested-scene references (cycle-guarded) against the
        // persisted scene registry before computing demand, so a camera used
        // only inside a nested scene still captures.
        let registry = SceneGraph.index(sceneStore.scenes)
        let standby = resilience.policy.standbySceneID.flatMap { id in sceneStore.scenes.first { $0.id.rawValue == id } }
        let layers = [previewProgram.programScene, staged, standby, fallbackOriginalScene].compactMap { $0 }
            .flatMap { scene in
                var layers = SceneGraph.flattenedVisibleLayers(of: scene, in: registry)
                if secondaryCanvasDemanded { layers += SceneGraph.flattenedVisibleLayers(of: scene.composition(for: .secondary), in: registry) }
                return layers
            }
        // G09 (issue #116): project overlay media (animated images / alpha
        // video) composites ABOVE every scene, so its playout demand comes
        // from the overlay list, not scene layers: an overlay demands its
        // media source while visible in the program OR staged composition
        // (a per-scene hide narrows the demand exactly like a scene-layer
        // visibility toggle). Being in the SAME unioned demand set, a shared
        // overlay source keeps playing across Takes untouched — no restart.
        let overlayLayers = sceneStore.overlays.filter { overlay in
            guard overlay.isVisible else { return false }
            let hiddenInProgram = previewProgram.programScene?
                .hiddenOverlayIDs.contains(overlay.id) ?? false
            let hiddenInStaged = staged?.hiddenOverlayIDs.contains(overlay.id) ?? false
            return !hiddenInProgram || (staged != nil && !hiddenInStaged)
        }
        let standbyLayers = resilience.policy.sourceRules.compactMap { rule -> LayerNode? in
            guard rule.mode == .standby, let id = rule.standbySourceID,
                  let source = sceneStore.sources.first(where: { $0.id.rawValue == id }) else { return nil }
            return LayerNode(name: source.name, sourceID: source.id, payload: source.payload, transform: .fullscreen)
        }
        let demand = CaptureSourceKey.demanded(layers: layers + overlayLayers + standbyLayers,
                                               sources: sceneStore.sources)
            // A06 (issue #118): app-audio sources demand capture by
            // REGISTRATION (registered + enabled), independent of which scene
            // is staged/program — unioned here so the W02 pipeline gate and
            // `stopAll` still govern their lifecycle.
            .union(CaptureSourceKey.demandedAppAudio(sources: sceneStore.sources))
            .union(isolatedCaptureSubscriptions.values)
            .union(isolatedVideoCaptureSubscriptions.values)
        let programLayers = previewProgram.programScene.map { scene in
            SceneGraph.flattenedVisibleLayers(of: scene, in: registry) +
                (secondaryProgramOutputDemanded ? SceneGraph.flattenedVisibleLayers(of: scene.composition(for: .secondary), in: registry) : [])
        } ?? []
        let programOverlays = sceneStore.overlays.filter {
            $0.isVisible && !(previewProgram.programScene?.hiddenOverlayIDs.contains($0.id) ?? false)
        }
        let programAudioKeys = privacySlateActive || previewProgram.programScene == nil ? [] : CaptureSourceKey.demanded(
            layers: programLayers + programOverlays, sources: sceneStore.sources)
        if let browserSession = BrowserOverlayHelperBackend.qualificationSession, browserSession.ownsMixer(audioEngine) {
            browserSession.prepareMixerForAudio = { [weak self] in await self?.prepareBrowserAudioMixer() }
        }
        audioEngine.setScreenCaptureChannels(Set(demand.compactMap { key in
            if case .appAudio(let payload) = key { return .application(bundleID: payload.channelBundleID) }
            if case .screen = key { return .capture(key) }
            return nil
        }))
        capturePool.reconcile(demand: demand, settings: settings, programAudioKeys: programAudioKeys)
        let mediaChannels = Set(demand.compactMap { key -> AudioChannelID? in
            if case .media(let id) = key { return .media(id) }; return nil
        }).union(soundboardAudioReferences.keys)
        syncMediaAudioChannels(mediaChannels)
        configureResilientFrames(demand: demand)
        // A01: the audio engine keeps exactly the channels its captures can
        // feed — the mic plus one per demanded capture key. Stopped captures
        // stop delivering, and their channels (rings, converters, FX state)
        // are torn down here; pending gains survive so a re-created channel
        // keeps its mix position.
        let keep = Set(demand.map { key -> AudioChannelID in
            // A02: media playout keys map onto `.media` channels (keyed by
            // registry source ID), not capture channels.
            if case .media(let id) = key { return .media(id) }
            // A06: app-audio keys map onto `.application` channels (keyed by
            // the target's bundle ID / the system-mix channel key).
            if case .appAudio(let payload) = key {
                return .application(bundleID: payload.channelBundleID)
            }
            return .capture(key)
        }).union([.microphone(deviceUID: nil)])
            // A05: enabled additional mic channels survive pruning too — a
            // mic's capture lifetime is settings-driven, not scene demand.
            .union(additionalMicChannelIDs)
            .union(capturePool.browserAudioChannels)
            .union(mediaAudioChannelIDs)
        let audioEngine = self.audioEngine
        let demandFence = mediaAudioDemand, revision = mediaAudioDemand.currentRevision()
        Task { await audioEngine.pruneChannels(keeping: keep, ifCurrent: { demandFence.matches(revision: revision) }) }
    }

    private func key(for source: SourceDefinition) -> CaptureSourceKey? {
        CaptureSourceKey.demanded(layers: [LayerNode(name: source.name, sourceID: source.id,
            payload: source.payload, transform: .fullscreen)], sources: sceneStore.sources).first
    }

    private func configureResilientFrames(demand: Set<CaptureSourceKey>) {
        resilienceDemand = demand
        var modes = Dictionary(uniqueKeysWithValues: demand.map { ($0, resilience.policy.defaultSourceMode) })
        var standbys: [CaptureSourceKey: CaptureSourceKey] = [:]
        for rule in resilience.policy.sourceRules {
            guard let source = sceneStore.sources.first(where: { $0.id.rawValue == rule.sourceID }),
                  let primary = key(for: source) else { continue }
            modes[primary] = rule.mode
            if rule.mode == .standby, let id = rule.standbySourceID,
               let standbySource = sceneStore.sources.first(where: { $0.id.rawValue == id }),
               let standbyKey = key(for: standbySource), standbyKey != primary,
               !failureTracker.latched.contains(standbyKey) { standbys[primary] = standbyKey }
        }
        resilientFrames.configure(active: demand, modes: modes, failed: failureTracker.latched, standbys: standbys)
    }

    private func evaluateSourceResilience() {
        guard isPipelineRunning, !privacySlateActive else { return }
        // A deliberate operator Take supersedes an automatic standby scene.
        if let fallbackSceneID, previewProgram.programScene?.id != fallbackSceneID {
            fallbackOriginalScene = nil; self.fallbackSceneID = nil
        }
        let unavailable = Set(resilienceDemand.filter { capturePool.frameAvailability(for: $0) == false })
        let reported = Set(resilienceDemand.filter { capturePool.isMissing($0) || capturePool.problem(for: $0) != nil })
        let failures = failureTracker.update(active: resilienceDemand, unavailable: unavailable,
            reportedFailures: reported, now: ProcessInfo.processInfo.systemUptime,
            graceSeconds: resilience.policy.failureGraceSeconds,
            automaticallyRestore: resilience.policy.automaticallyRestoreSources)
        configureResilientFrames(demand: resilienceDemand)
        let status = sceneStore.sources.compactMap { source -> String? in
            guard let sourceKey = key(for: source), failures.contains(sourceKey) else { return nil }
            let mode = resilience.policy.sourceRules.first { $0.sourceID == source.id.rawValue }?.mode
                ?? resilience.policy.defaultSourceMode
            return "\(source.name): \(mode.label)\(reported.contains(sourceKey) ? " (unavailable)" : " (restore when ready)")"
        }
        sourceFailoverStatus = status.isEmpty && !failures.isEmpty ? ["\(failures.count) inline sources use their configured fallback."] : status
        let registry = SceneGraph.index(sceneStore.scenes)
        let watched = fallbackOriginalScene ?? previewProgram.programScene
        let watchedLayers = watched.map { SceneGraph.flattenedVisibleLayers(of: $0, in: registry) } ?? []
        let watchedOverlays = sceneStore.overlays.filter { $0.isVisible && !(watched?.hiddenOverlayIDs.contains($0.id) ?? false) }
        let programKeys = CaptureSourceKey.demanded(layers: watchedLayers + watchedOverlays, sources: sceneStore.sources)
        if !failures.intersection(programKeys).isEmpty,
           let id = resilience.policy.standbySceneID,
           let standby = sceneStore.scenes.first(where: { $0.id.rawValue == id }), standby.id != watched?.id,
           fallbackOriginalScene == nil {
            fallbackOriginalScene = previewProgram.programScene
            fallbackSceneID = standby.id
            previewProgram.setResilienceProgram(standby)
            resilience.noteSourceFallback("Source failed: program switched to standby scene \(standby.name). Output sessions remain connected.")
        } else if failures.intersection(programKeys).isEmpty, fallbackOriginalScene != nil,
                  resilience.policy.automaticallyRestoreSources {
            restoreResilienceProgram()
        }
    }

    /// Explicit restoration never starts a publisher/recorder. Sources that
    /// remain missing immediately re-enter their configured fallback.
    func restoreResilienceProgram() {
        guard !resilience.isLocked else { return }
        if let original = fallbackOriginalScene, previewProgram.programScene?.id == fallbackSceneID {
            previewProgram.setResilienceProgram(original)
        }
        fallbackOriginalScene = nil; fallbackSceneID = nil
        failureTracker.restore()
        privacySlateActive = false
        privacySlateScene = nil
        guestProgramReturnAuthority.change()
        guestReturnVideoSink?.stopProgramReturn()
        privacyGate.setScene(nil)
        applyMixerBusGain(.program, gain: programBusGain)
        reconcileSourceDemand(); evaluateSourceResilience()
        resilience.noteSourceFallback("Program restore requested. Outputs restart only through their explicit start controls.")
    }

    private func enterPrivacySlate() {
        capturePool.retireBrowserAudio()
        audioEngine.cancelGuestTalkback()
        guard !privacySlateActive else { return }
        fallbackOriginalScene = previewProgram.programScene
        let slate = Scene(name: "Offline", layers: [LayerNode(name: "Offline notice",
            payload: .text(TextSourcePayload(text: "OFFLINE — RESTORE MANUALLY", alignment: .center)),
            transform: .fullscreen)], background: .solid(colorHex: "#101010"),
            hiddenOverlayIDs: Set(sceneStore.overlays.map(\.id)))
        fallbackSceneID = slate.id
        privacySlateScene = slate
        privacySlateActive = true
        guestProgramReturnAuthority.change()
        guestReturnVideoSink?.stopProgramReturn()
        privacyGate.setScene(slate)
        applyMixerBusGain(.program, gain: programBusGain)
        previewProgram.setResilienceProgram(slate)
    }

    /// The W03 program seam (W05 Take, issue #68; W08 swap point, issue #65):
    /// lands the program snapshot on the program engine. The engine swaps its
    /// scene value between ticks, so the outgoing composition changes
    /// atomically per frame — the tick loop, the shared clock, and every
    /// capture source keep running untouched (no program media restart).
    /// Called from the controller's observation of
    /// `PreviewProgramModel.programScene`.
    func publishSceneToProgram(_ scene: Scene) {
        if scene.secondaryCanvas?.isValid != true, guestReturnVideoSink?.returnVideoSource == .secondary {
            guestReturnVideoSink?.stopProgramReturn()
        }
        updateSecondaryGeometryIfIdle()
        Task { await engine.updateScene(scene) }
        // G08 (issue #115): program scene-entry applies each web widget's
        // sceneEntryRefresh policy (the capture itself never restarts).
        capturePool.noteWebWidgetSceneEntries(
            sceneID: scene.id,
            layers: SceneGraph.flattenedVisibleLayers(of: scene, in: SceneGraph.index(sceneStore.scenes)),
            sources: sceneStore.sources)
        // A01: audio follows the program atomically with video — the scene's
        // S05 `AudioBinding`s become ramped channel gains (click-free Take).
        applyProgramAudioBindings()
    }

    /// Pushes the PROGRAM scene's per-layer `AudioBinding`s (S05) onto the
    /// audio engine's capture channels: a visible screen layer's mute/volume
    /// becomes its channel's program gain, and every capture channel NOT
    /// bound in the program scene ramps to silence (a staged-only source must
    /// never leak into the outgoing mix — the audio reading of W03). The mic
    /// is not scene-bound; its gain comes from settings. Multiple layers
    /// sharing one source: the first visible binding wins (documented).
    private func applyProgramAudioBindings() {
        guard let program = previewProgram.programScene else { return }
        let registry = SceneGraph.index(sceneStore.scenes)
        let layers = SceneGraph.flattenedVisibleLayers(of: program, in: registry) +
            (secondaryProgramOutputDemanded ? SceneGraph.flattenedVisibleLayers(of: program.composition(for: .secondary), in: registry) : [])
        var gains: [AudioChannelID: (volume: Float, isMuted: Bool)] = [:]
        for layer in layers {
            let payload = layer.sourceID
                .flatMap { id in sceneStore.sources.first(where: { $0.id == id }) }?.payload
                ?? layer.payload
            guard case .screen(let screen) = payload else { continue }
            let id = AudioChannelID.capture(.screen(screen))
            if gains[id] == nil {
                gains[id] = (Float(layer.audio.volume), layer.audio.isMuted)
            }
        }
        let audioEngine = self.audioEngine
        Task { await audioEngine.applyProgramCaptureGains(gains) }
        // A02 (issue #97): media channels follow the same program-binding
        // rule — a visible media layer's `AudioBinding` becomes its
        // channel's program gain; every other DEMANDED media channel ramps
        // to silence (a staged-only source must never leak into the outgoing
        // mix — the same W03 reading the capture-gain call applies above).
        // `applyProgramCaptureGains` only covers `.capture` channels, so
        // media gains go through the documented per-channel gain API here.
        let staged = previewState == .active ? previewProgram.stagedScene : nil
        // G09 (issue #116): overlay media sources are in playout demand
        // (reconcileSourceDemand above) but carry no AudioBinding — project
        // overlays are VISUAL branding, so their channels ride the
        // no-binding default (volume 0) and stay silent. Including them in
        // the demanded set is what makes that explicit instead of leaking a
        // unity-gain default onto program.
        let demandLayers = [previewProgram.programScene, staged].compactMap { $0 }
            .flatMap { scene in
                SceneGraph.flattenedVisibleLayers(of: scene, in: registry) +
                    (secondaryCanvasDemanded ? SceneGraph.flattenedVisibleLayers(of: scene.composition(for: .secondary), in: registry) : [])
            }
            + sceneStore.overlays.filter { $0.payload.isMedia }
        let demandedMedia: Set<SourceDefinitionID> = Set(
            CaptureSourceKey.demanded(layers: demandLayers, sources: sceneStore.sources)
                .compactMap { key -> SourceDefinitionID? in
                    guard case .media(let id) = key else { return nil }
                    return id
                })
        var mediaBindings: [SourceDefinitionID: (volume: Float, isMuted: Bool)] = [:]
        for layer in layers {
            guard let sourceID = layer.sourceID,
                  mediaBindings[sourceID] == nil else { continue }
            let payload = sceneStore.source(withID: sourceID)?.payload ?? layer.payload
            guard payload.isMedia else { continue }
            mediaBindings[sourceID] = (Float(layer.audio.volume), layer.audio.isMuted)
        }
        let mixer = mixerGains
        Task {
            for id in demandedMedia {
                let binding = mediaBindings[id] ?? (volume: 0, isMuted: false)
                let gain = mixer[.media(id)] ?? (volume: 1, isMuted: false)
                await audioEngine.setChannelGain(.media(id),
                                                 volume: binding.volume * gain.volume,
                                                 isMuted: binding.isMuted || gain.isMuted)
            }
        }
    }

    // MARK: - Permission transitions (C10, issue #79)

    /// Folds permission-status transitions into capture recovery. Only real
    /// transitions retire only the affected capture authority. A regrant
    /// clears that permission's signal history before reopening; sources keep
    /// their exact identity and outputs keep their existing session/clock.
    /// Transient discovery unavailability is not a confirmed TCC denial.
    private func handlePermissionChange(snapshot: [PermissionsManager.Kind: PermissionsManager.Status]? = nil,
                                        resumeAvailable: Bool = false) {
        let previous = lastPermissionStatuses
        let current = snapshot ?? permissions.statuses
        lastPermissionStatuses = current
        guard previous != current || resumeAvailable else { return }
        let changed = PermissionsManager.Kind.allCases.filter { previous[$0] != current[$0] || resumeAvailable }
        for kind in changed { permissionRecoveryRevisions[kind] = UUID() }
        func transitioned(_ kind: PermissionsManager.Kind, to status: PermissionsManager.Status) -> Bool {
            previous[kind] != status && current[kind] == status
        }
        if transitioned(.camera, to: .denied) {
            capturePool.noteCameraPermissionRevoked()
        }
        if transitioned(.screenCapture, to: .denied) {
            audioEngine.denyCapturePermission(.screenCapture)
            capturePool.noteScreenPermissionRevoked()
        }
        if transitioned(.microphone, to: .denied) {
            audioEngine.denyCapturePermission(.microphone)
            audioEngine.cancelGuestTalkback()
            audio.setPermissionAvailable(false)
        }
        for kind in changed where current[kind] == .granted {
            let revision = permissionRecoveryRevisions[kind]!
            let restartMic = !resumeAvailable || !audio.isCapturing(.microphone(deviceUID: nil))
            Task { [weak self] in
                guard let self, self.permissionRecoveryRevisions[kind] == revision else { return }
                switch kind {
                case .camera: break
                case .screenCapture:
                    await self.audioEngine.restoreCapturePermission(.screenCapture)
                    guard self.permissionRecoveryRevisions[kind] == revision else { return }
                    self.capturePool.restoreScreenPermission()
                case .microphone:
                    await self.audioEngine.restoreCapturePermission(.microphone)
                    guard self.permissionRecoveryRevisions[kind] == revision else { return }
                    self.audio.setPermissionAvailable(true)
                }
                guard !self.resilience.isLocked, self.isPipelineRunning else { return }
                if kind == .microphone {
                    if restartMic { self.startAudioInput() }
                } else { self.capturePool.retryErroredSources() }
                self.evaluateSourceResilience()
            }
        }
        evaluateSourceResilience()
    }

    // MARK: - Engine cadence

    private var encodeFrameRate: Int {
        // The profile's rate, defensively clamped to the hardware ceiling —
        // the settings UI gates on the same `OutputCapabilities`, so this only
        // fires for hand-edited or migrated settings files.
        min(max(activeProfile.frameRate, 1), max(1, capabilities.hardwareMaxFrameRate))
    }


}

/// A08 (issue #120): carries the non-Sendable `ChannelFXProcessor` into a
/// mic channel's `@Sendable` insert closure, and hands chain updates from
/// the main actor to the capture thread. `@unchecked Sendable` is sound
/// here: `process` is only ever called under the channel's ingest lock (one
/// thread at a time, off the main actor — the same confinement the
/// publishers gave their `VoicePolishProcessor` instances), and the chain
/// value crosses threads only through the unfair lock. The processor
/// re-applies a changed chain onto its running graph itself, so updates are
/// lock-free for the audio path apart from the tiny value hand-off.
private final class ChannelFXInsertBox: @unchecked Sendable {
    let demandID = UUID()
    private let processor = ChannelFXProcessor()
    private var lock = os_unfair_lock_s()
    private var chain: ChannelFXChain

    init(chain: ChannelFXChain) {
        self.chain = chain
    }

    /// Main-actor write: swap the chain the next processed buffer will run.
    func update(_ chain: ChannelFXChain) {
        os_unfair_lock_lock(&lock)
        self.chain = chain
        os_unfair_lock_unlock(&lock)
    }
    /// Called only under the channel ingest lock, like process(_:).
    func reset() { processor.reset() }

    /// Capture-thread read + process (under the channel's ingest lock).
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        os_unfair_lock_lock(&lock)
        let chain = self.chain
        os_unfair_lock_unlock(&lock)
        return processor.process(sample, chain: chain)
    }

    /// A11 (issue #123): the hosted Audio Units currently running in this
    /// channel's graph (main-thread safe — the processor publishes them
    /// under their own lock). A persisted slot with no handle did not load
    /// (plugin missing, load failure, or the channel is idle).
    func hostedAudioUnitHandles() -> [UUID: HostedAudioUnitHandle] {
        processor.hostedHandles()
    }
}

// MARK: - A09 echo handling & feedback diagnostics (issue #121)

extension StreamController {
    private static let feedbackLog = Logger(subsystem: "com.joeblau.Stream",
                                            category: "feedback-diagnostics")

    /// Registers the diagnostics taps and starts the poll loop. Called from
    /// `startAudioEngine` so every engine (re)start re-taps fresh channels:
    /// the MONITOR bus is the reference (tapped independently of the A07
    /// player tap — a tap, never a channel, per the A07 feedback-safety rule)
    /// and each mic channel gets an isolated (pre-fader) tap feeding its own
    /// howl detector. All taps are bounded and drop-oldest, so diagnostics
    /// can never stall the mix.
    func startFeedbackDiagnostics() {
        stopFeedbackDiagnostics()
        let analyzer = feedbackAnalyzer
        analyzer.reset()
        let monitorTap = AudioTapSubscription()
        feedbackMonitorTap = monitorTap
        let audioEngine = self.audioEngine
        Task {
            await audioEngine.addTap(bus: .monitor, token: monitorTap.token,
                                     capacity: 8) { sample in
                analyzer.ingestReference(sample)
            }
        }
        addFeedbackMicTap(.microphone(deviceUID: nil))
        for id in additionalMicChannelIDs { addFeedbackMicTap(id) }
        feedbackDiagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.evaluateFeedbackDiagnostics()
            }
        }
    }

    /// Stops the poll loop and removes every diagnostics tap (pipeline stop).
    func stopFeedbackDiagnostics() {
        feedbackDiagnosticsTask?.cancel()
        feedbackDiagnosticsTask = nil
        if let feedbackMonitorTap { removeAudioTap(feedbackMonitorTap) }
        feedbackMonitorTap = nil
        for (_, tap) in feedbackMicTaps { removeAudioTap(tap) }
        feedbackMicTaps = [:]
        feedbackAnalyzer.reset()
        feedbackDiagnostics = FeedbackDiagnostics()
        lastLoggedFeedbackSignature = ""
    }

    /// Registers (idempotently) one mic channel's isolated tap + detector.
    func addFeedbackMicTap(_ id: AudioChannelID) {
        guard feedbackMicTaps[id] == nil else { return }
        let analyzer = feedbackAnalyzer
        analyzer.addChannel(label: id.label)
        let tap = AudioTapSubscription()
        feedbackMicTaps[id] = tap
        let audioEngine = self.audioEngine
        let label = id.label
        Task {
            await audioEngine.addIsolatedTap(channel: id, token: tap.token,
                                             capacity: 8) { sample in
                analyzer.ingestMic(sample, channelLabel: label)
            }
        }
    }

    /// Removes one mic channel's tap + detector (channel left demand).
    func removeFeedbackMicTap(_ id: AudioChannelID) {
        if let tap = feedbackMicTaps.removeValue(forKey: id) {
            removeAudioTap(tap)
        }
        feedbackAnalyzer.removeChannel(label: id.label)
    }

    /// Re-reads the OS Voice Isolation state for the preferred mode. Mic
    /// modes are user-controlled (Control Center → Mic Mode; the API is
    /// read-only), so when the user prefers Voice Isolation Stream reports
    /// whether macOS has it active on the default mic's device and the UI
    /// guides from there — Stream never applies a second suppressor on top.
    func refreshEchoHandlingState() {
        guard settings.echoHandlingMode == .voiceIsolation else {
            voiceIsolationActive = nil
            return
        }
        // `activeMicrophoneMode` is an app-level (class) property (macOS
        // 12+): macOS reports the mic mode in effect for this app's capture.
        voiceIsolationActive = AVCaptureDevice.activeMicrophoneMode == .voiceIsolation
    }

    /// The 2 Hz fold: detector readings + the routing facts → the published
    /// `FeedbackDiagnostics`, with a support-log line on every transition of
    /// the warning set (issue #121: "log events for support").
    private func evaluateFeedbackDiagnostics() {
        let risks = feedbackAnalyzer.riskByChannel()
        var input = FeedbackRouteInput()
        input.monitoringEnabled = monitorOutput.isEnabled
        input.monitorOutputUID = monitorOutput.effectiveDeviceUID
        input.defaultInputUID = AVCaptureDevice.default(for: .audio)?.uniqueID
        input.preferredInputUID = settings.preferredAudioInputUID
        input.additionalEnabledInputUIDs = settings.audioInputs
            .filter(\.isEnabled).map(\.deviceUID)
        input.howlingChannelLabels = risks.filter { $0.value.isWarning }
            .map(\.key).sorted()
        var diagnostics = FeedbackDiagnostics()
        diagnostics.howlRiskByChannel = risks
        diagnostics.routeIssues = FeedbackRouteAnalyzer.issues(for: input)
        diagnostics.voiceIsolationActive = voiceIsolationActive
        feedbackDiagnostics = diagnostics

        let signature = (diagnostics.routeIssues.map(\.id)
            + risks.filter { $0.value.isWarning }.map { "howl.\($0.key)" }).sorted()
            .joined(separator: "|")
        guard signature != lastLoggedFeedbackSignature else { return }
        lastLoggedFeedbackSignature = signature
        if signature.isEmpty {
            Self.feedbackLog.info("Feedback diagnostics clear")
        } else {
            Self.feedbackLog.warning("Feedback diagnostics: \(signature, privacy: .public)")
        }
    }
}


// MARK: - A10 A/V delay alignment & speech ducking (issue #122)

extension StreamController {
    /// Pushes the persisted per-source delays onto the engines. Audio delays
    /// (by channel label) go to the mix engine, which shifts each channel's
    /// ring read on the shared host clock; video delays (by registry source
    /// ID) resolve through the registry to capture keys and go to BOTH
    /// composition engines, so the staged preview and the outgoing program
    /// show the same compensated picture. All engine-side maps survive
    /// (re)starts, so re-pushing is cheap self-healing, never a reset.
    func syncDelays(_ settings: StreamSettings) {
        let audioEngine = self.audioEngine
        Task { await audioEngine.setChannelDelays(settings.audioDelaysMs) }
        var video: [CaptureSourceKey: Double] = [:]
        for source in sceneStore.sources {
            let key: CaptureSourceKey?
            switch source.payload {
            case .camera(let payload): key = .camera(payload)
            case .screen(let payload): key = .screen(payload)
            // Media playout already rides the shared clock (A02); the other
            // kinds have no capture-latency mismatch to compensate.
            default: key = nil
            }
            guard let key,
                  let ms = settings.videoDelaysMs[Self.videoDelaySettingsKey(for: source.id)]
            else { continue }
            video[key] = ms
        }
        let engine = self.engine
        let previewEngine = self.previewEngine
        Task {
            await engine.setVideoDelays(video)
            await previewEngine.setVideoDelays(video)
        }
    }

    /// Pushes the persisted ducking configuration onto the mix engine. A
    /// bypass (disabled / empty selection) lands as nil, which ramps every
    /// ducked channel back to unity — restoring the user-set gain exactly.
    func syncDucking(_ ducking: DuckingSettings) {
        let chunkSeconds = Double(AudioMixEngine.chunkFrames)
            / Double(AudioMixEngine.sampleRate)
        let configuration = AudioMixEngine.DuckingConfiguration(
            ducking, chunkDurationSeconds: chunkSeconds)
        let audioEngine = self.audioEngine
        Task { await audioEngine.setDucking(configuration) }
    }

    /// A10: the settings key a registry source's video delay persists under
    /// (`source.<uuid>`). Keyed by the registry ID — not the payload — so a
    /// relink or target edit never loses the user's alignment.
    static func videoDelaySettingsKey(for id: SourceDefinitionID) -> String {
        "source.\(id)"
    }
}
