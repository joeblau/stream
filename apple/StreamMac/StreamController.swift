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
    /// The latest STAGED composition for the PREVIEW monitor, ~30 fps (W03:
    /// rendered by the preview engine, so staged edits never touch program).
    @Published private(set) var previewImage: CGImage?
    /// The latest PROGRAM composition for the PROGRAM monitor, ~30 fps.
    @Published private(set) var programImage: CGImage?
    @Published var errorMessage: String?

    /// Convenience for UI; `streamState` carries the full picture.
    var isLive: Bool { streamState.isLive }
    var isPreviewing: Bool { previewState == .active }

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
    private let audioEngine = AudioMixEngine()
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
    private let engine: CompositionEngine
    /// The W03 preview engine: composites the STAGED scene for the PREVIEW
    /// monitor only. Same source providers, independent tick — preview work
    /// can never delay or re-anchor the program engine.
    private let previewEngine: CompositionEngine
    /// The W03 staged/program scene model; the engines follow its snapshots.
    private let previewProgram: PreviewProgramModel
    /// Reached from the capture callbacks (arbitrary queues) and the main actor.
    private let publisherBox = PublisherBox()
    private var publisher: (any Publisher)? {
        didSet { publisherBox.publisher = publisher }
    }
    private var publisherTask: Task<Void, Never>?
    /// Folds the publisher's lifecycle events into `streamState`.
    private var eventTask: Task<Void, Never>?
    /// Ordered publisher video path: the engine's publisher sink yields into
    /// this newest-only stream; one consumer awaits `appendVideo` in order.
    private var videoConsumer: Task<Void, Never>?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    /// Captures + engine are up. Independent from preview: an active stream
    /// or recording keeps the pipeline running with the preview off (W02).
    private var isPipelineRunning = false
    /// Count of recording outputs tapping the composited frames (0 or 1 today).
    private var recordingDemand = 0
    /// The PREVIEW monitor's preview-engine subscription (staged composition).
    private var previewMonitorSubscription: FrameSubscription?
    /// The PROGRAM monitor's program-engine subscription (registered while the
    /// monitors are visible; the publisher/recording have their own sinks).
    private var programMonitorSubscription: FrameSubscription?
    /// Converts staged-composition frames to CGImages, off the main actor.
    private let previewConverter = PreviewImageConverter()
    /// Converts program-composition frames to CGImages, off the main actor.
    private let programConverter = PreviewImageConverter()

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
    private var outputSizeSentToPublisher = false
    private var cancellables: Set<AnyCancellable> = []

    init(sceneStore: SceneStore, previewProgram: PreviewProgramModel,
         permissions: PermissionsManager) {
        self.sceneStore = sceneStore
        self.previewProgram = previewProgram
        self.permissions = permissions
        // The persisted profile is the canvas authority from launch, so the
        // preview opens at the configured geometry before any source frame
        // ever arrives.
        let persisted = settingsStore.load()
        self.destinations = DestinationSession(settings: persisted)
        self.settings = persisted
        self.activeProfile = persisted.outputProfile

        // The engines pull source pixels off-main through the pool's frame
        // providers; they never touch this controller's MainActor state. Both
        // engines share the same read-only providers (W03: one capture feeds
        // both the staged preview and the outgoing program; S05: the pool
        // keys those captures by source identity).
        let frames = capturePool.frames
        self.engine = CompositionEngine(
            screenProvider: { frames.latestScreenFrame() },
            cameraProvider: { frames.freshestCameraFrame() },
            canvasSize: persisted.outputProfile.canvasSize,
            frameRate: persisted.outputProfile.frameRate)
        self.previewEngine = CompositionEngine(
            screenProvider: { frames.latestScreenFrame() },
            cameraProvider: { frames.freshestCameraFrame() },
            // G11 (issue #117): preview shows annotations as SwiftUI chrome in
            // CanvasInteractionView — painting them into the image too would
            // double-draw them.
            annotationProvider: { .empty },
            canvasSize: persisted.outputProfile.canvasSize,
            frameRate: persisted.outputProfile.frameRate)
        OutputCanvasStore.shared.publish(persisted.outputProfile.canvasSize)

        // W03: scene edits and selection changes reach the engines ONLY
        // through the preview/program model's snapshots — never straight from
        // SceneStore — so staged work can't leak into the outgoing program.
        previewProgram.$stagedScene
            .sink { [weak self] scene in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileSourceDemand()
                    let engine = self.previewEngine
                    Task { await engine.updateScene(scene) }
                }
            }
            .store(in: &cancellables)
        previewProgram.$programScene
            .sink { [weak self] scene in
                Task { @MainActor [weak self] in
                    guard let self, let scene else { return }
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
        permissions.$statuses
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePermissionChange()
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
        let publisherBox = self.publisherBox
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
            publisherBox.publisher?.enqueueProgram(sample)
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

        // The publisher output subscribes once for the controller's lifetime:
        // the sink never blocks the engine (newest-only stream), and the
        // consumer below drops frames while no publisher owns the session.
        let (stream, continuation) = AsyncStream.makeStream(
            of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(1))
        videoContinuation = continuation
        videoConsumer = Task {
            for await sample in stream {
                if let publisher = publisherBox.publisher {
                    await publisher.appendVideo(sample)
                }
            }
        }
        let engine = self.engine
        let subscription = FrameSubscription()
        Task { [continuation] in
            await engine.addSink(token: subscription.token, capacity: 1) { frame in
                continuation.yield(frame.sampleBuffer)
            }
        }
        // A10 (issue #122): push the persisted delays/ducking onto the
        // engines once, so the first pipeline start is already aligned — the
        // engine-side maps (registry delays, delay lines, duck config) all
        // survive (re)starts, so this covers every later start too.
        syncDelays(persisted)
        syncDucking(persisted.ducking)
    }

    /// Live encode/uplink metrics for the stats HUD, straight from the publisher.
    func statsSnapshot() async -> LiveStats? {
        await publisher?.statsSnapshot()
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
                      sink: @escaping @Sendable (CompositedFrame) -> Void) -> FrameSubscription {
        let subscription = FrameSubscription()
        Task { await engine.addSink(token: subscription.token, capacity: capacity, sink: sink) }
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

    func removeAudioTap(_ subscription: AudioTapSubscription) {
        Task { await audioEngine.removeTap(subscription.token) }
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
    /// A08 (issue #120): each mic channel's FX insert box, keyed by channel
    /// ID. Boxes outlive settings applies so a chain edit lands as a
    /// parameter update on the RUNNING processor (no capture restart);
    /// they rebuild only when the engine (re)starts or the channel leaves.
    private var channelFXBoxes: [AudioChannelID: ChannelFXInsertBox] = [:]

    /// Live mixer channel gain (ramped). The dispatcher owns mixer state;
    /// this is its write path for non-scene-bound channels (the mic today,
    /// media/app/guest channels as those surfaces land). Capture channels are
    /// scene-bound (S05 `AudioBinding`s drive them from the program scene)
    /// and intentionally have no write path here.
    func applyMixerChannelGain(_ id: AudioChannelID, volume: Float, isMuted: Bool) {
        mixerGains[id] = (volume, isMuted)
        Task { await audioEngine.setChannelGain(id, volume: volume, isMuted: isMuted) }
    }

    /// Live mixer master gain for one bus (program/monitor/aux). The
    /// dispatcher folds bus mutes into the value it passes (0 while muted).
    func applyMixerBusGain(_ bus: AudioBus, gain: Float) {
        Task { await audioEngine.setBusGain(bus, gain: gain) }
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

    /// Same race-safe register/cancel as `addFrameSink`, but addressed at an
    /// explicit engine — the W03 studio monitors subscribe to BOTH engines
    /// (PREVIEW on the preview engine, PROGRAM on the program engine), while
    /// `addFrameSink` stays the program-engine fan-out for real outputs.
    private func addMonitorSink(to engine: CompositionEngine,
                                sink: @escaping @Sendable (CompositedFrame) -> Void) -> FrameSubscription {
        let subscription = FrameSubscription()
        Task { await engine.addSink(token: subscription.token, capacity: 1, sink: sink) }
        return subscription
    }

    private func removeMonitorSink(_ subscription: FrameSubscription,
                                   from engine: CompositionEngine) {
        Task { await engine.removeSink(subscription.token) }
    }

    // MARK: - Preview / stream lifecycle

    func startPreview() {
        guard previewState == .idle else { return }
        settings = settingsStore.load()
        applyOutputProfile(settings.outputProfile)
        previewState = .active
        // PREVIEW monitor: the staged composition from the preview engine.
        // PROGRAM monitor: the outgoing composition from the program engine.
        // Both conversions run on each subscription's serial queue, off-main;
        // the sinks self-throttle to ~30 fps before hopping to the UI.
        let previewConverter = self.previewConverter
        previewMonitorSubscription = addMonitorSink(to: previewEngine) { [weak self] frame in
            guard let image = previewConverter.makeImage(frame, throttleNanoseconds: 33_000_000) else { return }
            Task { @MainActor [weak self] in
                self?.previewImage = image
            }
        }
        let programConverter = self.programConverter
        programMonitorSubscription = addMonitorSink(to: engine) { [weak self] frame in
            guard let image = programConverter.makeImage(frame, throttleNanoseconds: 33_000_000) else { return }
            Task { @MainActor [weak self] in
                self?.programImage = image
            }
        }
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
        if let previewMonitorSubscription {
            removeMonitorSink(previewMonitorSubscription, from: previewEngine)
        }
        previewMonitorSubscription = nil
        if let programMonitorSubscription {
            removeMonitorSink(programMonitorSubscription, from: engine)
        }
        programMonitorSubscription = nil
        previewState = .idle
        previewImage = nil
        programImage = nil
        let previewEngine = self.previewEngine
        Task { await previewEngine.stop() }
        updatePipelineDemand()
    }

    /// (Re)starts the preview engine on the current staged composition. Only
    /// called while the monitors are visible and the pipeline is running.
    private func startPreviewEngine() {
        let staged = previewProgram.stagedScene
        let canvasSize = activeProfile.canvasSize
        let fps = encodeFrameRate
        Task { await previewEngine.run(scene: staged, canvasSize: canvasSize, frameRate: fps) }
    }

    func prepareForProjectChange() async {
        guard !outputSessionActive else { return }
        stopPreview()
        await engine.stop()
        await previewEngine.stop()
        await audioEngine.stop()
        capturePool.stopAll()
        audio.stop()
    }

    func goLive() {
        guard streamState.canStart else { return }
        settings = settingsStore.load()
        let errors = destinations.startErrors(program: settings.outputProfile)
        guard errors.isEmpty, let destination = destinations.enabled.first else {
            errorMessage = errors.joined(separator: "\n")
            return
        }
        settings = DestinationValidator.settings(destination,
            credentials: destinations.savedCredentials(for: destination.id), base: settings)
        applyOutputProfile(settings.outputProfile)
        // Go Live needs the render pipeline (frames to publish); the demand
        // check below starts it even if the user never turned the preview on.
        let publisher = makePublisher(for: settings.selectedProtocol)
        self.publisher = publisher
        outputSizeSentToPublisher = false
        streamState = .connecting
        updatePipelineDemand()
        let settings = self.settings
        publisherTask = Task { [weak self] in
            do {
                try await publisher.start(settings)
            } catch {
                self?.publisherDidFail(error)
            }
        }
        eventTask = Task { [weak self] in
            for await event in publisher.events {
                self?.handlePublisherEvent(event)
            }
        }
        // The canvas is known up front (profile-owned), so hand the encoder
        // its output size immediately instead of waiting for a first frame.
        applyOutputSizeIfPossible()
    }

    func stopStream() {
        guard streamState.isActive else { return }
        streamState = .stopping
        publisherTask?.cancel()
        publisherTask = nil
        eventTask?.cancel()
        eventTask = nil
        outputSizeSentToPublisher = false
        let ending = publisher
        publisher = nil
        guard let ending else {
            streamState = .idle
            updatePipelineDemand()
            return
        }
        Task { [weak self] in
            await ending.stop()
            self?.streamDidStop()
        }
    }

    // MARK: - Streaming state machine (folded from PublisherEvents)

    private func handlePublisherEvent(_ event: PublisherEvent) {
        switch event {
        case .connecting:
            // A retry attempt during .reconnecting keeps that state; only the
            // acknowledged publish below ends it.
            if !streamState.isActive {
                streamState = .connecting
            }
        case .published:
            // The ingest acknowledged the publish — the ONLY path to LIVE.
            if streamState.isActive {
                streamState = .live
                errorMessage = nil
            }
        case .reconnecting(let reason):
            if streamState == .live || streamState == .connecting {
                streamState = .reconnecting(reason: reason)
            }
        case .failed(let message):
            if streamState.isActive {
                failStream(message)
            }
        case .stopped:
            streamDidStop()
        }
    }

    private func streamDidStop() {
        guard streamState == .stopping else { return }
        streamState = .idle
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    private func publisherDidFail(_ error: Error) {
        // `.stopping` excluded: a late error from a publisher the user already
        // stopped must not flip the session to `.failed`.
        guard streamState.isActive, streamState != .stopping else { return }
        failStream(error.localizedDescription)
    }

    /// Ends the session into `.failed`: tears the publisher down and surfaces
    /// the message. From `.failed` the transport bar offers a fresh Go Live.
    private func failStream(_ message: String) {
        publisherTask?.cancel()
        publisherTask = nil
        eventTask?.cancel()
        eventTask = nil
        outputSizeSentToPublisher = false
        let ending = publisher
        publisher = nil
        streamState = .failed(message)
        errorMessage = message
        if let ending {
            Task { await ending.stop() }
        }
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    // MARK: - Pipeline demand (preview / stream / recording independence)

    /// RecordingController subscribes to the engine's frames here so its
    /// output keeps the render pipeline alive even with the preview off
    /// (and vice versa).
    func noteRecordingStarted() {
        recordingDemand += 1
        updatePipelineDemand()
    }

    func noteRecordingStopped() {
        recordingDemand = max(0, recordingDemand - 1)
        promoteStagedProfileIfOutputsIdle()
        updatePipelineDemand()
    }

    private var pipelineNeeded: Bool {
        previewState == .active || streamState.isActive || recordingDemand > 0
    }

    private func updatePipelineDemand() {
        if pipelineNeeded, !isPipelineRunning {
            startPipeline()
        } else if !pipelineNeeded, isPipelineRunning {
            stopPipeline()
        }
    }

    // MARK: - Output profile (staged vs active, W07)

    /// True when an output owns the encode geometry: resolution/fps edits made
    /// now must wait for the next session (encoders can't be re-dimensioned
    /// mid-program, and the recording writer's input is locked to the size of
    /// its first frame).
    private var outputsOwnProfile: Bool {
        streamState.isActive || recordingDemand > 0
    }

    /// Public read for the W04 settings session: while this is true,
    /// connection and canvas/fps edits stage for the next session.
    var outputSessionActive: Bool { outputsOwnProfile }

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
        let clamped = capabilities.clamped(profile, destination: proto ?? settings.selectedProtocol)
        if outputsOwnProfile {
            stagedProfile = clamped == activeProfile ? nil : clamped
            return
        }
        setActiveProfile(clamped)
    }

    private func setActiveProfile(_ profile: OutputProfile) {
        let changed = profile != activeProfile
        activeProfile = profile
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
        Task { await engine.setOutput(canvasSize: canvasSize, frameRate: fps) }
        let previewEngine = self.previewEngine
        Task { await previewEngine.setOutput(canvasSize: canvasSize, frameRate: fps) }
    }

    /// Applies a staged profile once no stream/recording owns the geometry.
    /// Safe to call from every session-end path; a no-op unless staged + idle.
    private func promoteStagedProfileIfOutputsIdle() {
        guard let stagedProfile, !outputsOwnProfile else { return }
        setActiveProfile(stagedProfile)
    }

    private func startPipeline() {
        isPipelineRunning = true
        startAudioEngine()
        startAudioInput()
        reconcileSourceDemand()
        let program = previewProgram.programScene
        let canvasSize = activeProfile.canvasSize
        let fps = encodeFrameRate
        Task { await engine.run(scene: program, canvasSize: canvasSize, frameRate: fps) }
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
        let micBox = channelFXBoxes[micID]!
        Task {
            await audioEngine.run()
            await audioEngine.addChannel(micID) { sample in
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
                await audioEngine.addChannel(id) { sample in
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
            box.update(settings.fxChain(forChannelLabel: id.label))
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
        if let uid = settings.preferredAudioInputUID,
           let device = audio.devices.first(where: { $0.uniqueID == uid }) {
            audio.start(device: device)
        } else {
            audio.start()
        }
        // A05 (issue #84): arm every enabled additional input device; the
        // device the default mic channel uses is excluded so it never
        // captures twice.
        audio.startAdditionalInputs(settings.audioInputs,
                                    excludingDeviceUID: settings.preferredAudioInputUID)
        // A09 (issue #121): mic capture (re)started — re-read the OS mic mode
        // on the device now in use.
        refreshEchoHandlingState()
    }

    private func stopPipeline() {
        isPipelineRunning = false
        let engine = self.engine
        Task { await engine.stop() }
        let previewEngine = self.previewEngine
        Task { await previewEngine.stop() }
        let audioEngine = self.audioEngine
        Task { await audioEngine.stop() }
        // A09 (issue #121): stop the diagnostics poll and drop the taps with
        // the pipeline (the next start re-registers them fresh).
        stopFeedbackDiagnostics()
        capturePool.stopAll()
        audio.stop()
        outputSizeSentToPublisher = false
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

    private func makePublisher(for transport: StreamCore.StreamProtocol) -> any Publisher {
        switch transport {
        case .rtmp, .rtmps:
            return RTMPPublisher()
        case .srt, .whip:
            return SessionPublisher(protocol: transport)
        }
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
    private func reconcileSourceDemand() {
        guard isPipelineRunning else { return }
        let staged = previewState == .active ? previewProgram.stagedScene : nil
        // S06: expand nested-scene references (cycle-guarded) against the
        // persisted scene registry before computing demand, so a camera used
        // only inside a nested scene still captures.
        let registry = SceneGraph.index(sceneStore.scenes)
        let layers = [previewProgram.programScene, staged].compactMap { $0 }
            .flatMap { SceneGraph.flattenedVisibleLayers(of: $0, in: registry) }
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
        let demand = CaptureSourceKey.demanded(layers: layers + overlayLayers,
                                               sources: sceneStore.sources)
            // A06 (issue #118): app-audio sources demand capture by
            // REGISTRATION (registered + enabled), independent of which scene
            // is staged/program — unioned here so the W02 pipeline gate and
            // `stopAll` still govern their lifecycle.
            .union(CaptureSourceKey.demandedAppAudio(sources: sceneStore.sources))
        capturePool.reconcile(demand: demand, settings: settings)
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
        let audioEngine = self.audioEngine
        Task { await audioEngine.pruneChannels(keeping: keep) }
    }

    /// The W03 program seam (W05 Take, issue #68; W08 swap point, issue #65):
    /// lands the program snapshot on the program engine. The engine swaps its
    /// scene value between ticks, so the outgoing composition changes
    /// atomically per frame — the tick loop, the shared clock, and every
    /// capture source keep running untouched (no program media restart).
    /// Called from the controller's observation of
    /// `PreviewProgramModel.programScene`.
    func publishSceneToProgram(_ scene: Scene) {
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
        let layers = SceneGraph.flattenedVisibleLayers(of: program, in: registry)
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
            .flatMap { SceneGraph.flattenedVisibleLayers(of: $0, in: registry) }
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
        Task {
            for id in demandedMedia {
                let binding = mediaBindings[id] ?? (volume: 0, isMuted: false)
                await audioEngine.setChannelGain(.media(id),
                                                 volume: binding.volume,
                                                 isMuted: binding.isMuted)
            }
        }
    }

    // MARK: - Permission transitions (C10, issue #79)

    /// Folds permission-status transitions into capture recovery. Only real
    /// transitions act: a re-granted camera/screen permission retries the
    /// sources its denial blocked (a pinned source resumes its exact
    /// identity; the pool never substitutes), a re-granted microphone
    /// restarts mic capture, and a camera revocation marks the affected
    /// sources without touching other sources or the outputs. Screen
    /// Recording revocation is probed from the pool's screen-error hook
    /// (`onScreenCaptureError` → `probeScreenAccess`), so the repair state
    /// surfaces even while preflight still says granted.
    private func handlePermissionChange() {
        let previous = lastPermissionStatuses
        let current = permissions.statuses
        lastPermissionStatuses = current
        func transitioned(_ kind: PermissionsManager.Kind, to status: PermissionsManager.Status) -> Bool {
            previous[kind] != status && current[kind] == status
        }
        if transitioned(.camera, to: .granted) || transitioned(.screenCapture, to: .granted) {
            capturePool.retryErroredSources()
        }
        if transitioned(.microphone, to: .granted), isPipelineRunning {
            startAudioInput()
        }
        if transitioned(.camera, to: .denied) {
            capturePool.noteCameraPermissionRevoked()
        }
    }

    // MARK: - Engine cadence

    private var encodeFrameRate: Int {
        // The profile's rate, defensively clamped to the hardware ceiling —
        // the settings UI gates on the same `OutputCapabilities`, so this only
        // fires for hand-edited or migrated settings files.
        min(max(activeProfile.frameRate, 1), max(1, capabilities.hardwareMaxFrameRate))
    }

    /// Hands the profile's canvas to the publisher exactly once per broadcast
    /// (`setOutputSize` itself also locks after the first call). The size is
    /// known at Go Live — no first-frame wait — so the encoder never starts at
    /// a source-derived size.
    private func applyOutputSizeIfPossible() {
        guard streamState.isActive, !outputSizeSentToPublisher,
              let publisher else { return }
        outputSizeSentToPublisher = true
        let canvasSize = activeProfile.canvasSize
        Task { await publisher.setOutputSize(canvasSize, nativeShortEdge: Int(min(canvasSize.width, canvasSize.height))) }
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

/// Lock-protected hand-off of the current publisher to the capture callbacks,
/// which fire on ScreenCaptureKit / audio queues (off the main actor) and call
/// only the publisher's nonisolated, thread-safe audio ingress.
private final class PublisherBox: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var stored: (any Publisher)?

    var publisher: (any Publisher)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return stored
        }
        set {
            os_unfair_lock_lock(&lock)
            stored = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

/// Converts engine frames to throttled CGImages for the SwiftUI preview.
/// `@unchecked Sendable`: every call arrives on the preview subscription's
/// single serial delivery queue, so the `CIContext` and throttle state are
/// never touched concurrently.
private final class PreviewImageConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastUpdateAt: UInt64 = 0

    func makeImage(_ frame: CompositedFrame, throttleNanoseconds: UInt64) -> CGImage? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastUpdateAt >= throttleNanoseconds else { return nil }
        lastUpdateAt = now
        guard let buffer = frame.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
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
