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
    /// A guest/remote contribution (EP06), keyed by guest session ID.
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
/// rings hold 200 ms; overflow drops OLDEST frames (bounded latency), underrun
/// inserts counted silence, tap queues drop oldest chunks. Nothing blocks.
actor AudioMixEngine {
    /// Engine-wide mix format: 48 kHz stereo (canonical, see StreamCore).
    static let sampleRate = 48_000
    /// Frames per mixed chunk (~10.7 ms). Chunks are emitted back-to-back at
    /// exactly this size, so the output timestamp stream is perfectly regular.
    static let chunkFrames = 512
    /// Per-channel ring capacity: 200 ms — the bounded real-time buffer.
    static let ringCapacityFrames = 9_600
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
    private var busGains: [AudioBus: Float] = [.program: 1, .monitor: 1, .aux: 1]
    private var taps: [UUID: AudioTapMailbox] = [:]
    private var cancelledTokens: Set<UUID> = []
    /// Gain assignments that arrived before their channel existed; applied at
    /// channel creation (scene gains are pushed before a new capture's first
    /// audio buffer lands).
    private var pendingGains: [AudioChannelID: ChannelGain] = [:]

    // Reused mix scratch (actor-confined): no per-chunk allocations.
    private var programScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var monitorScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var auxScratch = [Float](repeating: 0, count: chunkFrames * 2)
    private var isoScratch = [Float](repeating: 0, count: chunkFrames * 2)
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
        registry.prune(keeping: ids)
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
        let captureChannels = registry.channelIDs().filter {
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
                        sink: @escaping AudioSink) {
        if cancelledTokens.remove(token) != nil { return }
        taps[token] = AudioTapMailbox(description: "iso.\(channel.label)",
                                      bus: nil, isolatedChannel: channel,
                                      capacity: capacity, token: token, sink: sink)
    }

    func removeTap(_ token: UUID) {
        if taps.removeValue(forKey: token) == nil {
            cancelledTokens.insert(token)
        }
    }

    /// Master gain for one bus (program/monitor/aux). Applied post-sum,
    /// pre-clamp. A07 rides on this for monitor level.
    func setBusGain(_ bus: AudioBus, gain: Float) {
        busGains[bus] = max(0, gain)
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

    /// Emits every chunk whose sample window is safely in the past. The 5 ms
    /// safety margin absorbs capture-callback delivery jitter at chunk edges;
    /// later arrival is covered by the ring's counted-silence underrun policy.
    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let elapsedFrames = Int64(CMTimeGetSeconds(CMTimeSubtract(now, anchor))
                                    * Double(Self.sampleRate))
        let safety: Int64 = 240
        while mixPosition + Int64(Self.chunkFrames) <= elapsedFrames - safety {
            mixChunk(at: mixPosition)
            mixPosition += Int64(Self.chunkFrames)
        }
    }

    /// Mixes one fixed-size chunk across all channels and posts it to every
    /// bus tap that has subscribers. Buses with no taps are not rendered.
    private func mixChunk(at position: Int64) {
        let frames = Self.chunkFrames
        let channelIDs = registry.channelIDs()
        let wantProgram = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .program }
        let wantMonitor = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .monitor }
        let wantAux = taps.values.contains { $0.isolatedChannel == nil && $0.bus == .aux }
        let wantAnyBus = wantProgram || wantMonitor || wantAux

        for index in programScratch.indices {
            programScratch[index] = 0
            monitorScratch[index] = 0
            auxScratch[index] = 0
        }

        for id in channelIDs {
            let wantsISO = taps.values.contains { $0.isolatedChannel == id }
            guard wantAnyBus || wantsISO else { continue }
            for index in isoScratch.indices { isoScratch[index] = 0 }
            registry.mixChannel(id, at: position, frameCount: frames,
                                program: &programScratch, aux: &auxScratch,
                                isolated: &isoScratch)
            if wantsISO {
                let pts = chunkPTS(at: position)
                if let sample = makeSampleBuffer(isoScratch, frames: frames, pts: pts) {
                    for tap in taps.values where tap.isolatedChannel == id {
                        tap.post(sample)
                    }
                }
            }
        }

        postBus(.program, from: programScratch, at: position, wanted: wantProgram)
        postBus(.monitor, from: programScratch, at: position, wanted: wantMonitor)
        postBus(.aux, from: auxScratch, at: position, wanted: wantAux)
    }

    private func postBus(_ bus: AudioBus, from samples: [Float],
                         at position: Int64, wanted: Bool) {
        guard wanted else { return }
        var mixed = samples
        AudioMixerCore.applyBusGainAndClamp(&mixed, gain: busGains[bus] ?? 1)
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

    func setAnchor(_ anchor: CMTime) {
        os_unfair_lock_lock(&lock)
        self.anchor = anchor
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        channels.removeAll()
        os_unfair_lock_unlock(&lock)
    }

    func addChannel(_ id: AudioChannelID,
                    insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?,
                    gain: AudioMixEngine.ChannelGain?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        // Replace, not just insert-if-absent: an early buffer may have
        // auto-registered the channel (insert-less) just before this call,
        // and the explicit registration (VoicePolish on the mic) must win.
        channels[id] = ChannelIngest(insert: insert,
                                     initialGain: gain?.effectiveGain ?? Self.defaultGain(for: id))
    }

    func removeChannel(_ id: AudioChannelID) {
        os_unfair_lock_lock(&lock)
        channels[id] = nil
        os_unfair_lock_unlock(&lock)
    }

    func prune(keeping ids: Set<AudioChannelID>) {
        os_unfair_lock_lock(&lock)
        channels = channels.filter { ids.contains($0.key) }
        os_unfair_lock_unlock(&lock)
    }

    func setGain(_ id: AudioChannelID, effectiveGain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setGain(effectiveGain, rampFrames: rampFrames)
    }

    func setAuxSend(_ id: AudioChannelID, gain: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.setAuxSend(gain, rampFrames: rampFrames)
    }

    func enqueue(_ id: AudioChannelID, _ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        let anchor = self.anchor
        let channel = channels[id] ?? {
            let created = ChannelIngest(insert: nil,
                                        initialGain: Self.defaultGain(for: id))
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
                    isolated: inout [Float]) {
        os_unfair_lock_lock(&lock)
        let channel = channels[id]
        os_unfair_lock_unlock(&lock)
        channel?.mix(at: position, frameCount: frameCount,
                     program: &program, aux: &aux, isolated: &isolated)
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
    private var ring = AudioRingBuffer(capacityFrames: AudioMixEngine.ringCapacityFrames)
    private var gain: ChannelGainRamp
    private var auxSend = ChannelGainRamp(gain: 0)
    private var chunk = [Float](repeating: 0, count: AudioMixEngine.chunkFrames * 2)

    init(insert: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?, initialGain: Float) {
        self.insert = insert
        self.gain = ChannelGainRamp(gain: initialGain)
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

    /// Capture-thread ingest: insert (VoicePolish/FX) → canonical conversion →
    /// ring write at the capture PTS's absolute engine position. Buffers with
    /// no usable PTS append contiguously; unreadable/non-LPCM buffers drop.
    func enqueue(_ sampleBuffer: CMSampleBuffer, anchor: CMTime) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
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

    /// Mix-loop read: fills the channel scratch at the absolute window,
    /// exposes the pre-fader chunk as `isolated`, and accumulates program/aux
    /// with per-frame ramped gains (the click-free Take/mute contract).
    func mix(at position: Int64, frameCount: Int,
             program: inout [Float], aux: inout [Float],
             isolated: inout [Float]) {
        os_unfair_lock_lock(&lock)
        ring.fill(at: position, frameCount: frameCount, into: &chunk)
        for index in 0..<(frameCount * 2) { isolated[index] = chunk[index] }
        AudioMixerCore.accumulate(source: chunk, frameCount: frameCount,
                                  gain: &gain, auxGain: &auxSend,
                                  program: &program, aux: &aux)
        os_unfair_lock_unlock(&lock)
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
    private let sink: AudioMixEngine.AudioSink
    private let queue: DispatchQueue
    private var lock = os_unfair_lock_s()
    private var capacity: Int
    private var pending: [CMSampleBuffer] = []
    private var isDraining = false
    /// Chunks shed at capacity. Read under `lock` by `dropCount()`.
    private var droppedCount: Int64 = 0

    init(description: String, bus: AudioBus?, isolatedChannel: AudioChannelID?,
         capacity: Int, token: UUID,
         sink: @escaping AudioMixEngine.AudioSink) {
        self.description = description
        self.bus = bus
        self.isolatedChannel = isolatedChannel
        self.capacity = max(1, capacity)
        self.sink = sink
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
            sink(sample)
        }
    }
}
