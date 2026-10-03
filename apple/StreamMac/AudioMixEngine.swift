import AVFoundation
import CoreMedia
import StreamCore
import os.lock

/// The stable identity of one audio channel in the mix (issue #82: "stable
/// channel IDs"). Sources tap in and out with their S05 capture demand, but
/// the ID survives: scene snapshots (S08/S09), mixer UI (A04), and per-source
/// FX (A08) all address channels through these values, never by index.
enum AudioChannelID: Hashable, Sendable {
    /// A microphone/line input. `deviceUID` nil = the system-default input
    /// (today's single mic); A05 pins additional mics by device UID.
    case microphone(deviceUID: String?)
    /// Audio of a pooled capture source — screen-source audio today; NDI
    /// (C06) and DeckLink (C07) join as capture keys without re-architecting.
    case capture(CaptureSourceKey)
    /// A02: audio of a media/movie source, keyed by its registry source ID.
    case media(SourceDefinitionID)
    /// A06: per-application audio capture, keyed by bundle ID.
    case application(bundleID: String)
    /// A guest/remote contribution, keyed by its registered stable slot UUID.
    case guest(id: String)

    /// A short stable label for statistics keys and logs.
    var label: String {
        switch self {
        case .microphone(let uid): return "mic.\(uid ?? "default")"
        case .capture(let key): return "capture.\(key)"
        case .media(let id): return "media.\(id)"
        case .application(let bundleID): return "app.\(bundleID)"
        case .guest(let id): return "guest.\(id)"
        }
    }
}

/// A04 (issue #83): one metering snapshot for the mixer UI, polled at
/// ~15–30 Hz. Per-channel levels are PRE-FADER (post-insert) — a muted or
/// binding-ducked source still shows its live signal, so the strip answers
/// "is this source alive?". Per-bus levels are POST-FADER, POST-GAIN,
/// PRE-CLAMP — the master meter shows exactly the mixed signal, and its clip
/// latch means the safety clamp engaged.
struct AudioEngineLevels: Sendable {
    var channels: [AudioChannelID: AudioLevels] = [:]
    var buses: [AudioBus: AudioLevels] = [:]
    /// A10 (issue #122): channels the ducker is currently holding below
    /// unity (their duck target < 1) — the mixer/soundboard "ducked"
    /// indicator. Read-only: ducking never changes what the faders mean.
    var duckedChannels: Set<AudioChannelID> = []
}

/// A01 (issue #82): the timestamped multi-source audio engine. Mixes N
/// timestamped sources — mic(s), screen-source audio, and future media/app/
/// NDI/guest channels — onto the SAME monotonic host clock the video
/// `CompositionEngine` anchors on, and fans the mix out onto routing buses.
///
/// **Clock / A-V sync.** At `run()` the engine anchors on
/// `CMClockGetTime(CMClockGetHostTimeClock())` — exactly the video engine's
/// timebase. Every output chunk's PTS is `anchor + position / 48000`, and
/// every channel's samples land in its ring at the absolute position its
/// capture PTS maps to (`(pts - anchor) * 48000`). Audio and video therefore
/// derive their timestamps from the same host clock instead of from
/// independent buffer counts, so the two cannot drift apart.
///
/// **Graph.** Capture callbacks (any queue) call the nonisolated `enqueue`;
/// a per-channel `ChannelIngest` runs the insert chain (VoicePolish on the
/// mic — the A08 FX insertion point), normalizes format via StreamCore's
/// `CanonicalAudioConverter`, and writes into a bounded `AudioRingBuffer`.
/// A tick loop mixes fixed 512-frame chunks: each channel contributes its
/// samples at the chunk's absolute window (silence on underrun), gain ramps
/// apply per frame (click-free mute/Take), and the sums are clamped to
/// [-1, 1]. All of it runs off the main actor.
///
/// **Buses.** Program (publisher + recording), monitor (A07), and aux /
/// guest-return (mix-minus) are computed from the same channel state; each
/// bus tap is a bounded, drop-oldest mailbox drained on its own serial queue,
/// so a slow output sheds only its own chunks and can never stall the mix
/// (the W02/W08 independence rule). Isolated pre-fader taps per channel
/// support isolated recording tracks.
///
/// **Drop policy** (see `AudioRingBuffer` for the full contract): per-channel
/// rings hold 200 ms of real-time buffer PLUS the A10 delay headroom
/// (`maxDelayFrames` = 500 ms), so a channel delayed by the bounded maximum
/// never overruns its ring; overflow drops OLDEST frames (bounded latency),
/// underrun inserts counted silence, tap queues drop oldest chunks. Nothing
/// blocks.
actor AudioMixEngine {
    /// Engine-wide mix format: 48 kHz stereo (canonical, see StreamCore).
    static let sampleRate = 48_000
    /// Frames per mixed chunk (~10.7 ms). Chunks are emitted back-to-back at
    /// exactly this size, so the output timestamp stream is perfectly regular.
    static let chunkFrames = 512
    /// A10 (issue #122): the bounded per-channel audio delay headroom —
    /// `AVSyncDelay.maxAudioDelayMs` (500 ms) in sample frames. A channel's
    /// delay shifts its ring READ window this far behind the mix position.
    static let maxDelayFrames = AVSyncDelay.audioFrames(
        forMilliseconds: AVSyncDelay.maxAudioDelayMs, sampleRate: sampleRate)
    /// Per-channel ring capacity: 200 ms of real-time buffer plus the A10
    /// delay headroom — the bounded real-time buffer.
    static let ringCapacityFrames = 9_600 + maxDelayFrames
    /// Gain/mute changes ease over 20 ms (960 frames) — no clicks on Take.
    static let gainRampFrames = 960

    /// Called on the capture thread with a chunk of one bus, pre-clamped.
    typealias AudioSink = @Sendable (CMSampleBuffer) -> Void

    /// The off-actor channel registry the nonisolated `enqueue` writes through
    /// (mirrors the video side's `SourceFrameProviders` hand-off).
    private let registry = AudioChannelRegistry()
    private var anchor: CMTime = .invalid
    private var mixPosition: Int64 = 0
    private var tickTask: Task<Void, Never>?
    /// Opt-in capture leases only. Existing inputs retain the 5 ms scheduling margin.
    /// Public capture batches may arrive tens of milliseconds after their original host PTS.
    /// Holdback delays delivery, never media timestamps, and stays inside the existing bounded ring.
    private var captureHoldbacks: [UUID: Int64] = [:]
    struct CaptureTimingSnapshot: Codable, Sendable {
        var holdbackMilliseconds: Double
        var leaseCount: Int
    }
    @discardableResult func reserveCaptureHoldback(token: UUID, milliseconds: Double) -> Bool {
        guard milliseconds.isFinite, (5...100).contains(milliseconds) else { return false }
        guard captureHoldbacks[token] != nil || captureHoldbacks.count < 32 else { return false }
        captureHoldbacks[token] = Int64((milliseconds * Double(Self.sampleRate) / 1_000).rounded())
        return true
    }
    func releaseCaptureHoldback(_ token: UUID) { captureHoldbacks.removeValue(forKey: token) }
    func captureTimingSnapshot() -> CaptureTimingSnapshot {
        CaptureTimingSnapshot(holdbackMilliseconds: Double(captureHoldbackFrames) * 1_000 / Double(Self.sampleRate), leaseCount: captureHoldbacks.count)
    }
    private var captureHoldbackFrames: Int64 { max(240, captureHoldbacks.values.max() ?? 240) }
    private var busGains: [AudioBus: Float] = [.program: 1, .monitor: 1, .aux: 1]
    /// A04: per-bus meters (post-gain, pre-clamp), fed in `postBus`.
    private var busLevels: [AudioBus: LevelMeter] = [:]
    private var taps: [UUID: AudioTapMailbox] = [:]
    private var guestReturns: [UUID: GuestReturnMailbox] = [:]
    private var cancelledTokens: Set<UUID> = []
    /// Gain assignments that arrived before their channel existed; applied at
    /// channel creation (scene gains are pushed before a new capture's first
    /// audio buffer lands).
    private var pendingGains: [AudioChannelID: ChannelGain] = [:]
    /// A10 (issue #122): the live ducking configuration (nil = bypassed).
    private var ducking: DuckingConfiguration?
    /// A10: the ducker's attack/hold/release state machine — engine-actor
    /// state, so it survives Takes and scene changes untouched (ducking is
    /// session-level, never scene-bound).
    private var duckEnvelope = DuckEnvelope()
    /// A10: the duck target last pushed per channel (1 = not ducked) — the
    /// UI's ducked-channel snapshot and the bypass restore list.
    private var appliedDuckGains: [AudioChannelID: Float] = [:]

    // Reused mix scratch (actor-confined): no per-chunk allocations.
    private var programScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var monitorScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var auxScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var preISOScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var isoScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var contributionScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var formatDescription: CMAudioFormatDescription?

    // MARK: - Lifecycle (driven by the W02 pipeline-demand model)

    /// Anchors the host clock and starts the mix loop. Channels and taps are
    /// configured independently; a bus with no taps is not rendered.
    func run() {
        registry.reset()
        startTicking()
    }

    /// Stops mixing (pipeline demand back to 0). Taps stay registered — like
    /// the video engine's subscribers — and channels are cleared so the next
    /// run starts with fresh rings, converters, and insert (FX) state.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        registry.reset()
        captureHoldbacks.removeAll()
    }

    // MARK: - Explicit guest admission

    /// Registration is authority supplied by the runtime, never inferred from
    /// a PCM callback, channel label, fader, or isolated recording selection.
    /// One native guest slot is bounded and qualified; replacement closes all
    /// gates and discards the previous negotiation's samples.
    @discardableResult func registerGuest(_ lease: GuestReceiveLease, initialMixer: MixerSettings? = nil) -> Bool {
        let id = Self.guestChannelID(for: lease)
        let result = registry.registerGuest(lease, gain: pendingGains[id], initialMixer: initialMixer)
        if result.created, let initialMixer {
            pendingGains[id] = ChannelGain(volume: Float(max(0, min(2, initialMixer.channelVolumes[id.label] ?? 1))),
                                           isMuted: initialMixer.channelMutes[id.label] ?? false)
        }
        return result.accepted
    }

    static func guestChannelID(for lease: GuestReceiveLease) -> AudioChannelID {
        .guest(id: lease.slot.uuidString)
    }

    nonisolated func registeredGuestChannelID(slot: UUID) -> AudioChannelID? {
        registry.registeredGuestChannelID(slot: slot)
    }

    /// Return listening is separate from admitting the guest into Program or
    /// Monitor. Only this exact current full lease can receive a public mix.
    @discardableResult nonisolated func setGuestReturnAllowed(_ lease: GuestReceiveLease, allowed: Bool) -> Bool {
        registry.setGuestReturnAllowed(lease, allowed: allowed)
    }
    nonisolated func guestReturnFrameIsCurrent(_ frame: GuestReturnAudioFrame) -> Bool {
        registry.guestReturnRevision(frame.lease) == frame.routingRevision
    }
    @discardableResult func addGuestReturnTap(_ lease: GuestReceiveLease, token: UUID, capacity: Int = 8,
                sink: @escaping @Sendable (GuestReturnAudioFrame) -> Void) -> Bool {
        guard cancelledTokens.remove(token) == nil, taps[token] == nil,
              registry.guestLease(for: Self.guestChannelID(for: lease)) == lease,
              guestReturns[token] != nil || guestReturns.count < 4 else { return false }
        guestReturns[token]?.close()
        let registry = self.registry
        guestReturns[token] = GuestReturnMailbox(lease: lease, token: token, capacity: capacity,
            current: { registry.guestReturnRevision($0.lease) == $0.routingRevision }, sink: sink)
        return true
    }

    /// Admission and faders are independent. Backstage may be heard privately
    /// on monitor, but Program, aux, and BOTH isolated processing taps require
    /// the explicit Program gate. This does not create a recipient mix-minus.
    @discardableResult nonisolated func setGuestRouting(_ lease: GuestReceiveLease,
                                            programAllowed: Bool, monitorAllowed: Bool) -> Bool {
        registry.setGuestRouting(lease, programAllowed: programAllowed, monitorAllowed: monitorAllowed)
    }

    /// Revokes ingress synchronously, even when the mix actor is busy. Captured
    /// callbacks cannot repopulate a removed or replaced admission.
    @discardableResult nonisolated func removeGuest(_ lease: GuestReceiveLease) -> Bool {
        registry.removeGuest(lease)
    }

    /// Permanent runtime retirement, preceding receiver/coordinator teardown.
    /// Ordinary zero-demand stop only clears rings, retaining explicit leases.
    nonisolated func retireGuestAdmissions() { registry.retireGuestAdmissions() }

    /// The caller first checks the shared audio/video sender-clock mapping.
    /// This inlet additionally pins that generation, validates bounded decoded
    /// PCM, and writes at ORIGINAL host PTS. No first-arrival rebase is applied.
    @discardableResult nonisolated func enqueueGuest(_ frame: GuestAudioFrame) -> Bool {
        registry.enqueueGuest(frame)
    }

    /// Nonmutating validation before the shared video/audio mapping is pinned.
    /// Intake rechecks under the same lock, including after a concurrent revoke.
    nonisolated func validateGuestFrame(_ frame: GuestAudioFrame) -> Bool {
        registry.validateGuestFrame(frame)
    }

    struct GuestAdmissionSnapshot: Sendable {
        var lease: GuestReceiveLease?
        var mappingGeneration: UUID?
        var programAllowed: Bool
        var monitorAllowed: Bool
        var retired: Bool
        var acceptedPackets: UInt64
        var rejectedPackets: UInt64
        var lastPTS: CMTime
        var lastEndPTS: CMTime
    }
    nonisolated func guestAdmissionSnapshot() -> GuestAdmissionSnapshot {
        registry.guestAdmissionSnapshot()
    }

    // MARK: - Channels

    struct ChannelGain: Sendable {
        var volume: Float
        var isMuted: Bool

        var effectiveGain: Float { isMuted ? 0 : max(0, volume) }
    }

    /// Registers a channel with an optional insert chain — a synchronous
    /// sample-buffer transformer run on the capture thread BEFORE format
    /// normalization. The mic's `VoicePolishProcessor` lives here; A08/A11 FX
    /// racks insert through the same seam. Safe to call before `run`.
    func addChannel(_ id: AudioChannelID,
                    insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)? = nil) {
        registry.addChannel(id, insert: insert, gain: pendingGains[id])
    }

    /// Removes a channel (its capture left demand). Late buffers for the ID
    /// simply recreate it via `enqueue`'s auto-registration at the pending
    /// gain — never a leak, never a crash.
    func removeChannel(_ id: AudioChannelID) {
        registry.removeChannel(id)
    }

    /// Removes every channel not in `keeping` (the controller passes the mic
    /// plus the union of demanded capture keys, mirroring the S05 pool).
    /// Pending gains survive, so a re-created channel keeps its mix state.
    func pruneChannels(keeping ids: Set<AudioChannelID>) {
        registry.prune(keeping: ids.union(taps.values.compactMap(\.isolatedChannel)))
    }

    /// Ramped gain/mute change (S05 `AudioBinding` honored here). Recorded in
    /// `pendingGains` so a channel created later starts at the right level;
    /// the ramp (`gainRampFrames`) makes Take-time re-binding click-free.
    func setChannelGain(_ id: AudioChannelID, volume: Float, isMuted: Bool) {
        let gain = ChannelGain(volume: volume, isMuted: isMuted)
        pendingGains[id] = gain
        registry.setGain(id, effectiveGain: gain.effectiveGain,
                         rampFrames: Self.gainRampFrames)
    }

    /// The aux/guest-return send for a channel (0 = not heard on the aux bus;
    /// 1 = full). Ramped like the program gain.
    func setChannelAuxSend(_ id: AudioChannelID, gain: Float) {
        registry.setAuxSend(id, gain: max(0, gain), rampFrames: Self.gainRampFrames)
    }

    /// Applies the program scene's S05 `AudioBinding`s to capture channels:
    /// listed channels ramp to their binding gain, and every other capture
    /// channel ramps to silence (a staged-only source must never leak into
    /// the outgoing mix). Non-capture channels (mic, guests) are untouched —
    /// they are not scene-bound.
    func applyProgramCaptureGains(_ gains: [AudioChannelID: (volume: Float, isMuted: Bool)]) {
        // A binding may precede its first PCM, or survive a ring reset/prune.
        // Revoke those declarations too before a late callback registers them.
        let captureChannels = Set(registry.channelIDs()).union(pendingGains.keys).filter {
            if case .capture = $0 { return true }
            return false
        }
        for id in captureChannels where gains[id] == nil {
            setChannelGain(id, volume: 0, isMuted: false)
        }
        for (id, gain) in gains {
            setChannelGain(id, volume: gain.volume, isMuted: gain.isMuted)
        }
    }

    // MARK: - A10 A/V delay + speech ducking (issue #122)

    /// A10: the engine-side view of the persisted `DuckingSettings`, with
    /// decibel/millisecond values pre-converted to linear gains and whole
    /// mix chunks. Channels are matched by LABEL each chunk (not by ID at
    /// configure time), so duck targets that come and go — soundboard pads,
    /// playlists, scene media — join and leave the duck set with their
    /// channels, and the config survives channel pruning untouched.
    struct DuckingConfiguration: Sendable {
        var sidechainLabels: Set<String>
        var targetLabels: Set<String>
        var thresholdLinear: Float
        var duckGain: Float
        var attackChunks: Int
        var holdChunks: Int
        var releaseChunks: Int

        /// Nil when the settings mean "bypassed" (disabled, or no sidechain
        /// or target selected) — the envelope rests and every duck ramp
        /// eases back to unity.
        init?(_ settings: DuckingSettings, chunkDurationSeconds: Double) {
            guard settings.isEnabled,
                  !settings.sidechainLabels.isEmpty,
                  !settings.targetLabels.isEmpty else { return nil }
            sidechainLabels = settings.sidechainLabels
            targetLabels = settings.targetLabels
            thresholdLinear = settings.thresholdLinear
            duckGain = settings.duckGain
            attackChunks = AVSyncDelay.chunkCount(forMilliseconds: settings.attackMs,
                                                  chunkDurationSeconds: chunkDurationSeconds)
            holdChunks = AVSyncDelay.chunkCount(forMilliseconds: settings.holdMs,
                                                chunkDurationSeconds: chunkDurationSeconds)
            releaseChunks = AVSyncDelay.chunkCount(forMilliseconds: settings.releaseMs,
                                                   chunkDurationSeconds: chunkDurationSeconds)
        }
    }

    /// A10: per-channel audio delays in MILLISECONDS, keyed by channel label
    /// (the persisted settings map). Each channel's ring read shifts that far
    /// BEHIND the mix position — compensation for per-source capture latency
    /// on the same host clock, so program, monitor, aux, and isolated taps
    /// all carry the compensated timing identically and no timestamp ever
    /// regresses. Registry-level (like solo): the map survives engine
    /// restarts and applies to channels that auto-register later.
    func setChannelDelays(_ delaysMs: [String: Double]) {
        let frames = delaysMs.mapValues {
            AVSyncDelay.audioFrames(forMilliseconds: $0, sampleRate: Self.sampleRate)
        }
        registry.setDelays(frames)
    }

    /// A10: (re)configures speech-driven ducking. The envelope and per-
    /// channel duck ramps live alongside — never inside — the base gain
    /// ramps: the mix multiplies `base × duck`, so the A04 faders and the
    /// ducker never fight, and bypass (nil) ramps every ducked channel back
    /// to unity, restoring the user-set gain exactly.
    func setDucking(_ configuration: DuckingConfiguration?) {
        ducking = configuration
        duckEnvelope.reset()
        let releaseFrames = configuration.map { $0.releaseChunks * Self.chunkFrames }
            ?? Self.gainRampFrames
        for (id, gain) in appliedDuckGains where gain < 1 {
            registry.setDuckGain(id, gain: 1, rampFrames: releaseFrames)
        }
        appliedDuckGains.removeAll()
    }

    /// Capture-thread entry point: converts, inserts FX, and writes the
    /// buffer's frames into the channel's ring at the position its capture
    /// PTS maps to on the engine clock. Unknown channels auto-register
    /// (pending gain if set, else silence for capture channels / unity
    /// otherwise) so future source kinds need no engine changes. Synchronous
    /// and lock-confined per channel — never touches actor state.
    nonisolated func enqueue(_ id: AudioChannelID, _ sampleBuffer: CMSampleBuffer) {
        registry.enqueue(id, sampleBuffer)
    }

    // MARK: - Bus taps (bounded, drop-oldest fan-out)

    /// Registers a bus tap under a caller-chosen token (same race-safe
    /// register/cancel contract as the video engine's sinks: a cancel landing
    /// before its register is honored). `capacity` is in chunks (~10.7 ms
    /// each); delivery runs on the tap's own serial queue.
    func addTap(bus: AudioBus, token: UUID, capacity: Int = 8, sink: @escaping AudioSink) {
        if cancelledTokens.remove(token) != nil { return }
        taps[token] = AudioTapMailbox(description: "bus.\(bus.rawValue)",
                                      bus: bus, isolatedChannel: nil,
                                      capacity: capacity, token: token, sink: sink)
    }

    /// Registers an isolated (pre-fader, post-insert) tap on one channel —
    /// the isolated-recording surface. Tokens share the bus-tap namespace.
    func addIsolatedTap(channel: AudioChannelID, token: UUID, capacity: Int = 8,
                        processing: IsolatedAudioProcessing = .afterEffects, sink: @escaping AudioSink) {
        if cancelledTokens.remove(token) != nil { return }
        registry.ensureChannel(channel, gain: pendingGains[channel])
        let deliveryFilter: (@Sendable (CMSampleBuffer) -> CMSampleBuffer?)?
        if case .guest = channel {
            guard let lease = registry.guestLease(for: channel) else { return }
            let registry = self.registry
            deliveryFilter = { sample in
                guard let allowed = registry.isolatedGuestPermission(lease) else { return nil }
                return allowed ? sample : AudioTapMailbox.silence(like: sample)
            }
        } else { deliveryFilter = nil }
        if processing == .beforeEffects { registry.setPreEffectsEnabled(channel, enabled: true) }
        taps[token] = AudioTapMailbox(description: "iso.\(channel.label)",
                                      bus: nil, isolatedChannel: channel, processing: processing,
                                      capacity: capacity, token: token, deliveryFilter: deliveryFilter, sink: sink)
    }

    func removeTap(_ token: UUID) {
        if let removed = guestReturns.removeValue(forKey: token) { removed.close(); return }
        if let removed = taps.removeValue(forKey: token) {
            if let channel = removed.isolatedChannel, removed.processing == .beforeEffects,
               !taps.values.contains(where: { $0.isolatedChannel == channel && $0.processing == .beforeEffects }) {
                registry.setPreEffectsEnabled(channel, enabled: false)
            }
        } else { cancelledTokens.insert(token) }
    }

    /// Master gain for one bus (program/monitor/aux). Applied post-sum,
    /// pre-clamp. A07 rides on this for monitor level.
    func setBusGain(_ bus: AudioBus, gain: Float) {
        if bus == .program, gain <= 0 { registry.invalidateGuestReturnFrames() }
        busGains[bus] = max(0, gain)
    }

    /// A04 monitor-only solo (issue #83): while ANY channel is soloed, the
    /// MONITOR bus carries only the soloed channels' post-fader signal; the
    /// PROGRAM bus — what the stream and recording emit — is NEVER affected
    /// by solo (a solo mishap can't take a source out of the broadcast).
    /// The flag survives channel teardown/re-creation (registry-level), so a
    /// capture that stops and resumes keeps its solo state.
    func setChannelSolo(_ id: AudioChannelID, soloed: Bool) {
        registry.setSoloed(id, soloed: soloed)
    }

    /// A04: the latest meter snapshot for the mixer UI (poll at ~15–30 Hz;
    /// cheap — reads lock-confined per-channel meters and the actor's bus
    /// meters, no audio-thread work).
    func levelsSnapshot() -> AudioEngineLevels {
        var levels = AudioEngineLevels()
        levels.channels = registry.levelsSnapshot()
        levels.duckedChannels = Set(appliedDuckGains.filter { $0.value < 0.999 }.keys)
        for (bus, meter) in busLevels {
            levels.buses[bus] = meter.levels
        }
        return levels
    }

    /// Loss/underrun counters per channel plus per-tap shed counts.
    func statsSnapshot() -> AudioEngineStatistics {
        var stats = registry.statistics()
        for (token, tap) in taps {
            let drops = tap.dropCount()
            if drops > 0 {
                stats.tapDrops["\(tap.description).\(token.uuidString.prefix(8))"] = drops
            }
        }
        for (token, tap) in guestReturns {
            stats.tapDrops["guest-return.\(token.uuidString.prefix(8))"] = tap.dropCount()
        }
        return stats
    }

    // MARK: - Tick loop

    private func startTicking() {
        tickTask?.cancel()
        anchor = CMClockGetTime(CMClockGetHostTimeClock())
        registry.setAnchor(anchor)
        mixPosition = 0
        // Wake twice per chunk so output latency stays ~1.5 chunks even when
        // sleep overshoots; every due chunk is still emitted (gapless).
        let interval = UInt64(1_000_000_000) * UInt64(Self.chunkFrames)
            / UInt64(Self.sampleRate) / 2
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Emits every chunk whose sample window is safely in the past. The default 5 ms
    /// margin, or a bounded explicit capture lease, absorbs callback delivery jitter;
    /// later arrival is covered by the ring's counted-silence underrun policy.
    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let elapsedFrames = Int64(CMTimeGetSeconds(CMTimeSubtract(now, anchor))
                                    * Double(Self.sampleRate))
        let safety = captureHoldbackFrames
        while mixPosition + Int64(Self.chunkFrames) <= elapsedFrames - safety {
            mixChunk(at: mixPosition)
            mixPosition += Int64(Self.chunkFrames)
        }
    }

    /// Mixes one fixed-size chunk across all channels and posts it to every
    /// bus tap that has subscribers. Buses with no taps are not rendered.
    private func mixChunk(at position: Int64) {
        let frames = Self.chunkFrames
        for channel in Set(taps.values.compactMap(\.isolatedChannel)) {
            registry.ensureChannel(channel, gain: pendingGains[channel])
        }
        let channelIDs = registry.channelIDs()
        let wantProgram = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .program }
        let wantMonitor = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .monitor }
        let wantAux = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .aux }
        let wantAnyBus = wantProgram || wantMonitor || wantAux
        let returnWindows = guestReturns.values.compactMap { tap -> (GuestReturnMailbox, UInt64)? in
            guard let revision = registry.guestReturnRevision(tap.lease) else { return nil }
            tap.clearScratch()
            return (tap, revision)
        }

        // A10 (issue #122): advance the duck envelope ONCE per chunk from the
        // PRE-FADER sidechain meters (the mic reads as speech regardless of
        // its fader), and push the new duck target onto the target channels
        // only on envelope transitions — the channels' own ramps do the
        // click-free attack/release trajectories between pushes.
        if let ducking {
            let levels = registry.levelsSnapshot()
            var sidechain: Float = 0
            var targets: [AudioChannelID] = []
            for (id, channelLevels) in levels {
                if ducking.sidechainLabels.contains(id.label) {
                    sidechain = max(sidechain, channelLevels.rms)
                }
                if ducking.targetLabels.contains(id.label) {
                    targets.append(id)
                }
            }
            let decision = duckEnvelope.advance(
                speechActive: sidechain >= ducking.thresholdLinear,
                duckGain: ducking.duckGain,
                parameters: DuckEnvelope.Parameters(
                    attackChunks: ducking.attackChunks,
                    holdChunks: ducking.holdChunks,
                    releaseChunks: ducking.releaseChunks))
            if decision.changed {
                let rampFrames = decision.rampChunks * Self.chunkFrames
                for id in targets {
                    appliedDuckGains[id] = decision.targetGain
                    registry.setDuckGain(id, gain: decision.targetGain, rampFrames: rampFrames)
                }
            }
        }

        for index in programScratch.indices {
            programScratch[index] = 0
            monitorScratch[index] = 0
            auxScratch[index] = 0
        }

        // A04 monitor-only solo: while any channel is soloed, the monitor
        // bus is built from the soloed channels' post-fader contributions
        // instead of mirroring program.
        let soloActive = wantMonitor && registry.anySoloed()

        for id in channelIDs {
            let wantsISO = taps.values.contains { $0.isolatedChannel == id }
            guard wantAnyBus || wantsISO || !returnWindows.isEmpty else { continue }
            for index in isoScratch.indices {
                isoScratch[index] = 0; preISOScratch[index] = 0; contributionScratch[index] = 0
            }
            let gaps = registry.mixChannel(id, at: position, frameCount: frames,
                                program: &programScratch, aux: &auxScratch,
                                isolated: &isoScratch, preEffects: &preISOScratch, monitor: &monitorScratch,
                                contribution: &contributionScratch,
                                soloActive: soloActive)
            for (tap, _) in returnWindows where id != Self.guestChannelID(for: tap.lease) {
                tap.accumulate(contributionScratch)
            }
            if wantsISO {
                let pts = chunkPTS(at: position)
                for processing in IsolatedAudioProcessing.allCases {
                    let consumers = taps.values.filter { $0.isolatedChannel == id && $0.processing == processing }
                    guard !consumers.isEmpty else { continue }
                    let samples = processing == .beforeEffects ? preISOScratch : isoScratch
                    if let sample = makeSampleBuffer(samples, frames: frames, pts: pts) {
                        IsolatedAudioGap.attach(processing == .beforeEffects ? gaps.pre : gaps.post, to: sample)
                        for tap in consumers { tap.post(sample) }
                    }
                }
            }
        }

        postBus(.program, from: programScratch, at: position, wanted: wantProgram)
        postBus(.monitor, from: monitorScratch,
                at: position, wanted: wantMonitor)
        postBus(.aux, from: auxScratch, at: position, wanted: wantAux)
        for (tap, revision) in returnWindows {
            var samples = tap.scratch
            AudioMixerCore.applyBusGainAndClamp(&samples, gain: busGains[.program] ?? 1)
            if let sample = makeSampleBuffer(samples, frames: frames, pts: chunkPTS(at: position)) {
                tap.post(.init(lease: tap.lease, routingRevision: revision, sample: sample))
            }
        }
    }

    private func postBus(_ bus: AudioBus, from samples: [Float],
                         at position: Int64, wanted: Bool) {
        guard wanted else { return }
        var mixed = samples
        let gain = busGains[bus] ?? 1
        // A04: meter the post-gain, PRE-clamp signal — a latched clip here
        // means the safety clamp below actually engaged.
        busLevels[bus, default: LevelMeter()].ingest(interleaved: mixed, gain: gain)
        AudioMixerCore.applyBusGainAndClamp(&mixed, gain: gain)
        let pts = chunkPTS(at: position)
        guard let sample = makeSampleBuffer(mixed, frames: Self.chunkFrames, pts: pts)
        else { return }
        for tap in taps.values where tap.isolatedChannel == nil && tap.bus == bus {
            tap.post(sample)
        }
    }

    private func chunkPTS(at position: Int64) -> CMTime {
        CMTimeAdd(anchor, CMTime(value: position, timescale: CMTimeScale(Self.sampleRate)))
    }

    /// Packs one interleaved stereo chunk into a `CMSampleBuffer` on the
    /// canonical format, stamped on the engine clock (duration = chunk size,
    /// so the publisher's timeline normalizer never has to guess).
    private func makeSampleBuffer(_ samples: [Float], frames: Int,
                                  pts: CMTime) -> CMSampleBuffer? {
        if formatDescription == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(Self.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * 2,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 8 * UInt32(MemoryLayout<Float>.size),
                mReserved: 0
            )
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                                 layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil,
                                                 extensions: nil,
                                                 formatDescriptionOut: &description) == noErr
            else { return nil }
            formatDescription = description
        }
        guard let formatDescription else { return nil }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let created = samples.withUnsafeBufferPointer { pointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: 0,
                blockBufferOut: &blockBuffer)
        }
        guard created == noErr, let blockBuffer,
              CMBlockBufferReplaceDataBytes(
                with: samples, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { return nil }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }
}

/// The lock-protected channel table the nonisolated `enqueue` writes through.
/// Actor state (taps, buses) never crosses into it; channel state (rings,
/// converters, ramps) never crosses into the actor except through the
/// lock-confined `mixChannel` call from the mix loop.
private final class AudioChannelRegistry: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var channels: [AudioChannelID: ChannelIngest] = [:]
    private var anchor: CMTime = .invalid
    /// Capture callbacks can arrive before explicit channel registration.
    /// Retain declared local gains through ring resets so first-buffer
    /// registration honors the controller's current routing and mute state.
    /// Guest gains remain owned by the full receive-lease admission below.
    private var localGains: [AudioChannelID: Float] = [:]
    /// A04: soloed channel IDs. Registry-level (not per-channel-instance) so
    /// solo survives channel teardown/re-creation — `reset`, pruning, and
    /// auto-registration all re-apply it to the next ingest instance.
    private var soloedIDs: Set<AudioChannelID> = []
    /// A10 (issue #122): per-channel audio delay in sample frames, keyed by
    /// channel LABEL. Registry-level (same rule as solo): the map survives
    /// `reset` and pruning, and applies both to explicit registrations and to
    /// channels that auto-register on their first buffer.
    private var delayFramesByLabel: [String: Int] = [:]
    private var preEffectsIDs: Set<AudioChannelID> = []

    private struct GuestAdmission {
        let lease: GuestReceiveLease
        var mapping: UUID?
        var programAllowed = false
        var monitorAllowed = false
        var returnAllowed = false
        var returnRevision: UInt64 = 1
        var gain: Float
        var auxSend: Float
        var lastPTS = CMTime.invalid
        var lastEndPTS = CMTime.invalid
        var channelID: AudioChannelID { AudioMixEngine.guestChannelID(for: lease) }
    }
    private var guest: GuestAdmission?
    private var guestRetired = false
    private var highestGuestGeneration: UInt64 = 0
    private var guestAcceptedPackets: UInt64 = 0
    private var guestRejectedPackets: UInt64 = 0

    func registerGuest(_ lease: GuestReceiveLease, gain: AudioMixEngine.ChannelGain?, initialMixer: MixerSettings?) -> (accepted: Bool, created: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !guestRetired, lease.generation > 0 else { return (false, false) }
        if let current = guest {
            guard current.lease.slot == lease.slot else { return (false, false) }
            if current.lease == lease { return (true, false) }
        }
        // Runtime generations are monotonically increasing, including after
        // removal. A delayed explicit registration cannot resurrect an old lease.
        guard lease.generation > highestGuestGeneration else { return (false, false) }
        if let current = guest { channels[current.channelID] = nil }
        highestGuestGeneration = lease.generation
        let id = AudioMixEngine.guestChannelID(for: lease)
        let channelGain: Float
        let auxSend: Float
        if let initialMixer {
            let volume = Float(max(0, min(2, initialMixer.channelVolumes[id.label] ?? 1)))
            channelGain = initialMixer.channelMutes[id.label] == true ? 0 : volume
            auxSend = Float(max(0, min(1, initialMixer.channelAuxSends[id.label] ?? 0)))
            if initialMixer.soloedChannels.contains(id.label) { soloedIDs.insert(id) }
            else { soloedIDs.remove(id) }
        } else { channelGain = gain?.effectiveGain ?? 1; auxSend = 0 }
        let admission = GuestAdmission(lease: lease, gain: channelGain, auxSend: auxSend)
        guest = admission
        channels[admission.channelID] = makeGuestChannel(admission)
        return (true, true)
    }

    private func makeGuestChannel(_ guest: GuestAdmission) -> ChannelIngest {
        ChannelIngest(insert: nil, initialGain: guest.gain, initialAuxSend: guest.auxSend,
                      soloed: soloedIDs.contains(guest.channelID),
                      delayFrames: delayFramesByLabel[guest.channelID.label] ?? 0,
                      preEffectsEnabled: preEffectsIDs.contains(guest.channelID))
    }

    func setGuestReturnAllowed(_ lease: GuestReceiveLease, allowed: Bool) -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard guest?.lease == lease, !guestRetired,
              guest!.returnRevision < UInt64.max else { return false }
        if guest!.returnAllowed != allowed {
            guest!.returnRevision += 1; guest!.returnAllowed = allowed
        }
        return true
    }
    func guestReturnRevision(_ lease: GuestReceiveLease) -> UInt64? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard guest?.lease == lease, !guestRetired, guest!.returnAllowed else { return nil }
        return guest!.returnRevision
    }
    func invalidateGuestReturnFrames() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if guest != nil {
            if guest!.returnRevision < UInt64.max { guest!.returnRevision += 1 }
            else { guest!.returnAllowed = false }
        }
    }

    func registeredGuestChannelID(slot: UUID) -> AudioChannelID? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let guest, guest.lease.slot == slot else { return nil }
        return guest.channelID
    }

    func guestLease(for id: AudioChannelID) -> GuestReceiveLease? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return guest?.channelID == id ? guest?.lease : nil
    }

    func isolatedGuestPermission(_ lease: GuestReceiveLease) -> Bool? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let guest, guest.lease == lease else { return nil }
        return guest.programAllowed
    }

    func setGuestRouting(_ lease: GuestReceiveLease, programAllowed: Bool, monitorAllowed: Bool) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard guest?.lease == lease else { return false }
        guest?.programAllowed = programAllowed
        guest?.monitorAllowed = monitorAllowed
        return true
    }

    func removeGuest(_ lease: GuestReceiveLease) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let current = guest, current.lease == lease else { return false }
        channels[current.channelID] = nil
        guest = nil
        return true
    }

    func retireGuestAdmissions() {
        os_unfair_lock_lock(&lock)
        if let guest { channels[guest.channelID] = nil }
        guest = nil
        guestRetired = true
        os_unfair_lock_unlock(&lock)
    }

    func guestAdmissionSnapshot() -> AudioMixEngine.GuestAdmissionSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return AudioMixEngine.GuestAdmissionSnapshot(lease: guest?.lease, mappingGeneration: guest?.mapping,
            programAllowed: guest?.programAllowed ?? false, monitorAllowed: guest?.monitorAllowed ?? false,
            retired: guestRetired, acceptedPackets: guestAcceptedPackets, rejectedPackets: guestRejectedPackets,
            lastPTS: guest?.lastPTS ?? .invalid, lastEndPTS: guest?.lastEndPTS ?? .invalid)
    }

    func validateGuestFrame(_ frame: GuestAudioFrame) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return validatedGuestSamples(frame) != nil
    }

    /// Caller holds the registry lock. This validates without pinning mapping,
    /// moving a frontier, registering, or otherwise mutating admission state.
    private func validatedGuestSamples(_ frame: GuestAudioFrame) -> [Float]? {
        guard let current = guest, current.lease == frame.lease,
              frame.pts.isNumeric, frame.pts.seconds.isFinite,
              frame.duration.isNumeric, frame.duration.seconds.isFinite,
              anchor.isNumeric,
              abs((frame.pts - CMClockGetTime(CMClockGetHostTimeClock())).seconds) <= 0.5,
              current.mapping == nil || current.mapping == frame.mappingGeneration,
              !current.lastPTS.isNumeric || frame.pts > current.lastPTS,
              !current.lastEndPTS.isNumeric || (frame.pts - current.lastEndPTS).seconds >= -0.5 / 48_000,
              frame.pcm.format.commonFormat == .pcmFormatFloat32,
              frame.pcm.format.sampleRate == 48_000, frame.pcm.format.channelCount == 2,
              frame.pcm.frameLength > 0, frame.pcm.frameLength <= 5_760,
              abs(frame.duration.seconds - Double(frame.pcm.frameLength) / 48_000) <= 1 / 48_000,
              let samples = Self.guestSamples(frame.pcm), samples.allSatisfy({ $0.isFinite })
        else { return nil }
        return samples
    }

    func enqueueGuest(_ frame: GuestAudioFrame) -> Bool {
        // Decode buffers are owned by the receiver; copy only one bounded
        // packet while the registry pins its exact lease against replacement.
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard var current = guest, let samples = validatedGuestSamples(frame)
        else { guestRejectedPackets &+= 1; return false }
        current.mapping = frame.mappingGeneration
        current.lastPTS = frame.pts
        current.lastEndPTS = frame.pts + CMTime(value: Int64(frame.pcm.frameLength), timescale: 48_000)
        let channel = channels[current.channelID] ?? makeGuestChannel(current)
        channels[current.channelID] = channel
        // Keep registry -> channel lock order through the original-PTS write.
        channel.enqueueGuest(samples, pts: frame.pts, anchor: anchor)
        guest = current
        guestAcceptedPackets &+= 1
        return true
    }

    private static func guestSamples(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        if pcm.format.isInterleaved { return CanonicalAudioConverter.interleavedFloats(pcm) }
        guard let planes = pcm.floatChannelData else { return nil }
        var samples = [Float](repeating: 0, count: Int(pcm.frameLength) * 2)
        for frame in 0..<Int(pcm.frameLength) {
            samples[frame * 2] = planes[0][frame]
            samples[frame * 2 + 1] = planes[1][frame]
        }
        return samples
    }

    private func isGuest(_ id: AudioChannelID) -> Bool {
        if case .guest = id { return true }
        return false
    }

    func setAnchor(_ anchor: CMTime) {
        os_unfair_lock_lock(&lock)
        self.anchor = anchor
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        channels.removeAll()
        if var current = guest {
            if current.returnRevision < UInt64.max { current.returnRevision += 1 }
            else { current.returnAllowed = false }
            current.lastPTS = .invalid
            current.lastEndPTS = .invalid
            guest = current
            channels[current.channelID] = makeGuestChannel(current)
        }
        os_unfair_lock_unlock(&lock)
    }

    func addChannel(_ id: AudioChannelID,
                    insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?,
                    gain: AudioMixEngine.ChannelGain?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !isGuest(id) else { return }
        // Replace, not just insert-if-absent: an early buffer may have
        // auto-registered the channel (insert-less) just before this call,
        // and the explicit registration (VoicePolish on the mic) must win.
        channels[id] = ChannelIngest(insert: insert,
                                     initialGain: gain?.effectiveGain ?? localGains[id] ?? Self.defaultGain(for: id),
                                     soloed: soloedIDs.contains(id),
                                     delayFrames: delayFramesByLabel[id.label] ?? 0,
                                     preEffectsEnabled: preEffectsIDs.contains(id))
    }

    func ensureChannel(_ id: AudioChannelID, gain: AudioMixEngine.ChannelGain?) {
        os_unfair_lock_lock(&lock)
        if !isGuest(id), channels[id] == nil {
            channels[id] = ChannelIngest(insert: nil, initialGain: gain?.effectiveGain ?? localGains[id] ?? Self.defaultGain(for: id),
                soloed: soloedIDs.contains(id), delayFrames: delayFramesByLabel[id.label] ?? 0,
                preEffectsEnabled: preEffectsIDs.contains(id))
        }
        os_unfair_lock_unlock(&lock)
    }

    func setPreEffectsEnabled(_ id: AudioChannelID, enabled: Bool) {
        os_unfair_lock_lock(&lock)
        if enabled { preEffectsIDs.insert(id) } else { preEffectsIDs.remove(id) }
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setPreEffectsEnabled(enabled)
    }

    /// A04: toggles one channel's monitor-only solo. The ID set is the source
    /// of truth (applied to future ingest instances); the live channel gets
    /// the flag immediately.
    func setSoloed(_ id: AudioChannelID, soloed: Bool) {
        os_unfair_lock_lock(&lock)
        if soloed { soloedIDs.insert(id) } else { soloedIDs.remove(id) }
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setSoloed(soloed)
    }

    /// A04: true while any channel is soloed (the monitor bus switches from
    /// mirroring program to the soloed-only mix).
    func anySoloed() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return soloedIDs.contains { id in
            // Persisted local solo retains silence even while its source is
            // absent. An unregistered/backstage guest cannot silence monitor.
            return !isGuest(id) || (guest?.channelID == id && guest?.monitorAllowed == true)
        }
    }

    /// A04: the per-channel PRE-FADER meter readings for the mixer UI.
    func levelsSnapshot() -> [AudioChannelID: AudioLevels] {
        os_unfair_lock_lock(&lock)
        let entries = channels.map { ($0.key, $0.value.levels) }
        os_unfair_lock_unlock(&lock)
        return Dictionary(uniqueKeysWithValues: entries)
    }

    func removeChannel(_ id: AudioChannelID) {
        os_unfair_lock_lock(&lock)
        channels[id] = nil
        if guest?.channelID == id { guest = nil }
        os_unfair_lock_unlock(&lock)
    }

    func prune(keeping ids: Set<AudioChannelID>) {
        os_unfair_lock_lock(&lock)
        channels = channels.filter { ids.contains($0.key) || guest?.channelID == $0.key }
        os_unfair_lock_unlock(&lock)
    }

    func setGain(_ id: AudioChannelID, effectiveGain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        if !isGuest(id) { localGains[id] = effectiveGain }
        if guest?.channelID == id { guest?.gain = effectiveGain }
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setGain(effectiveGain, rampFrames: rampFrames)
    }

    func setAuxSend(_ id: AudioChannelID, gain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        if guest?.channelID == id { guest?.auxSend = gain }
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setAuxSend(gain, rampFrames: rampFrames)
    }

    /// A10: replaces the per-channel delay map (frames, by label) and applies
    /// it to the live channels. Delay changes take effect on the next mixed
    /// chunk — a read-window shift, never a ring reset, so no click and no
    /// dropped history.
    func setDelays(_ framesByLabel: [String: Int]) {
        os_unfair_lock_lock(&lock)
        delayFramesByLabel = framesByLabel
        let entries = channels.map { ($0.key, $0.value) }
        os_unfair_lock_unlock(&lock)
        for (id, channel) in entries {
            channel.setDelayFrames(framesByLabel[id.label] ?? 0)
        }
    }

    /// A10: the ducker's ramped duck-gain target for one channel. Duck rides
    /// its own ramp and multiplies the base gain in the mix (`base × duck`),
    /// so it never disturbs the A04 fader/binding ramps.
    func setDuckGain(_ id: AudioChannelID, gain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setDuckGain(gain, rampFrames: rampFrames)
    }

    func enqueue(_ id: AudioChannelID, _ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        guard !isGuest(id) else { os_unfair_lock_unlock(&lock); return }
        let anchor = self.anchor
        let channel = channels[id] ?? {
            let created = ChannelIngest(insert: nil,
                                        initialGain: localGains[id] ?? Self.defaultGain(for: id),
                                        soloed: soloedIDs.contains(id),
                                        delayFrames: delayFramesByLabel[id.label] ?? 0,
                                     preEffectsEnabled: preEffectsIDs.contains(id))
            channels[id] = created
            return created
        }()
        os_unfair_lock_unlock(&lock)
        channel.enqueue(sampleBuffer, anchor: anchor)
    }

    func channelIDs() -> [AudioChannelID] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(channels.keys)
    }

    func mixChannel(_ id: AudioChannelID, at position: Int64, frameCount: Int,
                    program: inout [Float], aux: inout [Float],
                    isolated: inout [Float], preEffects: inout [Float], monitor: inout [Float],
                    contribution: inout [Float],
                    soloActive: Bool) -> (pre: Int, post: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let isRegisteredGuest = isGuest(id)
        let programAllowed = !isRegisteredGuest || (guest?.channelID == id && guest?.programAllowed == true)
        let monitorAllowed = !isRegisteredGuest || (guest?.channelID == id && guest?.monitorAllowed == true)
        return channels[id]?.mix(at: position, frameCount: frameCount,
                     program: &program, aux: &aux, isolated: &isolated, preEffects: &preEffects,
                     monitor: &monitor, programAllowed: programAllowed,
                     contribution: &contribution,
                     monitorAllowed: monitorAllowed, soloActive: soloActive) ?? (pre: frameCount, post: frameCount)
    }

    func statistics() -> AudioEngineStatistics {
        os_unfair_lock_lock(&lock)
        let entries = channels.map { ($0.key.label, $0.value.statistics()) }
        os_unfair_lock_unlock(&lock)
        var stats = AudioEngineStatistics()
        stats.channels = Dictionary(uniqueKeysWithValues: entries)
        return stats
    }

    /// Auto-registered channels stay SILENT until the controller routes them
    /// (a staged-only source's audio must never leak into the program mix);
    /// microphones and future explicit sources start at unity.
    private static func defaultGain(for id: AudioChannelID) -> Float {
        switch id {
        case .capture, .media, .application, .guest: return 0
        case .microphone: return 1
        }
    }
}

/// One channel's lock-confined ingest state: insert chain → format
/// normalization → bounded ring → ramped gain. Every entry point takes the
/// channel lock, so the capture thread, the mix loop, and gain changes never
/// race.
private final class ChannelIngest: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private let insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?
    private var converter = CanonicalAudioConverter()
    private var preConverter: CanonicalAudioConverter?
    private var preRing: AudioRingBuffer?
    private var ring = AudioRingBuffer(capacityFrames: AudioMixEngine.ringCapacityFrames)
    private var gain: ChannelGainRamp
    private var auxSend = ChannelGainRamp(gain: 0)
    private var chunk = [Float](repeating: 0, count: AudioMixEngine.chunkFrames * 2)
    /// A04: monitor-only solo flag (registry-owned; re-applied on re-create).
    private var soloed: Bool
    /// A04: the channel's PRE-FADER (post-insert) meter, fed from the chunk
    /// the mix loop already reads — no extra pass over the ring.
    private var meter = LevelMeter()
    /// A10 (issue #122): the channel's audio delay — the ring read lags the
    /// mix position by this many frames, on the same host clock.
    private var delayFrames: Int
    /// A10: the ducker's gain ramp (1 = not ducked). Multiplies the base gain
    /// in the mix — `effective = base × duck` — so the faders and the ducker
    /// never fight and bypass restores the user-set gain exactly.
    private var duck = ChannelGainRamp(gain: 1)
    /// A10: scratch for the duck-scaled chunk (only touched while a duck
    /// ramp is active).
    private var duckedChunk = [Float](repeating: 0, count: AudioMixEngine.chunkFrames * 2)

    init(insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?, initialGain: Float, initialAuxSend: Float = 0,
         soloed: Bool = false, delayFrames: Int = 0, preEffectsEnabled: Bool = false) {
        self.insert = insert
        self.gain = ChannelGainRamp(gain: initialGain)
        self.auxSend = ChannelGainRamp(gain: initialAuxSend)
        self.soloed = soloed
        self.delayFrames = max(0, delayFrames)
        if preEffectsEnabled {
            preConverter = CanonicalAudioConverter()
            preRing = AudioRingBuffer(capacityFrames: AudioMixEngine.ringCapacityFrames)
        }
    }

    func setPreEffectsEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if enabled, preRing == nil {
            preConverter = CanonicalAudioConverter()
            preRing = AudioRingBuffer(capacityFrames: AudioMixEngine.ringCapacityFrames)
        } else if !enabled { preConverter = nil; preRing = nil }
    }

    func setGain(_ effectiveGain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        gain.setTarget(effectiveGain, rampFrames: rampFrames)
        os_unfair_lock_unlock(&lock)
    }

    func setAuxSend(_ send: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        auxSend.setTarget(send, rampFrames: rampFrames)
        os_unfair_lock_unlock(&lock)
    }

    /// A10: re-targets the duck ramp (engine-side gain automation).
    func setDuckGain(_ gain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        duck.setTarget(gain, rampFrames: rampFrames)
        os_unfair_lock_unlock(&lock)
    }

    /// A10: re-positions the ring read window (ms → frames conversion and
    /// clamping happened upstream in `AVSyncDelay`).
    func setDelayFrames(_ frames: Int) {
        os_unfair_lock_lock(&lock)
        delayFrames = max(0, frames)
        os_unfair_lock_unlock(&lock)
    }

    /// A04: monitor-only solo flag (see `AudioMixEngine.setChannelSolo`).
    func setSoloed(_ soloed: Bool) {
        os_unfair_lock_lock(&lock)
        self.soloed = soloed
        os_unfair_lock_unlock(&lock)
    }

    /// Capture-thread ingest: insert (VoicePolish/FX) → canonical conversion →
    /// ring write at the capture PTS's absolute engine position. Buffers with
    /// no usable PTS append contiguously; unreadable/non-LPCM buffers drop.
    func enqueue(_ sampleBuffer: CMSampleBuffer, anchor: CMTime) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let preConverter, let pcm = preConverter.convert(sampleBuffer),
           let raw = CanonicalAudioConverter.interleavedFloats(pcm), !raw.isEmpty {
            let pts = sampleBuffer.presentationTimeStamp
            let position = anchor.isNumeric && pts.isNumeric
                ? Int64(((pts - anchor).seconds * Double(AudioMixEngine.sampleRate)).rounded())
                : preRing?.nextWritePosition ?? 0
            preRing?.write(raw, at: position)
        }
        let processed = insert?(sampleBuffer) ?? sampleBuffer
        guard let pcm = converter.convert(processed),
              let samples = CanonicalAudioConverter.interleavedFloats(pcm),
              !samples.isEmpty else { return }
        let pts = processed.presentationTimeStamp
        let position: Int64
        if anchor.isValid, anchor.isNumeric, pts.isValid, pts.isNumeric {
            let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, anchor))
            position = Int64((seconds * Double(AudioMixEngine.sampleRate)).rounded())
        } else {
            position = ring.nextWritePosition
        }
        ring.write(samples, at: position)
    }

    func enqueueGuest(_ samples: [Float], pts: CMTime, anchor: CMTime) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let position = Int64(((pts - anchor).seconds * Double(AudioMixEngine.sampleRate)).rounded())
        ring.write(samples, at: position)
        preRing?.write(samples, at: position)
    }

    /// Mix-loop read: fills the channel scratch at the absolute window
    /// (shifted back by the A10 delay), exposes the pre-fader chunk as
    /// `isolated`, and accumulates program/aux with per-frame ramped gains
    /// (the click-free Take/mute contract). A04: feeds the channel meter
    /// from the pre-fader chunk, and — while a solo is active and this
    /// channel is soloed — additionally accumulates its post-fader signal
    /// into `monitor` (the monitor-only solo mix). A10: while a duck ramp
    /// is active the accumulated chunk is scaled by the duck trajectory
    /// FIRST — post-meter, post-isolated, so meters still show the live
    /// signal and isolated recording tracks stay clean of the duck.
    func mix(at position: Int64, frameCount: Int,
             program: inout [Float], aux: inout [Float],
             isolated: inout [Float], preEffects: inout [Float], monitor: inout [Float],
             programAllowed: Bool, contribution: inout [Float], monitorAllowed: Bool, soloActive: Bool) -> (pre: Int, post: Int) {
        os_unfair_lock_lock(&lock)
        let postBefore = ring.underrunFrames
        let preBefore = preRing?.underrunFrames ?? 0
        preRing?.fill(at: position - Int64(delayFrames), frameCount: frameCount, into: &preEffects)
        let preGaps = preRing.map { Int($0.underrunFrames - preBefore) } ?? frameCount
        ring.fill(at: position - Int64(delayFrames), frameCount: frameCount, into: &chunk)
        let postGaps = Int(ring.underrunFrames - postBefore)
        meter.ingest(interleaved: chunk)
        for index in 0..<(frameCount * 2) { isolated[index] = chunk[index] }
        let source: [Float]
        if duck.current < 1 || duck.target < 1 {
            for frame in 0..<frameCount {
                let duckGain = duck.advance()
                duckedChunk[frame * 2] = chunk[frame * 2] * duckGain
                duckedChunk[frame * 2 + 1] = chunk[frame * 2 + 1] * duckGain
            }
            source = duckedChunk
        } else {
            source = chunk
        }
        // Advance one shared fader/send trajectory, even when a hard routing
        // gate is closed. A mute ramp cannot authorize a backstage source.
        let hearMonitor = monitorAllowed && (!soloActive || soloed)
        for frame in 0..<frameCount {
            let channelGain = gain.advance()
            let sendGain = auxSend.advance()
            for side in 0..<2 {
                let index = frame * 2 + side
                let value = source[index]
                contribution[index] = programAllowed ? value * channelGain : 0
                if programAllowed {
                    program[index] += contribution[index]
                    aux[index] += value * sendGain
                } else {
                    isolated[index] = 0
                    preEffects[index] = 0
                }
                if hearMonitor { monitor[index] += value * channelGain }
            }
        }
        os_unfair_lock_unlock(&lock)
        return programAllowed ? (pre: preGaps, post: postGaps) : (pre: frameCount, post: frameCount)
    }

    /// A04: the channel's current pre-fader meter reading.
    var levels: AudioLevels {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return meter.levels
    }

    func statistics() -> AudioChannelStatistics {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var stats = AudioChannelStatistics()
        stats.droppedFrames = ring.droppedFrames
        stats.underrunFrames = ring.underrunFrames
        stats.receivedFrames = ring.receivedFrames
        return stats
    }
}

/// One full-lease recipient's bounded PCM delivery queue. Its sum scratch is
/// used only by the mixer actor; the queue retains immutable owned chunks.
private final class GuestReturnMailbox: @unchecked Sendable {
    let lease: GuestReceiveLease
    var scratch = [Float](repeating: 0, count: AudioMixEngine.chunkFrames * 2)
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let capacity: Int
    private let current: @Sendable (GuestReturnAudioFrame) -> Bool
    private let sink: @Sendable (GuestReturnAudioFrame) -> Void
    private var pending: [GuestReturnAudioFrame] = []
    private var draining = false, closed = false
    private var drops: Int64 = 0
    init(lease: GuestReceiveLease, token: UUID, capacity: Int,
         current: @escaping @Sendable (GuestReturnAudioFrame) -> Bool,
         sink: @escaping @Sendable (GuestReturnAudioFrame) -> Void) {
        self.lease = lease; self.capacity = max(1, min(8, capacity))
        self.current = current; self.sink = sink
        queue = DispatchQueue(label: "stream.audio.guest-return.\(token.uuidString)", qos: .userInitiated)
    }
    func clearScratch() { for index in scratch.indices { scratch[index] = 0 } }
    func accumulate(_ samples: [Float]) {
        for index in scratch.indices { scratch[index] += samples[index] }
    }
    func dropCount() -> Int64 { lock.lock(); defer { lock.unlock() }; return drops }
    func close() { lock.lock(); closed = true; pending.removeAll(); lock.unlock() }
    func post(_ frame: GuestReturnAudioFrame) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if pending.count >= capacity { pending.removeFirst(); drops += 1 }
        pending.append(frame)
        let schedule = !draining
        if schedule { draining = true }; lock.unlock()
        if schedule { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !closed, !pending.isEmpty else { draining = false; lock.unlock(); return }
            let frame = pending.removeFirst(); lock.unlock()
            if current(frame) { sink(frame) }
        }
    }
}

/// One tap's bounded, drop-oldest chunk queue — the audio twin of the video
/// engine's `FrameMailbox`. `post` never blocks; at capacity the oldest chunk
/// is shed and counted. Delivery runs on the tap's private serial queue, so a
/// slow consumer (publisher mid-reconnect, recorder flushing) backs up and
/// sheds only its own chunks.
private final class AudioTapMailbox: @unchecked Sendable {
    let description: String
    /// The bus this tap consumes (nil for isolated channel taps).
    let bus: AudioBus?
    /// The channel this tap isolates (nil for bus taps).
    let isolatedChannel: AudioChannelID?
    let processing: IsolatedAudioProcessing
    private let sink: AudioMixEngine.AudioSink
    private let deliveryFilter: (@Sendable (CMSampleBuffer) -> CMSampleBuffer?)?
    private let queue: DispatchQueue
    private var lock = os_unfair_lock_s()
    private var capacity: Int
    private var pending: [CMSampleBuffer] = []
    private var isDraining = false
    /// Chunks shed at capacity. Read under `lock` by `dropCount()`.
    private var droppedCount: Int64 = 0

    init(description: String, bus: AudioBus?, isolatedChannel: AudioChannelID?,
         processing: IsolatedAudioProcessing = .afterEffects, capacity: Int, token: UUID,
         deliveryFilter: (@Sendable (CMSampleBuffer) -> CMSampleBuffer?)? = nil,
         sink: @escaping AudioMixEngine.AudioSink) {
        self.description = description
        self.bus = bus
        self.isolatedChannel = isolatedChannel
        self.processing = processing
        self.capacity = max(1, capacity)
        self.sink = sink
        self.deliveryFilter = deliveryFilter
        self.queue = DispatchQueue(label: "com.joeblau.StreamMac.audio.tap.\(token.uuidString)",
                                   qos: .userInitiated)
    }

    func dropCount() -> Int64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return droppedCount
    }

    func post(_ sample: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        if pending.count >= capacity {
            pending.removeFirst()
            droppedCount += 1
        }
        pending.append(sample)
        let shouldSchedule = !isDraining
        if shouldSchedule { isDraining = true }
        os_unfair_lock_unlock(&lock)
        if shouldSchedule {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            os_unfair_lock_lock(&lock)
            guard !pending.isEmpty else {
                isDraining = false
                os_unfair_lock_unlock(&lock)
                return
            }
            let sample = pending.removeFirst()
            os_unfair_lock_unlock(&lock)
            if let deliveryFilter {
                if let filtered = deliveryFilter(sample) { sink(filtered) }
            } else { sink(sample) }
        }
    }

    /// A permission change discards queued source samples without rewriting
    /// their timestamps. The isolated consumer receives counted silence for
    /// the same canonical sample window; a retired lease delivers nothing.
    static func silence(like sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = sample.formatDescription else { return nil }
        let frames = sample.numSamples
        var block: CMBlockBuffer?
        let bytes = frames * 2 * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block,
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                     dataLength: bytes) == noErr else { return nil }
        var output: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: sample.presentationTimeStamp,
            packetDescriptions: nil, sampleBufferOut: &output) == noErr, let output else { return nil }
        IsolatedAudioGap.attach(frames, to: output)
        return output
    }
}
