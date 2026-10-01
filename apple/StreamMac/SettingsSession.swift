import Foundation
import StreamCore

/// The single settings-editing session for the studio shell (W04, issue #67).
///
/// ONE object connects the three places settings live, so they cannot
/// diverge:
///
/// - `draft` — what the embedded settings area displays and edits;
/// - `activeSettings` — the last applied snapshot, pushed into
///   `StreamController` via `applySavedSettings(_:)`;
/// - `SettingsStore` — persistence (container JSON + per-protocol Keychain).
///
/// Edits mutate only the draft. `apply()` validates, persists, and applies in
/// one step; `revert()` — or simply closing the area — leaves the active
/// state untouched. Presentation (`isPresented`) also lives here, so the menu
/// command (⌘,), the toolbar toggle, the W05 command layer, and W06 first-run
/// share one entry point.
@MainActor
final class SettingsSession: ObservableObject {
    /// What the app is actually using. Updated only by `apply()`.
    @Published private(set) var activeSettings: StreamSettings
    /// The editing copy shown in the settings area. Mutating it changes
    /// nothing outside this object until `apply()`.
    @Published var draft: StreamSettings
    /// Whether the shell is presenting the embedded settings pane.
    @Published var isPresented = false
    /// A section the pane should scroll to when it next renders (W06: the
    /// first-run flow jumps straight to Connection). Consumed and cleared by
    /// the settings view after scrolling.
    @Published var requestedSection: Section?

    /// The settings pane's top-level sections, for deep-linking (W06).
    enum Section: String, Sendable {
        case connection, video, audio, chat, application
        /// C03 (issue #78): global capture-privacy defaults.
        case capturePrivacy
    }

    /// Opens the settings pane, optionally scrolled to a section — the entry
    /// point for guided jumps like the first-run flow's destination step.
    func showSettings(section: Section? = nil) {
        requestedSection = section
        isPresented = true
    }

    private let store: SettingsStore
    private let controller: StreamController
    private let capabilities = OutputCapabilities.current

    /// Per-protocol credential edits, keyed so switching the protocol picker
    /// mid-edit never loses an unapplied URL/key. Seeded lazily from the
    /// Keychain on first touch of each protocol.
    private var draftCredentials: [StreamProtocol: (url: String, key: String)] = [:]

    init(store: SettingsStore = SettingsStore(), controller: StreamController) {
        self.store = store
        self.controller = controller
        let loaded = store.load()
        activeSettings = loaded
        draft = loaded
        draftCredentials[loaded.selectedProtocol] = (loaded.rtmpURL, loaded.streamKey)
    }

    /// True while a stream or recording owns the encode geometry/destination:
    /// connection and canvas/fps edits then stage for the NEXT session (W07
    /// model generalized by W04).
    var isOutputActive: Bool { controller.outputSessionActive }

    /// The draft differs from the applied snapshot.
    var isDirty: Bool { draft != activeSettings }

    /// Malformed values that block Apply (empty-but-incomplete does not).
    var blockingErrors: [String] { SettingsValidator.blockingErrors(for: draft) }

    var canApply: Bool { isDirty && blockingErrors.isEmpty }

    /// Stashes the current protocol's edited credentials, switches the draft
    /// to `proto`, and recalls that protocol's edited/stored credentials —
    /// each protocol keeps its own Keychain slot.
    func selectProtocol(_ proto: StreamProtocol) {
        guard proto != draft.selectedProtocol else { return }
        draftCredentials[draft.selectedProtocol] = (draft.rtmpURL, draft.streamKey)
        draft.selectedProtocol = proto
        let credentials = draftCredentials[proto] ?? store.connectionSecrets(for: proto)
        draftCredentials[proto] = credentials
        draft.rtmpURL = credentials.url
        draft.streamKey = credentials.key
        if !proto.supports(draft.videoCodec) { draft.videoCodec = .h264 }
        // The new destination may carry less than the old one (e.g. 4K over
        // SRT → RTMP): reduce the profile honestly.
        draft.outputProfile = capabilities.clamped(draft.outputProfile, destination: proto)
    }

    /// Validates, persists, and applies the draft as one step. Returns false
    /// — leaving persisted and active state untouched — when validation
    /// fails, so an invalid value can never reach the store or the pipeline.
    @discardableResult
    func apply() -> Bool {
        guard blockingErrors.isEmpty else { return false }
        draftCredentials[draft.selectedProtocol] = (draft.rtmpURL, draft.streamKey)
        // Credentials the user edited under a non-selected protocol persist
        // too; `store.save` writes the selected protocol's slot itself.
        for (proto, credentials) in draftCredentials where proto != draft.selectedProtocol {
            store.saveConnectionSecrets(url: credentials.url, key: credentials.key, for: proto)
        }
        store.save(draft)
        activeSettings = draft
        controller.applySavedSettings(draft)
        return true
    }

    /// Discards every unapplied edit, returning the draft (and its
    /// per-protocol credential edits) to the active state.
    func revert() {
        draft = activeSettings
        draftCredentials = [activeSettings.selectedProtocol:
            (activeSettings.rtmpURL, activeSettings.streamKey)]
    }

    // MARK: - A04 mixer persistence (issue #83)

    /// Persists the mixer document straight into the APPLIED settings and
    /// mirrors it into the draft — the mixer is a live performance surface,
    /// not a draft/Apply editor. Mirroring keeps `draft.mixer` fresh so a
    /// later settings Apply can't roll mixer state back, and `isDirty` is
    /// unaffected. The dispatcher ramps the live engine gains itself.
    func persistMixer(_ mixer: MixerSettings) {
        activeSettings.mixer = mixer
        draft.mixer = mixer
        scheduleLiveSettingsSave()
    }

    /// The mixer's mic fader is the live face of `micVolume`: persist it and
    /// mirror it into the draft without the Apply dance (same freshness rule
    /// as `persistMixer`). The dispatcher applies the live, ramped engine
    /// gain — mixer mute state lives there, not in settings.
    func persistMicVolume(_ value: Double) {
        let clamped = max(0, min(value, 2))
        activeSettings.micVolume = clamped
        draft.micVolume = clamped
        scheduleLiveSettingsSave()
    }

    /// A05 (issue #84): persists the additional-input device list (enable /
    /// hardware-channel mapping / relink) straight into the APPLIED settings
    /// and applies it to the live pipeline — like the mixer, this is a live
    /// session surface, not a draft/Apply edit. Mirroring keeps
    /// `draft.audioInputs` fresh so a later settings Apply can't roll the
    /// input list back, and `isDirty` is unaffected. The controller's
    /// `applySavedSettings` diff starts/stops the affected devices' captures
    /// and mix channels in place.
    func persistAudioInputs(_ inputs: [AudioInputSelection]) {
        activeSettings.audioInputs = inputs
        draft.audioInputs = inputs
        controller.applySavedSettings(activeSettings)
        scheduleLiveSettingsSave()
    }

    /// Debounced settings write for live-surface edits (mixer fader scrubs,
    /// A05 input toggles): a scrub dispatches a command per tick, and the
    /// state updates above must stay synchronous (publishers fire, the
    /// engine ramps live), but the FILE write coalesces to one save per
    /// gesture instead of one per tick.
    private var mixerSaveTask: Task<Void, Never>?

    private func scheduleLiveSettingsSave() {
        mixerSaveTask?.cancel()
        mixerSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.save(self.activeSettings)
        }
    }
}
