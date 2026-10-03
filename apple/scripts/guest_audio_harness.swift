import AVFoundation
import CoreMedia
import Foundation
import StreamCore

// Only opaque identity types are substituted. AudioMixEngine, its real bounded
// taps/rings, original-PTS ingest, and native PCM file encode/decode are shipping
// code. No receiver, credential, physical input/output or permission is invoked.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}

func emit(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }

func require(_ condition: Bool, _ message: String = "Guest audio qualification assertion", file: StaticString = #file, line: UInt = #line) {
    precondition(condition, message, file: file, line: line)
}

struct GuestAudioPacket: Sendable {
    let pts: Double
    let samples: [Float]
    let gaps: Int
}
final class GuestAudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [GuestAudioPacket] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { preconditionFailure("Missing PCM") }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        require(status == noErr)
        lock.lock(); defer { lock.unlock() }
        require(packets.count < 2_000, "Probe itself must remain bounded")
        packets.append(.init(pts: sample.presentationTimeStamp.seconds, samples: values, gaps: IsolatedAudioGap.frames(in: sample)))
    }
    func snapshot() -> [GuestAudioPacket] { lock.lock(); defer { lock.unlock() }; return packets }
}
final class GuestAudioBlockedProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let probe = GuestAudioProbe()
    private var first = true // The real tap's one serial callback queue owns it.
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 1) == .success }
    func receive(_ sample: CMSampleBuffer) {
        if first {
            first = false; entered.signal()
            require(release.wait(timeout: .now() + 3) == .success, "Blocked tap cleanup timed out")
        }
        probe.receive(sample)
    }
}

@main struct GuestAudioHarness {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await admissionAndClock()
        try await atomicPersistedMixer()
        try await originalSourceClock(directory)
        try await routesAndFiles(directory)
        try await queuedISOPermission(processing: .beforeEffects, replaceLease: false)
        try await queuedISOPermission(processing: .afterEffects, replaceLease: false)
        try await queuedISOPermission(processing: .afterEffects, replaceLease: true)
        try await boundedBacklog()
        emit("PASS: explicit full guest lease / original host-PTS PCM / independent Program-monitor / backstage pre-post ISO / bounded native audio qualification")
    }
    static func lease(slot: UUID = UUID(), generation: UInt64 = 1) -> GuestReceiveLease {
        .init(slot: slot, peerID: UUID(), negotiation: UUID(), generation: generation)
    }
    static func pcm(frames: Int = 480, interleaved: Bool = false, frequency: Double = 2_000, offset: Double = 0,
                    amplitude: Float = 0.25, rate: Double = 48_000, channels: UInt32 = 2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if interleaved {
            let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for side in 0..<Int(channels) { data[frame * Int(channels) + side] = amplitude * Float(sin((offset + Double(frame) / rate) * 2 * .pi * frequency)) }
            }
        } else {
            for side in 0..<Int(channels) {
                for frame in 0..<frames { buffer.floatChannelData![side][frame] = amplitude * Float(sin((offset + Double(frame) / rate) * 2 * .pi * frequency)) }
            }
        }
        return buffer
    }
    static func frame(_ lease: GuestReceiveLease, pts: Double, mapping: UUID, pcm: AVAudioPCMBuffer? = nil,
                      duration: Double? = nil) -> GuestAudioFrame {
        let buffer = pcm ?? self.pcm()
        return .init(lease: lease, pcm: buffer, pts: CMTime(seconds: pts, preferredTimescale: 48_000),
                     duration: CMTime(seconds: duration ?? Double(buffer.frameLength) / 48_000, preferredTimescale: 48_000),
                     mappingGeneration: mapping, clockQuality: .senderReportAligned)
    }
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    static func admissionAndClock() async throws {
        let engine = AudioMixEngine(), first = lease(), mapping = UUID()
        let guest = AudioMixEngine.guestChannelID(for: first), fake = AudioChannelID.guest(id: "unknown-label")
        await engine.run()
        let time = now() + 0.04
        require(!engine.enqueueGuest(frame(first, pts: time, mapping: mapping)), "A callback cannot register")
        await engine.addChannel(fake); await engine.setChannelGain(fake, volume: 1, isMuted: false)
        engine.enqueue(fake, try ProgramRecordingFixtures.audio(at: 0, timestampBase: time, constantTone: true))
        await engine.addIsolatedTap(channel: fake, token: UUID()) { _ in preconditionFailure("Unknown guest tap registered") }
        require(await engine.statsSnapshot().channels[fake.label] == nil, "Generic guest paths must not register")
        require(await engine.registerGuest(first))
        require(engine.registeredGuestChannelID(slot: first.slot) == guest)
        require(engine.registeredGuestChannelID(slot: UUID()) == nil)
        require(!(await engine.registerGuest(lease())), "Qualified bound is one explicit slot")
        require(!engine.validateGuestFrame(frame(first, pts: time, mapping: UUID(), pcm: pcm(rate: 44_100))))
        require(engine.guestAdmissionSnapshot().mappingGeneration == nil, "Malformed first receipt cannot poison mapping")
        require(engine.validateGuestFrame(frame(first, pts: time, mapping: mapping)))
        require(engine.guestAdmissionSnapshot().mappingGeneration == nil, "Pure validation cannot pin mapping")
        require(engine.enqueueGuest(frame(first, pts: time, mapping: mapping)))
        let accepted = engine.guestAdmissionSnapshot()
        require(abs(accepted.lastPTS.seconds - time) <= 1 / 48_000, "Original PTS must survive intake")
        require(abs(accepted.lastEndPTS.seconds - time - 0.01) <= 1 / 48_000)
        require(!engine.enqueueGuest(frame(first, pts: time, mapping: mapping)), "Duplicate PTS rejected")
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: UUID())), "Mapping generation mismatch rejected")
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: mapping, pcm: pcm(frames: 5_761))), "Oversize PCM rejected")
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: mapping, pcm: pcm(rate: 44_100))), "Wrong canonical rate rejected")
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: mapping, pcm: pcm(channels: 1))), "Wrong canonical shape rejected")
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: mapping, duration: 0.04)), "False packet duration rejected")
        let badPCM = pcm(); badPCM.floatChannelData![0][1] = .nan
        require(!engine.enqueueGuest(frame(first, pts: time + 0.02, mapping: mapping, pcm: badPCM)), "Nonfinite PCM rejected")
        require(!engine.enqueueGuest(frame(first, pts: now() + 0.8, mapping: mapping)), "Unbounded future PTS rejected")
        require(engine.enqueueGuest(frame(first, pts: time + 0.01, mapping: mapping, pcm: pcm(interleaved: true))))
        let replacement = lease(slot: first.slot, generation: 2)
        require(await engine.registerGuest(replacement))
        require(!(await engine.registerGuest(first)), "Older explicit registration cannot replace newer")
        require(!engine.enqueueGuest(frame(first, pts: now() + 0.04, mapping: mapping)), "Old callback rejected after replacement")
        require(!engine.removeGuest(first), "Old owner cannot remove current admission")
        require(!engine.setGuestRouting(first, programAllowed: true, monitorAllowed: true))
        require(engine.guestAdmissionSnapshot().programAllowed == false)
        require(engine.enqueueGuest(frame(replacement, pts: now() + 0.04, mapping: UUID())))
        await engine.pruneChannels(keeping: [])
        require(engine.registeredGuestChannelID(slot: replacement.slot) == guest, "Capture pruning cannot drop explicit guest")
        await engine.stop(); await engine.run()
        require(engine.registeredGuestChannelID(slot: replacement.slot) == guest, "Demand restart retains explicit admission")
        require(engine.enqueueGuest(frame(replacement, pts: now() + 0.04, mapping: engine.guestAdmissionSnapshot().mappingGeneration!)))
        require(engine.removeGuest(replacement))
        require(!engine.enqueueGuest(frame(replacement, pts: now() + 0.08, mapping: UUID())))
        require(!(await engine.registerGuest(replacement)), "A removed generation cannot resurrect")
        require(await engine.registerGuest(lease(slot: first.slot, generation: 3)))
        engine.retireGuestAdmissions()
        require(!engine.enqueueGuest(frame(replacement, pts: now() + 0.04, mapping: UUID())))
        require(!(await engine.registerGuest(replacement)), "Retired runtime cannot re-register")
        require(engine.guestAdmissionSnapshot().retired)
        await engine.stop()
        emit("PASS: unknown/generic/old negotiation rejected; one lease bound; canonical finite <=120ms PCM, exact original PTS/mapping, prune/restart and synchronous permanent retirement")
    }

    static func power(_ packets: [GuestAudioPacket], frequency: Double, from start: Double, to end: Double) -> Double {
        var real = 0.0, imaginary = 0.0, count = 0
        for packet in packets {
            for frame in 0..<(packet.samples.count / 2) {
                let time = packet.pts + Double(frame) / 48_000
                guard time >= start && time < end else { continue }
                let value = Double(packet.samples[frame * 2])
                real += value * cos(time * 2 * .pi * frequency)
                imaginary += value * sin(time * 2 * .pi * frequency)
                count += 1
            }
        }
        require(count > 4_000, "Need a real measured PCM window")
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(count)
    }
    static func assertTone(_ probe: GuestAudioProbe, frequency: Double, present: Bool, start: Double, end: Double, name: String) {
        let amplitude = power(probe.snapshot(), frequency: frequency, from: start, to: end)
        require(present ? amplitude > 0.15 : amplitude < 0.005, "\(name): measured \(frequency)Hz amplitude \(amplitude), expected present=\(present)")
        emit("TRACE: \(name) \(frequency)Hz amplitude=\(amplitude)")
    }

    static func atomicPersistedMixer() async throws {
        let engine = AudioMixEngine(), previous = lease(), admission = lease(slot: previous.slot, generation: 2), mapping = UUID()
        let guest = AudioMixEngine.guestChannelID(for: admission), unrelated = AudioChannelID.application(bundleID: "fixture.atomic-independent")
        var restored = MixerSettings()
        restored.channelVolumes[guest.label] = 0.4
        restored.channelMutes[guest.label] = true
        restored.soloedChannels.insert(guest.label)
        restored.channelAuxSends[guest.label] = 0.5
        require(await engine.registerGuest(previous))
        require(engine.removeGuest(previous))
        require(await engine.registerGuest(admission, initialMixer: restored))
        var stale = MixerSettings()
        stale.channelVolumes[guest.label] = 2
        stale.channelMutes[guest.label] = false
        stale.channelAuxSends[guest.label] = 1
        require(!(await engine.registerGuest(previous, initialMixer: stale)), "Rejected old registration cannot mutate current mixer")
        require(await engine.registerGuest(admission, initialMixer: stale), "Exact idempotent lease registration must preserve existing mix")
        // A subsequent default API call reads the saved mute, not the stale
        // rejected/idempotent supplied settings. Prove it with actual PCM.
        require(engine.setGuestRouting(admission, programAllowed: true, monitorAllowed: true))
        let program = GuestAudioProbe(), monitor = GuestAudioProbe(), aux = GuestAudioProbe()
        await engine.addTap(bus: .program, token: UUID(), capacity: 32, sink: program.receive)
        await engine.addTap(bus: .monitor, token: UUID(), capacity: 32, sink: monitor.receive)
        await engine.addTap(bus: .aux, token: UUID(), capacity: 32, sink: aux.receive)
        await engine.run() // Must keep the atomically restored mute/solo/send.
        await engine.setChannelGain(unrelated, volume: 1, isMuted: false)
        await engine.addChannel(unrelated)
        let base = now() + 0.04, clock = ContinuousClock(), start = clock.now
        for index in 0..<90 {
            let offset = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            if index == 45 { await engine.setChannelGain(guest, volume: 0.4, isMuted: false) }
            require(engine.enqueueGuest(frame(admission, pts: base + offset, mapping: mapping, pcm: pcm(offset: offset))))
            engine.enqueue(unrelated, try ProgramRecordingFixtures.audio(at: offset, timestampBase: base, constantTone: true, amplitude: 0.2))
        }
        try await Task.sleep(for: .milliseconds(100)); await engine.stop()
        assertTone(program, frequency: 2_000, present: false, start: base + 0.15, end: base + 0.35, name: "atomic restored mute")
        assertTone(monitor, frequency: 2_000, present: false, start: base + 0.15, end: base + 0.35, name: "atomic restored monitor mute")
        assertTone(monitor, frequency: 1_000, present: false, start: base + 0.15, end: base + 0.35, name: "atomic restored guest solo")
        let gain = power(program.snapshot(), frequency: 2_000, from: base + 0.6, to: base + 0.8)
        let send = power(aux.snapshot(), frequency: 2_000, from: base + 0.15, to: base + 0.35)
        require(abs(gain - 0.1) < 0.005, "Restored0.4 fader after unmute: \(gain)")
        require(abs(send - 0.125) < 0.005, "Restored0.5 pre-fader aux: \(send)")
        try await pendingMutedRejoin(engine, original: admission, mixer: restored)
        emit("PASS: full-lease atomic MixerSettings registration preserved mute/solo/0.4fader/0.5aux through reset; rejected stale and exact-idempotent settings cannot overwrite; actual Program amplitude=\(gain), aux=\(send)")
    }

    static func pendingMutedRejoin(_ engine: AudioMixEngine, original: GuestReceiveLease, mixer: MixerSettings) async throws {
        require(engine.removeGuest(original))
        let seeded = lease(slot: original.slot, generation: 3)
        require(await engine.registerGuest(seeded, initialMixer: mixer))
        require(engine.removeGuest(seeded))
        let rejoin = lease(slot: original.slot, generation: 4), mapping = UUID(), probe = GuestAudioProbe()
        require(await engine.registerGuest(rejoin)) // Default reads newly seeded pending mute.
        require(engine.setGuestRouting(rejoin, programAllowed: true, monitorAllowed: true))
        await engine.addTap(bus: .program, token: UUID(), capacity: 32, sink: probe.receive)
        await engine.run()
        let base = now() + 0.04, clock = ContinuousClock(), start = clock.now
        for index in 0..<30 {
            let offset = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            require(engine.enqueueGuest(frame(rejoin, pts: base + offset, mapping: mapping, pcm: pcm(offset: offset))))
        }
        try await Task.sleep(for: .milliseconds(100)); await engine.stop()
        assertTone(probe, frequency: 2_000, present: false, start: base + 0.12, end: base + 0.25, name: "default rejoin preserves newly seeded pending mute")
    }

    static func originalSourceClock(_ directory: URL) async throws {
        let engine = AudioMixEngine(), admission = lease(), mapping = UUID(), probe = GuestAudioProbe()
        require(await engine.registerGuest(admission))
        require(engine.setGuestRouting(admission, programAllowed: true, monitorAllowed: false))
        await engine.addTap(bus: .program, token: UUID(), capacity: 32, sink: probe.receive)
        await engine.run()
        let base = now() + 0.12, clock = ContinuousClock(), start = clock.now
        for index in 0..<50 {
            let offset = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            let buffer = pcm(offset: offset, amplitude: (15..<25).contains(index) ? 0.25 : 0)
            require(engine.enqueueGuest(frame(admission, pts: base + offset, mapping: mapping, pcm: buffer)))
            // Simulate receiver buffer reuse immediately after its callback.
            // The bounded inlet must own the samples already admitted.
            for side in 0..<2 { memset(buffer.floatChannelData![side], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size) }
        }
        try await Task.sleep(for: .milliseconds(160))
        await engine.stop()
        let packets = probe.snapshot()
        var onset: Double?
        for packet in packets {
            if let index = packet.samples.firstIndex(where: { abs($0) > 0.10 }) {
                onset = packet.pts + Double(index / 2) / 48_000; break
            }
        }
        require(onset != nil)
        let error = onset! - (base + 0.15)
        require(abs(error) < 0.0001, "A 120ms early receipt was rebased instead of placed at original source PTS: \(error)")
        for pair in zip(packets, packets.dropFirst()) {
            require(abs(pair.1.pts - pair.0.pts - 512.0 / 48_000) < 0.000001, "One host-clock output grid")
        }
        try saveAndRead(packets, to: directory.appendingPathComponent("original-host-clock.wav"))
        emit("PASS: 120ms early guest receipt retained original host PTS and owned PCM despite source-buffer reuse; tone onset error=\(error)s (<100us qualification window), native decoded WAV and continuous 512-frame grid")
    }

    static func routesAndFiles(_ directory: URL) async throws {
        let engine = AudioMixEngine(), admission = lease(), mapping = UUID()
        let guest = AudioMixEngine.guestChannelID(for: admission), unrelated = AudioChannelID.application(bundleID: "fixture.independent-tone")
        let program = GuestAudioProbe(), monitor = GuestAudioProbe(), aux = GuestAudioProbe(), before = GuestAudioProbe(), after = GuestAudioProbe()
        await engine.setChannelGain(guest, volume: 1, isMuted: false)
        require(await engine.registerGuest(admission))
        await engine.addTap(bus: .program, token: UUID(), capacity: 32, sink: program.receive)
        await engine.addTap(bus: .monitor, token: UUID(), capacity: 32, sink: monitor.receive)
        await engine.addTap(bus: .aux, token: UUID(), capacity: 32, sink: aux.receive)
        await engine.addIsolatedTap(channel: guest, token: UUID(), capacity: 32, processing: .beforeEffects, sink: before.receive)
        await engine.addIsolatedTap(channel: guest, token: UUID(), capacity: 32, processing: .afterEffects, sink: after.receive)
        await engine.run()
        await engine.setChannelGain(unrelated, volume: 1, isMuted: false)
        await engine.addChannel(unrelated)
        await engine.setChannelAuxSend(guest, gain: 1)
        let base = now() + 0.08, clock = ContinuousClock(), start = clock.now
        var acknowledgements = ["backstage": now()]
        for index in 0..<310 {
            let offset = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            if index == 60 {
                require(engine.setGuestRouting(admission, programAllowed: false, monitorAllowed: true))
                acknowledgements["private-monitor"] = now()
            }
            if index == 120 {
                require(engine.setGuestRouting(admission, programAllowed: true, monitorAllowed: false))
                acknowledgements["program-only"] = now()
            }
            if index == 180 {
                require(engine.setGuestRouting(admission, programAllowed: true, monitorAllowed: true))
                await engine.setChannelSolo(guest, soloed: true)
                acknowledgements["monitor-solo"] = now()
            }
            if index == 220 {
                require(engine.setGuestRouting(admission, programAllowed: false, monitorAllowed: false))
                acknowledgements["revoked"] = now()
            }
            if index == 270 {
                await engine.setChannelSolo(.application(bundleID: "fixture.absent-solo-source"), soloed: true)
                acknowledgements["absent-local-solo"] = now()
            }
            let packet = frame(admission, pts: base + offset, mapping: mapping, pcm: pcm(offset: offset))
            require(engine.enqueueGuest(packet), "Timed source packet must be admitted")
            // Independent local source remains on its own original timestamps.
            engine.enqueue(unrelated, try ProgramRecordingFixtures.audio(at: offset, timestampBase: base, constantTone: true, amplitude: 0.2))
        }
        try await Task.sleep(for: .milliseconds(160))
        await engine.stop()
        let phases = [
            (0.15, 0.45, false, false, true, "backstage"), (0.75, 1.05, false, true, true, "private-monitor"),
            (1.35, 1.65, true, false, true, "program-only"), (1.95, 2.10, true, true, false, "monitor-solo"),
            (2.35, 2.60, false, false, true, "revoked"), (2.85, 3.05, false, false, false, "absent-local-solo")
        ]
        for (index, phase) in phases.enumerated() {
            let (begin, finish, programOn, monitorOn, localMonitorOn, label) = phase
            // Authority follows actual acknowledged commands, independently of
            // the source's continuous original timestamps and arrival counter.
            // Retain strict spectra with four native chunks around transitions.
            let measuredStart = max(base + begin, acknowledgements[label]! + 4 * 512.0 / 48_000)
            let nextAck = index + 1 < phases.count ? acknowledgements[phases[index + 1].5]! : .infinity
            let measuredEnd = min(base + finish, nextAck - 4 * 512.0 / 48_000)
            emit("TRACE: \(label) actual ack=\(acknowledgements[label]!-base)s measured PTS window=\(measuredStart-base)..<\(measuredEnd-base)s")
            assertTone(program, frequency: 2_000, present: programOn, start: measuredStart, end: measuredEnd, name: "\(label) Program guest")
            assertTone(monitor, frequency: 2_000, present: monitorOn, start: measuredStart, end: measuredEnd, name: "\(label) monitor guest")
            for (name, probe) in [("aux", aux), ("before", before), ("after", after)] {
                assertTone(probe, frequency: 2_000, present: programOn, start: measuredStart, end: measuredEnd, name: "\(label) \(name) guest")
            }
            assertTone(program, frequency: 1_000, present: true, start: measuredStart, end: measuredEnd, name: "\(label) unrelated Program")
            assertTone(monitor, frequency: 1_000, present: localMonitorOn, start: measuredStart, end: measuredEnd, name: "\(label) unrelated monitor")
        }
        for (name, probe) in [("program", program), ("monitor", monitor), ("iso-before", before), ("iso-after", after)] {
            try saveAndRead(probe.snapshot(), to: directory.appendingPathComponent("\(name).wav"))
        }
        let stats = await engine.statsSnapshot()
        require(stats.tapDrops.isEmpty, "Normal taps must keep up; drops=\(stats.tapDrops)")
        emit("PASS: real Program/monitor/aux and pre/post taps preserve independent 1000Hz local tone, authorized 2000Hz guest routing, independent original host timestamps; decoded WAV exact samples")
    }

    static func saveAndRead(_ packets: [GuestAudioPacket], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        var frames = 0
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            for packet in packets {
                let count = packet.samples.count / 2
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0].mData!
                _ = packet.samples.withUnsafeBytes { memcpy(data, $0.baseAddress!, $0.count) }
                try file.write(from: buffer); frames += count
            }
        } // Close the real writer before reading its finalized WAV header.
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        require(reader.length == frames)
        let decoded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        try reader.read(into: decoded)
        require(CanonicalAudioConverter.interleavedFloats(decoded) == packets.flatMap(\.samples), "Actual native WAV decoded PCM must match tap")
    }

    static func boundedBacklog() async throws {
        let engine = AudioMixEngine(), admission = lease(), mapping = UUID()
        require(await engine.registerGuest(admission))
        await engine.run()
        // With no output demand, due source chunks are not consumed. One
        // continuous original-clock750ms burst exceeds the real700ms ring.
        try await Task.sleep(for: .milliseconds(400))
        let base = now() - 0.25
        for index in 0..<15 {
            let offset = Double(index) * 0.05
            require(engine.enqueueGuest(frame(admission, pts: base + offset, mapping: mapping,
                                               pcm: pcm(frames: 2_400, offset: offset))))
        }
        let stats = await engine.statsSnapshot().channels[AudioMixEngine.guestChannelID(for: admission).label]!
        require(stats.receivedFrames == 36_000)
        require(stats.droppedFrames == 2_400, "A real excess750ms backlog must shed exactly oldest50ms, got \(stats.droppedFrames)")
        // Synchronous authority removal precedes asynchronous owner cleanup.
        require(engine.removeGuest(admission))
        let stale = frame(admission, pts: now() + 0.05, mapping: mapping)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { engine.enqueueGuest(stale) } }
            for await accepted in group { require(!accepted, "Concurrent late callbacks cannot resurrect removed lease") }
        }
        require(engine.registeredGuestChannelID(slot: admission.slot) == nil)
        await engine.stop()
        emit("PASS: actual 750ms backlog -> bounded 700ms ring shed exactly 2400 oldest frames; 32 concurrent stale callbacks rejected after synchronous removal")
    }

    static func queuedISOPermission(processing: IsolatedAudioProcessing, replaceLease: Bool) async throws {
        let engine = AudioMixEngine(), admission = lease(), mapping = UUID(), blocked = GuestAudioBlockedProbe()
        let guest = AudioMixEngine.guestChannelID(for: admission)
        await engine.setChannelGain(guest, volume: 1, isMuted: false)
        require(await engine.registerGuest(admission))
        await engine.addIsolatedTap(channel: guest, token: UUID(), capacity: 32, processing: processing, sink: blocked.receive)
        require(engine.setGuestRouting(admission, programAllowed: true, monitorAllowed: false))
        await engine.run()
        // First callback is a genuine zero chunk before source onset. It holds
        // the serial mailbox while authorized tone accumulates behind it.
        try await Task.sleep(for: .milliseconds(40))
        require(await Task.detached { blocked.waitEntered() }.value)
        let base = now() + 0.04, clock = ContinuousClock(), start = clock.now
        for index in 0..<12 {
            let offset = Double(index) / 100
            try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            require(engine.enqueueGuest(frame(admission, pts: base + offset, mapping: mapping, pcm: pcm(offset: offset))))
        }
        try await Task.sleep(for: .milliseconds(50))
        if replaceLease {
            let replacement = lease(slot: admission.slot, generation: 2)
            require(await engine.registerGuest(replacement))
            require(engine.setGuestRouting(replacement, programAllowed: true, monitorAllowed: true))
        } else { require(engine.setGuestRouting(admission, programAllowed: false, monitorAllowed: false)) }
        blocked.release.signal()
        try await Task.sleep(for: .milliseconds(80))
        let packets = blocked.probe.snapshot()
        if replaceLease {
            require(packets.count == 1, "A replacement's Program grant cannot release old lease's queued ISO or new channel packets")
        } else {
            require(packets.count > 10, "Need actual queued windows")
            require(packets.allSatisfy { $0.samples.allSatisfy { $0 == 0 } }, "Queued backstage PCM must be replaced by original-window silence")
            require(packets.dropFirst().allSatisfy { $0.gaps == 512 }, "Permission silence is explicit source gap")
        }
        await engine.stop(); engine.retireGuestAdmissions()
        emit("PASS: blocked real \(processing.rawValue) tap queued authorized tone; \(replaceLease ? "replaced lease discarded all pending old-lease packets despite new Program grant" : "synchronous gate close zeroed queued PCM at original timestamps with 512-frame gap"); slow consumer did not block ingress")
    }
}
