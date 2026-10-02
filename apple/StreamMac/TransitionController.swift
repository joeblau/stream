import Combine
import CoreMedia
import CoreVideo
import Foundation
import StreamCore
import os.lock

// MARK: - Transition model (S09, issue #100)
//
// A Take switches the program composition through a configurable transition:
// cut (the pre-S09 behavior), dissolve (crossfade), dip-to-color, wipe,
// slide, or a full-screen media stinger. The PROJECT default lives on
// `SceneDocument.defaultTransition`; a scene's `Scene.transition` overrides
// it (nil = inherit). Both persist additively, exactly like S07's
// `defaultBackground`/`background`.

/// The transition kind a Take renders.
enum SceneTransitionStyle: String, Codable, CaseIterable, Sendable {
    case cut
    case dissolve
    case dipToColor
    case wipe
    case slide
    case stinger
    case layerMotion

    var displayName: String {
        switch self {
        case .cut: return "Cut"
        case .dissolve: return "Dissolve"
        case .dipToColor: return "Dip to Color"
        case .wipe: return "Wipe"
        case .slide: return "Slide"
        case .stinger: return "Stinger"
        case .layerMotion: return "Layer Motion"
        }
    }
}

/// The travel direction of a wipe (the reveal edge's motion) or a slide (the
/// incoming scene's motion).
enum TransitionDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        }
    }
}

/// One transition configuration: style, duration, and the style-specific
/// extras (direction, dip color, stinger media + cut point). The stinger's
/// media identity is a security-scoped bookmark (the sandboxed access grant),
/// same pattern as A02 media sources / A03 scene sounds.
struct SceneTransition: Hashable, Codable, Sendable {
    var style: SceneTransitionStyle
    /// Blend duration in seconds (dissolve/dip/wipe/slide, and the honest
    /// fallback duration for a stinger whose media is missing). Ignored by
    /// cut; a stinger's own length comes from its media file.
    var durationSeconds: Double
    var direction: TransitionDirection
    /// `#RRGGBB` the dip-to-color transition passes through.
    var dipColorHex: String
    /// Security-scoped bookmark for the stinger video (alpha-aware).
    var stingerBookmarkData: Data?
    var stingerFileName: String?
    /// Seconds from stinger playback start at which the scene swaps under it.
    var stingerCutPointSeconds: Double
    /// Linear stinger audio gain, 0...2 (1 = unity).
    var stingerVolume: Double
    var motionEasing: MotionEasing
    var motionFallback: MotionFallback

    init(style: SceneTransitionStyle = .cut,
         durationSeconds: Double = 0.35,
         direction: TransitionDirection = .right,
         dipColorHex: String = "#000000",
         stingerBookmarkData: Data? = nil,
         stingerFileName: String? = nil,
         stingerCutPointSeconds: Double = 1.0,
         stingerVolume: Double = 1,
         motionEasing: MotionEasing = .easeInOut,
         motionFallback: MotionFallback = .dissolve) {
        self.style = style
        self.durationSeconds = durationSeconds
        self.direction = direction
        self.dipColorHex = dipColorHex
        self.stingerBookmarkData = stingerBookmarkData
        self.stingerFileName = stingerFileName
        self.stingerCutPointSeconds = stingerCutPointSeconds
        self.stingerVolume = stingerVolume
        self.motionEasing = motionEasing
        self.motionFallback = motionFallback
    }

    /// The factory/persisted fallback: a cut, so upgraded installs keep the
    /// exact pre-S09 Take behavior until the user picks a transition.
    static let `default` = SceneTransition()

    /// Decode every field with a default so documents written before later
    /// refinements keep loading (the established additive-wire pattern).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(SceneTransitionStyle.self, forKey: .style) ?? .cut
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0.35
        direction = try container.decodeIfPresent(TransitionDirection.self, forKey: .direction) ?? .right
        dipColorHex = try container.decodeIfPresent(String.self, forKey: .dipColorHex) ?? "#000000"
        stingerBookmarkData = try container.decodeIfPresent(Data.self, forKey: .stingerBookmarkData)
        stingerFileName = try container.decodeIfPresent(String.self, forKey: .stingerFileName)
        stingerCutPointSeconds = try container.decodeIfPresent(Double.self, forKey: .stingerCutPointSeconds) ?? 1.0
        stingerVolume = try container.decodeIfPresent(Double.self, forKey: .stingerVolume) ?? 1
        motionEasing = try container.decodeIfPresent(MotionEasing.self, forKey: .motionEasing) ?? .easeInOut
        motionFallback = try container.decodeIfPresent(MotionFallback.self, forKey: .motionFallback) ?? .dissolve
    }

    var validationError: String? {
        guard durationSeconds.isFinite, (0...10).contains(durationSeconds) else {
            return "Transition duration must be between 0 and 10 seconds."
        }
        guard stingerCutPointSeconds.isFinite, (0...600).contains(stingerCutPointSeconds),
              stingerVolume.isFinite, (0...2).contains(stingerVolume) else {
            return "Stinger cut point must be 0–600 seconds and volume 0–2."
        }
        return nil
    }
}

// MARK: - Take → program-engine hand-off
//
// The W03 seam (`StreamController.publishSceneToProgram` →
// `CompositionEngine.updateScene`) carries only the scene value, so the
// transition a Take resolved travels beside it: the dispatcher's Take path
// ARMS a request here, and every composition engine peeks at it from
// `updateScene`. Only an engine whose scene actually SWITCHES to the armed
// target inside the freshness window renders the transition — after a
// preview/program Take that is exactly the program engine (the preview
// engine already shows the staged scene and gets no update), while in
// direct-live mode both engines switch together and mirror the same
// transition, which is precisely that mode's contract.

/// One armed Take: switch to `targetSceneID` through `transition`.
struct ProgramTransitionRequest: Sendable {
    var targetSceneID: SceneID
    var transition: SceneTransition
    /// Host-clock seconds when the Take armed the request.
    var armedAtHostSeconds: Double

    /// Requests go stale fast: an updateScene that arrives long after its
    /// Take is an unrelated switch (e.g. a later preview selection) and must
    /// cut, never resurrect an old transition.
    var isFresh: Bool {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds - armedAtHostSeconds <= 1.5
    }
}

/// The process-wide hand-off of the armed Take transition from the
/// dispatcher (main actor) to the composition engines (their actors).
/// Lock-protected, so a mid-tick arm can never tear a read.
final class ProgramTransitionStore: @unchecked Sendable {
    static let shared = ProgramTransitionStore()

    private var lock = os_unfair_lock_s()
    private var request: ProgramTransitionRequest?

    func arm(_ request: ProgramTransitionRequest) {
        os_unfair_lock_lock(&lock)
        self.request = request
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> ProgramTransitionRequest? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return request
    }
}

// MARK: - Stinger playback bridge

/// The engine-side view of the in-flight stinger: the playback engine to
/// pull frames (and top up mix audio) from, the playback start on the shared
/// host clock (the cut-point timer), and the media duration once known.
struct StingerSnapshot: Sendable {
    var playback: MediaSourcePlayback?
    var startedAt: CMTime
    var cutPointSeconds: Double
    var durationSeconds: Double

    static let inactive = StingerSnapshot(playback: nil, startedAt: .zero,
                                          cutPointSeconds: 0, durationSeconds: 0)
}

/// The process-wide hand-off of stinger playback state from
/// `TransitionController` (main actor) to the composition engine pulling
/// stinger frames on its render tick. Clearing the store IS the
/// end-of-stinger signal the engine completes the transition on.
final class TransitionStingerStore: @unchecked Sendable {
    static let shared = TransitionStingerStore()

    private var lock = os_unfair_lock_s()
    private var stinger: StingerSnapshot?
    /// Set once playback reports `.playing`: load-time `.ready` statuses
    /// must not read as end-of-stinger (see TransitionController).
    private var didPlay = false

    var isActive: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return stinger != nil
    }

    var hasPlayed: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return didPlay
    }

    func arm(_ stinger: StingerSnapshot) {
        os_unfair_lock_lock(&lock)
        self.stinger = stinger
        didPlay = false
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        stinger = nil
        didPlay = false
        os_unfair_lock_unlock(&lock)
    }

    func markPlaying() {
        os_unfair_lock_lock(&lock)
        didPlay = true
        os_unfair_lock_unlock(&lock)
    }

    func updateDuration(_ seconds: Double) {
        os_unfair_lock_lock(&lock)
        if var stinger, stinger.durationSeconds <= 0 {
            stinger.durationSeconds = seconds
            self.stinger = stinger
        }
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> StingerSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return stinger ?? .inactive
    }
}

/// The lock-protected, off-main-readable payload cell behind the stinger's
/// `MediaSourcePlayback` (the A02 relink seam), same pattern as
/// SoundboardController's payload boxes.
private final class StingerPayloadBox: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var stored: MediaSourcePayload?

    var payload: MediaSourcePayload? {
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

// MARK: - Transition controller

/// S09 (issue #100): the main-actor owner of the Take-time transition
/// side-effects the composition engine can't perform itself — stinger media
/// playback and the transition lifecycle surface.
///
/// **Stinger sequencing.** A stinger Take arms the program-transition
/// request (the engine renders the scene swap), loads/restarts the stinger's
/// `MediaSourcePlayback` (A02 — the same pull-based playout and `.media(id)`
/// mix-channel audio path as any media source, untouched), and publishes it
/// through `TransitionStingerStore`. The program engine pulls stinger frames
/// per tick — the render tick is the playout cadence, exactly like media
/// layers — composites them fullscreen above everything, swaps the base
/// scene at the configured cut point (timed from playback start on the
/// shared host clock), and completes when the store clears (stinger end,
/// error, or supersession). The stinger is preloaded when configured so a
/// Take starts decoding immediately.
///
/// **Honest fallback.** A stinger transition with no media (or media that
/// fails) never fakes the effect: no playback is armed, the engine renders
/// the plain dissolve fallback for the configured duration, and the failure
/// surfaces through `lastError`.
///
/// **Mid-transition Take policy (documented).** The newest Take wins: the
/// engine cuts to the newest target scene and applies that Take's armed
/// transition (an armed stinger replaces any in-flight one); a superseded
/// stinger stops immediately. `transitionDidEnd` fires for the superseded
/// transition too — a supersession IS its defined end (the S11
/// playlist-auto-advance seam).
@MainActor
final class TransitionController: ObservableObject {
    /// The latest stinger failure/fallback notice, surfaced transiently in
    /// the diagnostics strip by the dispatcher.
    @Published private(set) var lastError: String?
    /// S11 seam: fires when a program transition reaches a defined end —
    /// blend completion (timer at the armed duration), stinger playback end
    /// or failure, or supersession by a newer Take. Carries the transition's
    /// target scene.
    let transitionDidEnd = PassthroughSubject<SceneID, Never>()

    private let controller: StreamController
    /// The A02 media-audio ingest the pool wires to the mix engine (the
    /// soundboard reads the same closure for its engines).
    private let audioIngest: (@Sendable (SourceDefinitionID, CMSampleBuffer) -> Void)?
    private var stingerPlayback: MediaSourcePlayback?
    private var stingerBookmark: Data?
    /// The transition awaiting its end notice (blend timer or stinger end).
    private var pendingEndTarget: SceneID?
    var hasActiveTransition: Bool { pendingEndTarget != nil }
    private var endNoticeTask: Task<Void, Never>?

    /// One fixed mix-channel identity for every stinger (one plays at a
    /// time) — a stable, namespaced `.media(id)` channel. `nonisolated` so
    /// the off-main audio-ingest closure can reference it.
    nonisolated static let stingerChannelID = SourceDefinitionID(
        UUID(uuidString: "E0900000-5A09-4009-8009-000000000009")!)

    init(controller: StreamController) {
        self.controller = controller
        audioIngest = controller.capturePool.onMediaAudioSample
    }

    // MARK: Take handling (the dispatcher's .take visual extension)

    /// Arms the Take's transition for the program engine and performs the
    /// media side-effects. Called only for scene CHANGES (same-scene edit
    /// takes cut, with the engine's layer fades animating visibility diffs).
    func handleTake(targetSceneID: SceneID, transition: SceneTransition) {
        ProgramTransitionStore.shared.arm(ProgramTransitionRequest(
            targetSceneID: targetSceneID,
            transition: transition,
            armedAtHostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds))
        // Supersession: the previous in-flight transition's defined end.
        endNoticeTask?.cancel()
        endNoticeTask = nil
        if let pendingEndTarget {
            transitionDidEnd.send(pendingEndTarget)
            self.pendingEndTarget = nil
        }
        stopStinger()
        switch transition.style {
        case .cut:
            break
        case .stinger:
            guard let bookmark = transition.stingerBookmarkData else {
                lastError = "The stinger transition has no media file — the Take fell back to a dissolve."
                scheduleEndNotice(targetSceneID: targetSceneID,
                                  after: transition.durationSeconds)
                return
            }
            startStinger(bookmark: bookmark,
                         fileName: transition.stingerFileName,
                         cutPointSeconds: transition.stingerCutPointSeconds,
                         volume: transition.stingerVolume,
                         targetSceneID: targetSceneID)
        default:
            scheduleEndNotice(targetSceneID: targetSceneID,
                              after: transition.durationSeconds)
        }
    }

    /// Loads the stinger media ahead of time (called when a stinger
    /// transition is configured, and at launch for restored settings), so a
    /// Take starts decoding immediately instead of mid-transition.
    func preloadStinger(for transition: SceneTransition?) {
        guard transition?.style == .stinger,
              let bookmark = transition?.stingerBookmarkData else { return }
        playback(for: bookmark, fileName: transition?.stingerFileName).load()
    }

    // MARK: Stinger lifecycle

    private func startStinger(bookmark: Data, fileName: String?,
                              cutPointSeconds: Double, volume: Double,
                              targetSceneID: SceneID) {
        let playback = playback(for: bookmark, fileName: fileName)
        TransitionStingerStore.shared.arm(StingerSnapshot(
            playback: playback,
            startedAt: CMClockGetTime(CMClockGetHostTimeClock()),
            cutPointSeconds: max(0, cutPointSeconds),
            durationSeconds: 0))
        pendingEndTarget = targetSceneID
        controller.applyMixerChannelGain(.media(Self.stingerChannelID),
                                         volume: Float(max(0, min(volume, 2))),
                                         isMuted: false)
        // load() is a no-op once loaded (a preloaded stinger skips straight
        // to restart); after a load failure it retries. restart() rewinds to
        // the file start and plays (pre-start requests are honored when a
        // still-loading file finishes configuring).
        playback.load()
        playback.restart()
    }

    private func stopStinger() {
        // Clear BEFORE stop(): statuses stop() publishes then read the store
        // as inactive and are correctly ignored as stale.
        TransitionStingerStore.shared.clear()
        stingerPlayback?.stop()
    }

    /// The stinger's playback engine for `bookmark`: the existing instance
    /// when the media is unchanged, else a fresh one (a bookmark change is a
    /// new file; building a new engine beats racing the A02 relink path on a
    /// Take's first tick). The old engine is stopped immediately.
    private func playback(for bookmark: Data, fileName: String?) -> MediaSourcePlayback {
        if let stingerPlayback, stingerBookmark == bookmark { return stingerPlayback }
        stingerPlayback?.stop()
        let box = StingerPayloadBox()
        box.payload = MediaSourcePayload(bookmarkData: bookmark,
                                         fileName: fileName,
                                         loops: false,
                                         autoplay: false,
                                         endAction: .stop)
        let playback = MediaSourcePlayback(sourceID: Self.stingerChannelID) { box.payload }
        let ingest = audioIngest
        playback.onAudioSample = { sample in
            ingest?(Self.stingerChannelID, sample)
        }
        playback.onStatus = { [weak self] _, status in
            if status.phase == .playing {
                TransitionStingerStore.shared.markPlaying()
            }
            if status.durationSeconds > 0 {
                TransitionStingerStore.shared.updateDuration(status.durationSeconds)
            }
            let wasActive = TransitionStingerStore.shared.isActive
            let hadPlayed = TransitionStingerStore.shared.hasPlayed
            Task { @MainActor [weak self] in
                self?.handleStingerStatus(status, wasActive: wasActive, hadPlayed: hadPlayed)
            }
        }
        stingerPlayback = playback
        stingerBookmark = bookmark
        return playback
    }

    /// End-of-stinger bookkeeping. `wasActive`/`hadPlayed` are sampled when
    /// the status is PUBLISHED (off-main), so stale statuses from a stopped
    /// or superseded playback can't clear a freshly armed stinger: the
    /// load-time `.ready` (before the first `.playing`) is not an end, while
    /// an `.error` always is — a failed stinger ends the transition honestly
    /// instead of holding it open.
    private func handleStingerStatus(_ status: MediaSourceStatus,
                                     wasActive: Bool, hadPlayed: Bool) {
        guard wasActive else { return }
        switch status.phase {
        case .error:
            lastError = status.errorMessage
                ?? "The stinger media failed to play — the Take completed without it."
            TransitionStingerStore.shared.clear()
            fireTransitionEnded()
        case .ready, .ended:
            guard hadPlayed else { return }
            TransitionStingerStore.shared.clear()
            fireTransitionEnded()
        default:
            break
        }
    }

    // MARK: End notices (S11 seam)

    /// Blend transitions end on the engine at the armed duration; mirror
    /// that with a timer so lifecycle consumers (S11 playlist auto-advance)
    /// observe every transition's end without reaching into the engine.
    private func scheduleEndNotice(targetSceneID: SceneID, after seconds: Double) {
        pendingEndTarget = targetSceneID
        endNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fireTransitionEnded()
        }
    }

    private func fireTransitionEnded() {
        guard let target = pendingEndTarget else { return }
        pendingEndTarget = nil
        transitionDidEnd.send(target)
    }
}
