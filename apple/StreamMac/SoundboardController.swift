import Combine
import CoreMedia
import Foundation
import os.lock

/// A03 (issue #98): the soundboard / music-playlist / scene-sound playback
/// runtime.
///
/// **Engine reuse.** Every pad, playlist, stinger, and ambient bed is a
/// `MediaSourcePlayback` (A02) instance: the same security-scoped bookmark
/// resolution, the same AVAssetReader audio path retimed onto the shared
/// host clock, and the same `.media(sourceID)` mix channels — so soundboard
/// audio and scene media audio are indistinguishable to the A01 engine (one
/// clock, no duplicate audio, hardware-triggerable through the W05 command
/// layer). Because none of these are scene LAYERS, no render tick pulls
/// them: a demand-driven pump (`syncPump`) pulls frames/audio at ~60 Hz only
/// while at least one engine is playing — the A02 pull/top-up pattern with
/// its own cadence, never an always-on timer.
///
/// **Channels.** One `.media(id)` channel per pad / per playlist / per scene
/// binding. Per-item volume is pushed through the controller's mixer gain
/// path (`applyMixerChannelGain`), whose pending gains survive the engine's
/// channel pruning, so a pad keeps its level across scene changes and engine
/// restarts. The monitor bus mirrors program by default, so pads are audible
/// on monitor without any bus work (A07 owns the monitor attach).
///
/// **Hot-swap.** A relink only replaces the bookmark in the store; the
/// payload boxes below feed each engine's live `payloadProvider`, so the
/// A02 relink path reloads the file in place on the next pull — the pad/
/// playlist/binding ID (and therefore its mix channel) never changes.
@MainActor
final class SoundboardController: ObservableObject {
    /// Per-pad transport status (loaded/playing/paused/error + message),
    /// mirrored from the pad's most recently triggered engine.
    @Published private(set) var padStatuses: [SourceDefinitionID: MediaSourceStatus] = [:]
    /// Pads with at least one engine currently playing (the grid's lit state).
    @Published private(set) var playingPadIDs: Set<SourceDefinitionID> = []
    /// Per-playlist playback state (current track, position, error).
    @Published private(set) var playlistStates: [SourceDefinitionID: PlaylistPlaybackState] = [:]
    /// The last load/trigger error per scene-sound binding (the scene-sounds
    /// list's honest missing-file state; relink clears it).
    @Published private(set) var sceneSoundErrors: [SourceDefinitionID: String] = [:]

    /// The transport UI's view of one playlist.
    struct PlaylistPlaybackState: Equatable, Sendable {
        var phase: MediaPlayoutPhase = .idle
        var trackIndex: Int = 0
        var positionSeconds: Double = 0
        var durationSeconds: Double = 0
        var errorMessage: String? = nil

        var isPlaying: Bool { phase == .playing }
    }

    /// Overlap-policy cap per pad (each instance is a decoder + player).
    private static let maxOverlapInstances = 8
    /// Above this position, "previous" restarts the track instead of
    /// skipping back (the standard transport behavior).
    private static let previousRestartThreshold: Double = 3

    private let store: SoundboardStore
    private let controller: StreamController
    /// The A02 media-audio ingest the controller wired on the pool: buffers
    /// ride it straight into the engine's `.media(id)` channels.
    private let audioIngest: (@Sendable (SourceDefinitionID, CMSampleBuffer) -> Void)?

    private struct PadEngine {
        let instanceID: UUID
        let engine: MediaSourcePlayback
        let box: SoundPayloadBox
        var phase: MediaPlayoutPhase
    }

    private struct PlaylistEngine {
        let instanceID: UUID
        let engine: MediaSourcePlayback
        let box: SoundPayloadBox
        var phase: MediaPlayoutPhase
    }

    private struct SceneSoundEngine {
        let instanceID: UUID
        let engine: MediaSourcePlayback
        let box: SoundPayloadBox
        var phase: MediaPlayoutPhase
        var sawPlaying: Bool
    }

    private var padEngines: [SourceDefinitionID: [PadEngine]] = [:]
    private var playlistEngines: [SourceDefinitionID: PlaylistEngine] = [:]
    private var playlistIndexes: [SourceDefinitionID: Int] = [:]
    private var ambientEngines: [SourceDefinitionID: SceneSoundEngine] = [:]
    private var stingerEngines: [UUID: SceneSoundEngine] = [:]
    /// The program scene the scene-sound rules last synced against.
    private var programScene: Scene?
    /// Every live engine, for the pump's per-tick pull.
    private let engineList = SoundEngineList()
    /// Engines whose phase is `.playing`, keyed by instance ID — the pump's
    /// demand signal (the pump exists only while this is non-empty).
    private var playingEngines: Set<UUID> = []
    private var pumpTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: SoundboardStore, controller: StreamController) {
        self.store = store
        self.controller = controller
        audioIngest = controller.capturePool.onMediaAudioSample
        // Store edits (relink, volume, track lists, removals) hot-apply to
        // the live engines: payload boxes feed each engine's relink path and
        // volume edits push through the mixer gain path. `Published` sinks
        // fire with the current value, so this also pushes the initial
        // per-item gains (the engine's pending gains then hold them across
        // channel pruning and engine restarts).
        store.$pads.sink { [weak self] pads in
            Task { @MainActor [weak self] in self?.refreshPads(pads) }
        }.store(in: &cancellables)
        store.$playlists.sink { [weak self] playlists in
            Task { @MainActor [weak self] in self?.refreshPlaylists(playlists) }
        }.store(in: &cancellables)
    }

    // MARK: - Soundboard transport

    /// Trigger a pad. `.restart` rewinds the one shared instance; `.overlap`
    /// reuses a finished instance or spins up another (capped), so rapid
    /// retriggers layer like a hardware soundboard.
    func triggerPad(_ pad: SoundPad) {
        switch pad.triggerPolicy {
        case .restart:
            var engines = padEngines[pad.id] ?? []
            for extra in engines.dropFirst() {
                retire(extra.engine, instanceID: extra.instanceID)
            }
            let primary = engines.first ?? makePadEngine(pad)
            engines = [primary]
            padEngines[pad.id] = engines
            primary.box.payload = payload(for: pad)
            primary.engine.load()
            primary.engine.restart()
        case .overlap:
            var engines = padEngines[pad.id] ?? []
            let entry: PadEngine
            if let reusable = engines.firstIndex(where: {
                $0.phase != .playing && $0.phase != .loading
            }) {
                entry = engines[reusable]
            } else {
                guard engines.count < Self.maxOverlapInstances else { return }
                entry = makePadEngine(pad)
                engines.append(entry)
                padEngines[pad.id] = engines
            }
            entry.box.payload = payload(for: pad)
            entry.engine.load()
            entry.engine.restart()
        }
    }

    /// Stop every instance of one pad (rewind to the start, parked).
    func stopPad(_ pad: SoundPad) {
        for entry in padEngines[pad.id] ?? [] {
            entry.engine.stop()
        }
    }

    /// The panic button: stop every pad and every in-flight stinger. Music
    /// playlists and scene ambient beds have their own explicit transport and
    /// are deliberately untouched.
    func stopAllSoundEffects() {
        for engines in padEngines.values {
            for entry in engines {
                entry.engine.stop()
            }
        }
        for (instanceID, entry) in stingerEngines {
            retire(entry.engine, instanceID: instanceID)
        }
        stingerEngines = [:]
    }

    // MARK: - Playlist transport

    func playPlaylist(_ playlist: MusicPlaylist) {
        guard !playlist.tracks.isEmpty else { return }
        if let existing = playlistEngines[playlist.id] {
            existing.box.payload = trackPayload(playlist: playlist,
                                                index: playlistIndexes[playlist.id] ?? 0)
            existing.engine.play()
            return
        }
        let index = min(playlistIndexes[playlist.id] ?? 0, playlist.tracks.count - 1)
        startPlaylist(playlist, trackIndex: index, autoplay: true)
    }

    func pausePlaylist(_ playlist: MusicPlaylist) {
        playlistEngines[playlist.id]?.engine.pause()
    }

    /// Stop: rewind to the start of the current track, parked (a later play
    /// resumes the SAME track — only next/previous move the cursor).
    func stopPlaylist(_ playlist: MusicPlaylist) {
        playlistEngines[playlist.id]?.engine.stop()
    }

    func nextTrack(_ playlist: MusicPlaylist) {
        advanceTrack(playlist, step: 1)
    }

    /// Previous: restart the track when it's past the threshold (the standard
    /// double-press behavior), otherwise skip to the previous one.
    func previousTrack(_ playlist: MusicPlaylist) {
        let position = playlistStates[playlist.id]?.positionSeconds ?? 0
        if position > Self.previousRestartThreshold, let existing = playlistEngines[playlist.id] {
            if playlistStates[playlist.id]?.isPlaying == true {
                existing.engine.restart()
            } else {
                existing.engine.seek(toSeconds: 0)
            }
            return
        }
        advanceTrack(playlist, step: -1)
    }

    /// Moves the track cursor by `step` (wrapping), rebuilding the engine on
    /// the new track. Play state carries across: next/previous mid-play keeps
    /// playing, parked stays parked.
    private func advanceTrack(_ playlist: MusicPlaylist, step: Int) {
        guard !playlist.tracks.isEmpty else { return }
        let current = playlistIndexes[playlist.id] ?? 0
        let count = playlist.tracks.count
        let next = (current + step + count) % count
        let wasPlaying = playlistStates[playlist.id]?.isPlaying == true
        let hadEngine = playlistEngines[playlist.id] != nil
        if hadEngine || wasPlaying {
            startPlaylist(playlist, trackIndex: next, autoplay: wasPlaying)
        } else {
            playlistIndexes[playlist.id] = next
            playlistStates[playlist.id] = PlaylistPlaybackState(trackIndex: next)
        }
    }

    /// One engine per playlist, (re)built on the given track: the channel
    /// `.media(playlist.id)` — the identity A10 ducking keys on — never
    /// changes across track boundaries.
    private func startPlaylist(_ playlist: MusicPlaylist, trackIndex: Int, autoplay: Bool) {
        guard playlist.tracks.indices.contains(trackIndex) else { return }
        if let old = playlistEngines[playlist.id] {
            retire(old.engine, instanceID: old.instanceID)
            playlistEngines[playlist.id] = nil
        }
        playlistIndexes[playlist.id] = trackIndex
        pushGain(.media(playlist.id), volume: playlist.volume)
        let box = SoundPayloadBox()
        box.payload = trackPayload(playlist: playlist, index: trackIndex)
        let instanceID = UUID()
        let engine = makeEngine(channelID: playlist.id, instanceID: instanceID, box: box)
        engine.onStatus = { [weak self] _, status in
            Task { @MainActor [weak self] in
                self?.notePlaylistStatus(status, playlistID: playlist.id, instanceID: instanceID)
            }
        }
        playlistEngines[playlist.id] = PlaylistEngine(instanceID: instanceID,
                                                      engine: engine, box: box,
                                                      phase: .loading)
        engine.load()
        if autoplay { engine.play() }
        playlistStates[playlist.id] = PlaylistPlaybackState(phase: .loading,
                                                            trackIndex: trackIndex)
    }

    private func notePlaylistStatus(_ status: MediaSourceStatus,
                                    playlistID: SourceDefinitionID, instanceID: UUID) {
        guard var entry = playlistEngines[playlistID], entry.instanceID == instanceID else { return }
        let wasEnded = entry.phase == .ended
        entry.phase = status.phase
        playlistEngines[playlistID] = entry
        syncPlaying(instanceID, phase: status.phase)
        playlistStates[playlistID] = PlaylistPlaybackState(
            phase: status.phase,
            trackIndex: playlistIndexes[playlistID] ?? 0,
            positionSeconds: status.positionSeconds,
            durationSeconds: status.durationSeconds,
            errorMessage: status.errorMessage)
        // A track that plays out advances the playlist (repeat .one loops
        // inside the engine and never gets here).
        guard status.phase == .ended, !wasEnded,
              let playlist = store.playlist(withID: playlistID) else { return }
        let count = playlist.tracks.count
        guard count > 0 else { return }
        let current = playlistIndexes[playlistID] ?? 0
        let next: Int?
        if playlist.isShuffled, count > 1 {
            var candidate = current
            while candidate == current {
                candidate = Int.random(in: 0..<count)
            }
            next = candidate
        } else if current + 1 < count {
            next = current + 1
        } else {
            next = playlist.repeatMode == .all ? 0 : nil
        }
        if let next {
            startPlaylist(playlist, trackIndex: next, autoplay: true)
        } else {
            // List played out with repeat off: park the cursor at the top.
            playlistIndexes[playlistID] = 0
        }
    }

    // MARK: - Scene sounds (enter/exit stingers, continue beds)

    /// The Take-path hook (W05 dispatcher): the program scene changed.
    /// Idempotent — re-syncing the same scene with the same bindings is a
    /// no-op, so the hook can ride every Take, direct-live implicit take,
    /// and pipeline start without double-firing. Entering a scene plays its
    /// `.enter` stingers and starts its `.continue` ambient beds; leaving
    /// plays its `.exit` stingers and stops the beds. A binding edit Taken
    /// to the SAME scene reconciles beds by value (edited bed restarts).
    func syncProgramScene(_ scene: Scene?) {
        let previous = programScene
        guard scene?.id != previous?.id || scene?.soundBindings != previous?.soundBindings
        else { return }
        let sceneChanged = scene?.id != previous?.id
        if sceneChanged, let previous {
            for binding in previous.soundBindings where binding.rule == .exit {
                playStinger(binding)
            }
        }
        let previousBeds = previous?.soundBindings.filter { $0.rule == .continue } ?? []
        let nextBeds = scene?.soundBindings.filter { $0.rule == .continue } ?? []
        for bed in previousBeds where !nextBeds.contains(bed) {
            stopAmbient(bed.id)
        }
        for bed in nextBeds where !previousBeds.contains(bed) {
            startAmbient(bed)
        }
        if sceneChanged, let scene {
            for binding in scene.soundBindings where binding.rule == .enter {
                playStinger(binding)
            }
        }
        programScene = scene
    }

    /// A one-shot scene sound (enter/exit stinger): plays through to the end
    /// even across a following scene change, then retires itself.
    private func playStinger(_ binding: SceneSoundBinding) {
        pushGain(.media(binding.id), volume: binding.volume)
        let box = SoundPayloadBox()
        box.payload = payload(for: binding, loops: false)
        let instanceID = UUID()
        let engine = makeEngine(channelID: binding.id, instanceID: instanceID, box: box)
        engine.onStatus = { [weak self] _, status in
            Task { @MainActor [weak self] in
                self?.noteStingerStatus(status, bindingID: binding.id, instanceID: instanceID)
            }
        }
        stingerEngines[instanceID] = SceneSoundEngine(instanceID: instanceID,
                                                      engine: engine, box: box,
                                                      phase: .loading, sawPlaying: false)
        engine.load()
        engine.restart()
    }

    private func noteStingerStatus(_ status: MediaSourceStatus,
                                   bindingID: SourceDefinitionID, instanceID: UUID) {
        guard var entry = stingerEngines[instanceID], entry.instanceID == instanceID else { return }
        entry.phase = status.phase
        entry.sawPlaying = entry.sawPlaying || status.phase == .playing
        stingerEngines[instanceID] = entry
        syncPlaying(instanceID, phase: status.phase)
        if status.phase == .error {
            sceneSoundErrors[bindingID] = status.errorMessage
        }
        // Terminal for a one-shot: played out (.ended) or rewound after
        // having played (.ready — the panic button's stop).
        if status.phase == .ended || (status.phase == .ready && entry.sawPlaying) {
            retire(entry.engine, instanceID: instanceID)
            stingerEngines[instanceID] = nil
        }
    }

    /// A scene's ambient bed: loops while the scene is on program.
    private func startAmbient(_ binding: SceneSoundBinding) {
        guard ambientEngines[binding.id] == nil else { return }
        pushGain(.media(binding.id), volume: binding.volume)
        let box = SoundPayloadBox()
        box.payload = payload(for: binding, loops: true)
        let instanceID = UUID()
        let engine = makeEngine(channelID: binding.id, instanceID: instanceID, box: box)
        engine.onStatus = { [weak self] _, status in
            Task { @MainActor [weak self] in
                self?.noteAmbientStatus(status, bindingID: binding.id, instanceID: instanceID)
            }
        }
        ambientEngines[binding.id] = SceneSoundEngine(instanceID: instanceID,
                                                      engine: engine, box: box,
                                                      phase: .loading, sawPlaying: false)
        engine.load()
        engine.restart()
    }

    private func noteAmbientStatus(_ status: MediaSourceStatus,
                                   bindingID: SourceDefinitionID, instanceID: UUID) {
        guard var entry = ambientEngines[bindingID], entry.instanceID == instanceID else { return }
        entry.phase = status.phase
        ambientEngines[bindingID] = entry
        syncPlaying(instanceID, phase: status.phase)
        if status.phase == .error {
            sceneSoundErrors[bindingID] = status.errorMessage
        }
    }

    private func stopAmbient(_ bindingID: SourceDefinitionID) {
        guard let entry = ambientEngines.removeValue(forKey: bindingID) else { return }
        retire(entry.engine, instanceID: entry.instanceID)
    }

    // MARK: - Store change application (relink / volume / removal)

    private func refreshPads(_ pads: [SoundPad]) {
        let liveIDs = Set(pads.map(\.id))
        for (padID, engines) in padEngines where !liveIDs.contains(padID) {
            for entry in engines {
                retire(entry.engine, instanceID: entry.instanceID)
            }
            padEngines[padID] = nil
            padStatuses[padID] = nil
        }
        for pad in pads {
            pushGain(.media(pad.id), volume: pad.volume)
            guard let engines = padEngines[pad.id] else { continue }
            for entry in engines {
                entry.box.payload = payload(for: pad)
            }
        }
        playingPadIDs = Set(padEngines.filter { _, engines in
            engines.contains { $0.phase == .playing }
        }.keys)
    }

    private func refreshPlaylists(_ playlists: [MusicPlaylist]) {
        let liveIDs = Set(playlists.map(\.id))
        for (playlistID, entry) in playlistEngines where !liveIDs.contains(playlistID) {
            retire(entry.engine, instanceID: entry.instanceID)
            playlistEngines[playlistID] = nil
            playlistIndexes[playlistID] = nil
            playlistStates[playlistID] = nil
        }
        for playlist in playlists {
            pushGain(.media(playlist.id), volume: playlist.volume)
            guard !playlist.tracks.isEmpty else { continue }
            let index = min(playlistIndexes[playlist.id] ?? 0, playlist.tracks.count - 1)
            playlistIndexes[playlist.id] = index
            // Relink hot-swap: the current track's payload (bookmark, loop
            // policy) flows into the live engine's payload provider.
            playlistEngines[playlist.id]?.box.payload = trackPayload(playlist: playlist,
                                                                     index: index)
        }
    }

    // MARK: - Engine plumbing

    private func makePadEngine(_ pad: SoundPad) -> PadEngine {
        let box = SoundPayloadBox()
        box.payload = payload(for: pad)
        let instanceID = UUID()
        let engine = makeEngine(channelID: pad.id, instanceID: instanceID, box: box)
        engine.onStatus = { [weak self] _, status in
            Task { @MainActor [weak self] in
                self?.notePadStatus(status, padID: pad.id, instanceID: instanceID)
            }
        }
        return PadEngine(instanceID: instanceID, engine: engine, box: box, phase: .idle)
    }

    private func notePadStatus(_ status: MediaSourceStatus,
                               padID: SourceDefinitionID, instanceID: UUID) {
        guard let index = padEngines[padID]?.firstIndex(where: { $0.instanceID == instanceID })
        else { return }
        padEngines[padID]?[index].phase = status.phase
        syncPlaying(instanceID, phase: status.phase)
        padStatuses[padID] = status
        if status.phase == .playing {
            playingPadIDs.insert(padID)
        } else if padEngines[padID]?.contains(where: { $0.phase == .playing }) != true {
            playingPadIDs.remove(padID)
        }
    }

    private func makeEngine(channelID: SourceDefinitionID, instanceID: UUID,
                            box: SoundPayloadBox) -> MediaSourcePlayback {
        let engine = MediaSourcePlayback(sourceID: channelID) { box.payload }
        let ingest = audioIngest
        engine.onAudioSample = { sample in
            ingest?(channelID, sample)
        }
        engineList.insert(instanceID, engine)
        return engine
    }

    /// Tracks the pump's demand: an engine entering/leaving `.playing`.
    private func syncPlaying(_ instanceID: UUID, phase: MediaPlayoutPhase) {
        if phase == .playing {
            playingEngines.insert(instanceID)
        } else {
            playingEngines.remove(instanceID)
        }
        syncPump()
    }

    private func retire(_ engine: MediaSourcePlayback, instanceID: UUID) {
        engine.pause()
        engineList.remove(instanceID)
        playingEngines.remove(instanceID)
        syncPump()
    }

    /// The pump pulls every live engine ~60 times a second — the render-tick
    /// cadence A02's audio top-up is paced for — but exists ONLY while at
    /// least one engine is playing (no always-on timers).
    private func syncPump() {
        if !playingEngines.isEmpty, pumpTask == nil {
            let list = engineList
            pumpTask = Task.detached {
                while !Task.isCancelled {
                    for engine in list.snapshot() {
                        _ = engine.pullFrame()
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
        } else if playingEngines.isEmpty, let pumpTask {
            pumpTask.cancel()
            self.pumpTask = nil
        }
    }

    private func pushGain(_ id: AudioChannelID, volume: Double) {
        controller.applyMixerChannelGain(id, volume: Float(max(0, min(volume, 2))),
                                         isMuted: false)
    }

    private func payload(for pad: SoundPad) -> MediaSourcePayload {
        MediaSourcePayload(bookmarkData: pad.bookmarkData,
                           fileName: pad.fileName,
                           loops: pad.loops,
                           autoplay: false,
                           endAction: .stop)
    }

    private func trackPayload(playlist: MusicPlaylist, index: Int) -> MediaSourcePayload {
        let track = playlist.tracks.indices.contains(index) ? playlist.tracks[index] : nil
        return MediaSourcePayload(bookmarkData: track?.bookmarkData,
                                  fileName: track?.fileName,
                                  loops: playlist.repeatMode == .one,
                                  autoplay: false,
                                  endAction: .hold)
    }

    private func payload(for binding: SceneSoundBinding, loops: Bool) -> MediaSourcePayload {
        MediaSourcePayload(bookmarkData: binding.bookmarkData,
                           fileName: binding.fileName,
                           loops: loops,
                           autoplay: false,
                           endAction: .hold)
    }
}

/// The lock-protected, off-main-readable payload cell behind every engine's
/// `payloadProvider` (the A02 relink seam): store edits land here, and the
/// playback engine reads the latest payload on its pull path from any thread.
private final class SoundPayloadBox: @unchecked Sendable {
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

/// The pump's lock-protected live-engine list (mutated on the main actor,
/// snapshotted from the detached pump task).
private final class SoundEngineList: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var entries: [(instanceID: UUID, engine: MediaSourcePlayback)] = []

    func insert(_ instanceID: UUID, _ engine: MediaSourcePlayback) {
        os_unfair_lock_lock(&lock)
        entries.append((instanceID, engine))
        os_unfair_lock_unlock(&lock)
    }

    func remove(_ instanceID: UUID) {
        os_unfair_lock_lock(&lock)
        entries.removeAll { $0.instanceID == instanceID }
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [MediaSourcePlayback] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return entries.map(\.engine)
    }
}
