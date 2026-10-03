import AVFoundation
import CoreMedia
import Foundation
import StreamCore

/// Actual persisted settings, controller admission, dispatcher commands and
/// shipping mixer taps. All sources are owned synthetic PCM; no device capture,
/// receiver, provider account, permission request or network output is started.
private struct PersistedGuestPacket: Sendable {
    let pts: Double
    let samples: [Float]
}
private final class PersistedGuestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [PersistedGuestPacket] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let data = sample.dataBuffer else { preconditionFailure("Missing actual PCM") }
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
        precondition(samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        } == noErr)
        lock.lock(); defer { lock.unlock() }
        precondition(packets.count < 2_000, "Fixture receipt queue is bounded")
        packets.append(.init(pts: sample.presentationTimeStamp.seconds, samples: samples))
    }
    func amplitude(_ frequency: Double, from start: Double, to end: Double) -> Double {
        lock.lock(); let values = packets; lock.unlock()
        var real = 0.0, imaginary = 0.0, count = 0
        for packet in values {
            for frame in 0..<(packet.samples.count / 2) {
                let time = packet.pts + Double(frame) / 48_000
                guard time >= start && time < end else { continue }
                let phase = (time - start) * 2 * .pi * frequency
                let value = Double(packet.samples[frame * 2])
                real += value * cos(phase); imaginary += value * sin(phase); count += 1
            }
        }
        precondition(count > 8_000, "Actual tap must cover a measured PCM window")
        return 2 * hypot(real, imaginary) / Double(count)
    }
}

@MainActor private final class PersistedGuestStudio {
    let mixer = AudioMixEngine()
    let scenes: SceneStore
    let preview: PreviewProgramModel
    let controller: StreamController
    let session: SettingsSession
    let recorder: RecordingController
    let dispatcher: StudioCommandDispatcher
    private let suite = "stream.guest-persisted-mixer.\(UUID().uuidString)"
    private let defaults: UserDefaults
    let program = PersistedGuestProbe(), monitor = PersistedGuestProbe(), aux = PersistedGuestProbe()
    init(directory: URL) {
        scenes = SceneStore(directory: directory)
        preview = PreviewProgramModel(selected: scenes.selected)
        controller = StreamController(sceneStore: scenes, previewProgram: preview,
                                      permissions: PermissionsManager(), audioEngine: mixer)
        session = SettingsSession(store: DesktopSettingsStore(directory: directory), controller: controller)
        defaults = UserDefaults(suiteName: suite)!
        recorder = RecordingController(defaults: defaults, defaultDirectory: directory.appendingPathComponent("Recordings"))
        dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: scenes,
            session: session, recorder: recorder, previewProgram: preview)
    }
    func run() async {
        await mixer.addTap(bus: .program, token: UUID(), capacity: 64, sink: program.receive)
        await mixer.addTap(bus: .monitor, token: UUID(), capacity: 64, sink: monitor.receive)
        await mixer.addTap(bus: .aux, token: UUID(), capacity: 64, sink: aux.receive)
        await mixer.run()
        let local = AudioChannelID.application(bundleID: "fixture.guest-mixer-independent-1000")
        await mixer.setChannelGain(local, volume: 1, isMuted: false)
        await mixer.addChannel(local)
    }
    func close() async {
        controller.retireGuestMedia()
        await mixer.stop()
        scenes.flushPendingWrites()
        defaults.removePersistentDomain(forName: suite)
    }
    func command(_ command: StudioCommand) {
        let result = dispatcher.execute(command)
        precondition(result.error == nil, "Actual dispatcher rejected mixer command")
    }
    func awaitPublishedMixer(_ expected: MixerSettings) async throws {
        for _ in 0..<200 where dispatcher.state.mixer != expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(dispatcher.state.mixer == expected, "Actual published settings observer must refresh the dispatcher")
    }
    func measure(_ title: String, guestProgram: Double, guestMonitor: Double,
                 guestAux: Double, localMonitor: Double) async throws {
        // Authority comes from real command completion and the host clock,
        // independently of the synthetic source's packet counter.
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.12
        let end = start + 0.25
        try await Task.sleep(for: .milliseconds(450))
        for (name, probe, frequency, expected) in [
            ("Program guest", program, 2_000.0, guestProgram),
            ("Monitor guest", monitor, 2_000.0, guestMonitor),
            ("Aux guest", aux, 2_000.0, guestAux),
            ("Program local", program, 1_000.0, 0.2),
            ("Monitor local", monitor, 1_000.0, localMonitor),
            ("Aux local", aux, 1_000.0, 0.0)
        ] {
            let actual = probe.amplitude(frequency, from: start, to: end)
            precondition(abs(actual - expected) < 0.012,
                         "\(title) \(name): actual \(actual), expected \(expected)")
            print("TRACE: \(title) \(name) amplitude=\(actual)")
        }
    }
}

@main @MainActor private enum GuestPersistedMixerHarness {
    static func producer(_ studio: PersistedGuestStudio, lease: GuestReceiveLease) -> Task<Void, Error> {
        let controller = studio.controller, mixer = studio.mixer
        let mapping = UUID(), local = AudioChannelID.application(bundleID: "fixture.guest-mixer-independent-1000")
        return Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock(), started = clock.now
            let sourceStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let base = sourceStart + 0.08
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                      channels: 2, interleaved: false)!
            var index = 0
            while !Task.isCancelled {
                try await clock.sleep(until: started.advanced(by: .milliseconds(index * 10)))
                // A scheduling stall drops stale source intervals instead of
                // sending a burst or inventing a different source clock.
                index = max(index, Int((CMClockGetTime(CMClockGetHostTimeClock()).seconds - sourceStart) * 100))
                let offset = Double(index) / 100
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
                pcm.frameLength = 480
                for frame in 0..<480 {
                    let value = Float(sin((offset + Double(frame) / 48_000) * 2 * .pi * 2_000)) * 0.25
                    pcm.floatChannelData![0][frame] = value; pcm.floatChannelData![1][frame] = value
                }
                controller.receiveGuestAudio(.init(lease: lease, pcm: pcm,
                    pts: CMTime(seconds: base + offset, preferredTimescale: 48_000),
                    duration: CMTime(value: 480, timescale: 48_000),
                    mappingGeneration: mapping, clockQuality: .senderReportAligned))
                mixer.enqueue(local, try ProgramRecordingFixtures.audio(at: offset, timestampBase: base,
                                                                        constantTone: true, amplitude: 0.2))
                index += 1
                precondition(index < 1_500, "Fixture producer has a bounded lifetime")
            }
        }
    }
    static func stop(_ producer: Task<Void, Error>) async {
        producer.cancel()
        do { try await producer.value } catch is CancellationError {} catch { preconditionFailure("Synthetic producer failed") }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-persisted-guest-\(UUID().uuidString)")
        try DesktopStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slot = UUID(), first = GuestReceiveLease(slot: slot, peerID: UUID(), negotiation: UUID(), generation: 1)
        let guest = AudioMixEngine.guestChannelID(for: first)
        var saved = StreamSettings.default
        saved.micVolume = 0; saved.audioInputs = []
        saved.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30)
        saved.mixer.channelVolumes[guest.label] = 0.4
        saved.mixer.channelMutes[guest.label] = true
        saved.mixer.soloedChannels.insert(guest.label)
        saved.mixer.channelAuxSends[guest.label] = 0.6
        DesktopSettingsStore(directory: directory).saveNonSecret(saved)

        let studio = PersistedGuestStudio(directory: directory)
        precondition(studio.session.activeSettings.mixer == saved.mixer, "Actual settings document must reload")
        // An unregistered source document and a fader label confer no authority.
        studio.scenes.addSource(.init(name: "Unregistered Guest", payload: .guest(.init(slotID: UUID(), role: .camera))))
        precondition(studio.controller.registeredGuestAudioChannel(slot: slot) == nil)
        let admitted = await studio.controller.registerGuestMedia(first, name: "Saved Guest")
        precondition(admitted)
        precondition(studio.controller.registeredGuestAudioChannel(slot: slot) == guest)
        try await Task.sleep(for: .milliseconds(30))
        await studio.run()
        let firstProducer = producer(studio, lease: first)
        precondition(studio.controller.setGuestMediaRouting(first, programAllowed: false, monitorAllowed: true))
        try await studio.measure("restored muted backstage", guestProgram: 0, guestMonitor: 0, guestAux: 0, localMonitor: 0)
        precondition(studio.controller.setGuestMediaRouting(first, programAllowed: true, monitorAllowed: true))
        // Aux is the existing independent pre-fader send; a closed Program
        // gate always blocks it, while an authorized muted fader preserves it.
        try await studio.measure("restored muted Program", guestProgram: 0, guestMonitor: 0, guestAux: 0.15, localMonitor: 0)
        // No guest mixer command has registered this label. A real published
        // SettingsSession edit must therefore find the admitted channel itself.
        var unmuted = studio.session.activeSettings.mixer
        unmuted.channelMutes[guest.label] = nil
        studio.session.persistMixer(unmuted)
        try await studio.awaitPublishedMixer(unmuted)
        try await studio.measure("saved nonunity solo and aux", guestProgram: 0.1, guestMonitor: 0.1, guestAux: 0.15, localMonitor: 0)

        // This write bypasses channel command registration. The admitted guest
        // discovered during refresh must already be in the dispatcher's map.
        var external = studio.session.activeSettings.mixer
        external.channelVolumes[guest.label] = 0.2
        external.channelAuxSends[guest.label] = 0.8
        studio.session.persistMixer(external)
        try await studio.awaitPublishedMixer(external)
        try await studio.measure("external applied mixer document", guestProgram: 0.05, guestMonitor: 0.05, guestAux: 0.2, localMonitor: 0)
        studio.command(.setChannelMuted(guest, true))
        try await studio.measure("dispatcher live mute", guestProgram: 0, guestMonitor: 0, guestAux: 0.2, localMonitor: 0)
        studio.command(.setChannelMuted(guest, false))
        studio.command(.setChannelVolume(guest, 0.7))
        studio.command(.setChannelSolo(guest, false))
        studio.command(.setChannelAuxSend(guest, 0.3))
        try await studio.measure("dispatcher live mixer controls", guestProgram: 0.175, guestMonitor: 0.175, guestAux: 0.075, localMonitor: 0.2)
        precondition(studio.controller.setGuestMediaRouting(first, programAllowed: false, monitorAllowed: true))
        try await studio.measure("independent private monitor", guestProgram: 0, guestMonitor: 0.175, guestAux: 0, localMonitor: 0.2)
        await stop(firstProducer)
        studio.controller.removeGuestMedia(first)
        let rejoined = GuestReceiveLease(slot: slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        let rejoinAdmitted = await studio.controller.registerGuestMedia(rejoined, name: "Rejoined Guest")
        precondition(rejoinAdmitted)
        let nextProducer = producer(studio, lease: rejoined)
        precondition(studio.controller.setGuestMediaRouting(rejoined, programAllowed: true, monitorAllowed: true))
        try await studio.measure("new lease retains live settings", guestProgram: 0.175, guestMonitor: 0.175, guestAux: 0.075, localMonitor: 0.2)
        await stop(nextProducer)
        studio.session.flushPendingWrites()
        let persisted = DesktopSettingsStore(directory: directory).load()
        precondition(persisted.mixer == studio.session.activeSettings.mixer, "Dispatcher edits must reach actual settings persistence")
        await studio.close()

        let reopened = PersistedGuestStudio(directory: directory)
        precondition(reopened.session.activeSettings.mixer == persisted.mixer)
        let fresh = GuestReceiveLease(slot: slot, peerID: UUID(), negotiation: UUID(), generation: 1)
        let freshAdmitted = await reopened.controller.registerGuestMedia(fresh, name: "Reopened Guest")
        precondition(freshAdmitted)
        await reopened.run()
        let finalProducer = producer(reopened, lease: fresh)
        precondition(reopened.controller.setGuestMediaRouting(fresh, programAllowed: true, monitorAllowed: true))
        try await reopened.measure("fresh runtime reload", guestProgram: 0.175, guestMonitor: 0.175, guestAux: 0.075, localMonitor: 0.2)
        await stop(finalProducer)
        await reopened.close()
        print("PASS: actual persisted SettingsSession and dispatcher restore guest mute/nonunity gain/solo/aux before admission; real PCM Program/monitor/aux, external settings edits, lease replacement and fresh runtime reload qualified")
        print("Scope: synthetic local PCM and native runtime routing only; no receiver, Program video/ISO encode, mix-minus, provider, TURN or physical device qualification")
    }
}
