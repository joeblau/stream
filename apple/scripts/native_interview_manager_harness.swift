import AppKit
import AVFoundation
import CoreMedia
import Foundation
import StreamCore
import SwiftUI

private enum ManagerFixtureError: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ManagerFixtureError.failed(message) }
}
private func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}
private func trace(_ message: String) { print("TRACE: \(message)") }
private extension NSLock {
    func fixtureLocked<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

/// Actual Worker socket, with an explicit test-only delivery boundary. Every
/// message is ACKed before a withheld membership receipt. No receipt is made up.
private final class ManagerReceiptSocket: NativeInterviewSocketTransport, @unchecked Sendable {
    let actual: any NativeInterviewSocketTransport
    private let lock = NSLock()
    private var withheld: [String] = [], released: [String] = []
    private var holding = false, suppressing = false, captured = 0
    init(_ actual: any NativeInterviewSocketTransport) { self.actual = actual }
    var closeCode: Int? { actual.closeCode }
    func send(_ text: String, acknowledgment: Bool) -> Bool { actual.send(text, acknowledgment: acknowledgment) }
    func close() { actual.close() }
    func hold(_ enabled: Bool, suppress: Bool = false) {
        lock.lock(); holding = enabled; suppressing = suppress; lock.unlock()
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return captured }
    func releaseNext() throws {
        try lock.fixtureLocked {
            try require(!withheld.isEmpty, "No actual membership receipt to release")
            released.append(withheld.removeFirst())
        }
        try wake()
    }
    func receive() async throws -> String {
        while true {
            let released: String? = lock.fixtureLocked {
                if !self.released.isEmpty { return self.released.removeFirst() }
                return !holding && !withheld.isEmpty ? withheld.removeFirst() : nil
            }
            if let released { return released }
            let text = try await actual.receive()
            let object = try NativeInterviewWire.object(Data(text.utf8))
            let (delay, discard) = lock.fixtureLocked { (holding && object["type"] as? String == "admitted", suppressing) }
            if !delay { return text }
            let delivery = try NativeInterviewWire.number(object["delivery"])
            try require(actual.send(try json(["type": "ack", "delivery": Int64(delivery)]), acknowledgment: true),
                        "Actual withheld receipt ACK failed")
            lock.fixtureLocked {
                captured += 1
                if !discard { precondition(withheld.count < 32); withheld.append(text) }
            }
        }
    }
    // The shipping session's receive is already awaiting the actual socket.
    // A real status response wakes it after the explicit release boundary.
    func wake() throws { try require(send(try json(["type": "status", "program": false, "recording": false]), acknowledgment: false), "Wake not queued") }
}
private actor ManagerService: NativeInterviewService {
    let client: NativeInterviewServiceClient
    let configuration: NativeInterviewConfiguration
    private(set) var socket: ManagerReceiptSocket?
    init(_ client: NativeInterviewServiceClient, configuration: NativeInterviewConfiguration) {
        self.client = client; self.configuration = configuration
    }
    func createRoom() async throws -> NativeInterviewCreatedRoom { try await client.createRoom() }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite { try await client.createInvite(room: room) }
    func endRoom(_ room: UUID) async throws { try await client.endRoom(room) }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport {
        let value = ManagerReceiptSocket(try await client.connect(room: room, host: host)); socket = value; return value
    }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        // Control-authority evidence only. The separate Chrome/Coturn fixture
        // qualifies actual SDK decoding and relay traversal.
        .init(servers: [.init(urls: ["turn:127.0.0.1:3478?transport=udp"], username: "fixture-manager",
                             credential: try .init("synthetic-no-running-turn-server"))],
              expires: Date().addingTimeInterval(600), refreshAt: Date().addingTimeInterval(480))
    }
    func shutdown() async { await client.shutdown() }
}
private struct ManagerGuestReceipt: Sendable {
    let type: String, kind: String?, payload: String?
    let from: UUID?, generation: UUID?
}
private actor ManagerGuest {
    let socket: any NativeInterviewSocketTransport
    private var task: Task<Void, Never>?
    private var receipts: [ManagerGuestReceipt] = []
    init(socket: any NativeInterviewSocketTransport) { self.socket = socket }
    func start() throws {
        try require(socket.send(try json(["type": "hello", "name": "Owned synthetic manager guest"]), acknowledgment: false), "Guest hello failed")
        task = Task { [weak self, socket] in
            while !Task.isCancelled {
                do { let value = try await socket.receive(); guard let self else { return }; try await self.received(value) }
                catch { return }
            }
        }
    }
    private func received(_ text: String) throws {
        let object = try NativeInterviewWire.object(Data(text.utf8))
        let delivery = try NativeInterviewWire.number(object["delivery"])
        try require(socket.send(try json(["type": "ack", "delivery": Int64(delivery)]), acknowledgment: true), "Guest ACK failed")
        precondition(receipts.count < 256)
        receipts.append(.init(type: object["type"] as? String ?? "", kind: object["kind"] as? String,
            payload: object["payload"] as? String,
            from: (object["from"] as? String).flatMap(UUID.init(uuidString:)),
            generation: (object["generation"] as? String).flatMap(UUID.init(uuidString:))))
    }
    var count: Int { receipts.count }
    func nextOffer(since index: Int = 0) async throws -> ManagerGuestReceipt {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let value = receipts.dropFirst(index).first(where: { $0.type == "signal" && $0.kind == "offer" }) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ManagerFixtureError.failed("Missing actual Worker offer")
    }
    func answer(_ offer: ManagerGuestReceipt) throws {
        guard let payload = offer.payload, let host = offer.from, let generation = offer.generation else { throw ManagerFixtureError.failed("Missing actual offer identity") }
        let negotiation = try NativeInterviewWire.id(NativeInterviewWire.object(Data(payload.utf8))["negotiation"])
        let envelope = try json(["negotiation": negotiation.uuidString.lowercased(),
                                 "description": ["type": "answer", "sdp": "owned synthetic control-boundary answer"]])
        try require(socket.send(try json(["type": "signal", "to": host.uuidString.lowercased(),
            "targetGeneration": generation.uuidString.lowercased(), "kind": "answer", "payload": envelope]), acknowledgment: false), "Guest answer failed")
    }
    func stop() { task?.cancel(); socket.close() }
}

/// Controlled host boundary, with the shipping registered sink and actual
/// adapter event bridge. It does not claim RTP transport or native decoding.
@MainActor private final class ManagerHost: NativeInterviewMediaHost {
    let context: NativeInterviewPeerLease, sink: NativeGuestMediaSink
    let events: @Sendable (NativeInterviewMediaEvent) -> Bool
    let callbacks: NativeInterviewReceiverEvents
    let mapping = UUID()
    private(set) var started = false, retired = false
    init(context: NativeInterviewPeerLease, sink: NativeGuestMediaSink,
         events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) throws {
        self.context = context; self.sink = sink; self.events = events
        callbacks = .init(sink: sink, media: try .init(audio: "audio", camera: "camera", screen: "screen"), events: events)
    }
    func startHost() throws {
        started = true
        _ = events(.offer(sdp: "owned synthetic control-boundary offer", media: try .init(audio: "audio", camera: "camera", screen: "screen")))
    }
    func acceptAnswer(_ sdp: String) throws { _ = events(.ready) }
    func acceptCandidate(_ value: String, mid: String) throws {}
    func approveScreen(_ approved: Bool) -> Bool {
        guard !retired, let intent = callbacks.beginApproval(approved) else { return false }
        return callbacks.finishApproval(approved, intent: intent)
    }
    func screenSharing(_ sharing: Bool) throws {
        callbacks.receive("control", try json(["sharing": sharing]), "")
    }
    func controlClosed() { callbacks.receive("control-closed", "", "") }
    func retire() { guard !retired else { return }; retired = true; callbacks.close() }
    @discardableResult func paint(_ role: GuestReceiveRole, color: UInt32) throws -> CMTime {
        var pixel: CVPixelBuffer?
        try require(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, "Synthetic pixel allocation failed")
        let pixels = pixel!; CVPixelBufferLockBaseAddress(pixels, [])
        for y in 0..<72 {
            let row = CVPixelBufferGetBaseAddress(pixels)!.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<128 { row[x] = color }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        try require(sink.receive(.init(lease: context.receive, role: role, pixels: pixels, pts: pts,
            duration: CMTime(value: 1, timescale: 30), mappingGeneration: mapping, clockQuality: .senderReportAligned)), "Shipping sink rejected current controlled video")
        return pts
    }
}
@MainActor private final class ManagerHostFactory: NativeInterviewMediaHostFactory {
    let makeSink: NativeInterviewReceiverFactory.SinkFactory
    private(set) var hosts: [ManagerHost] = []
    private var closed = false
    init(_ makeSink: @escaping NativeInterviewReceiverFactory.SinkFactory) { self.makeSink = makeSink }
    func makeHost(context: NativeInterviewPeerLease, relay: NativeInterviewRelayConfiguration,
                  events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) async throws -> any NativeInterviewMediaHost {
        let sink = try await makeSink(context)
        guard !closed, !Task.isCancelled else { sink.close(); throw NativeInterviewError.changed }
        let value = try ManagerHost(context: context, sink: sink, events: events); hosts.append(value); return value
    }
    func shutdown() { closed = true; hosts.forEach { $0.retire() } }
}
private final class ManagerPCMProbe: @unchecked Sendable {
    struct Packet { let pts: Double; let samples: [Float] }
    private let lock = NSLock(); private var packets: [Packet] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let data = sample.dataBuffer else { preconditionFailure("Actual mixer PCM missing") }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
        precondition(values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) } == noErr)
        lock.lock(); defer { lock.unlock() }; precondition(packets.count < 2_000)
        packets.append(.init(pts: sample.presentationTimeStamp.seconds, samples: values))
    }
    func amplitude(from start: Double, to end: Double) -> Double {
        lock.lock(); let values = packets; lock.unlock()
        var real = 0.0, imaginary = 0.0, count = 0
        for packet in values {
            for index in 0..<(packet.samples.count / 2) {
                let time = packet.pts + Double(index) / 48_000
                guard time >= start && time < end else { continue }
                let phase = (time - start) * 2 * .pi * 2_000
                real += Double(packet.samples[index * 2]) * cos(phase)
                imaginary += Double(packet.samples[index * 2]) * sin(phase); count += 1
            }
        }
        precondition(count > 8_000, "Actual mixer tap must cover a bounded measured window")
        return 2 * hypot(real, imaginary) / Double(count)
    }
}
private final class ManagerActorHold: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
}
private extension AudioMixEngine {
    func fixtureHoldActor(_ hold: ManagerActorHold) {
        hold.entered.signal(); precondition(hold.release.wait(timeout: .now() + 4) == .success, "Owned actual actor hold exceeded four seconds")
    }
}
@MainActor private final class ManagerStudio {
    let mixer = AudioMixEngine(), scenes: SceneStore, preview: PreviewProgramModel
    let controller: StreamController, settings: SettingsSession, recorder: RecordingController, dispatcher: StudioCommandDispatcher
    var client: NativeInterviewServiceClient?, service: ManagerService?, factory: ManagerHostFactory?
    var capturedCredentialProvider: NativeInterviewManager.CredentialProvider?
    var manager: NativeInterviewManager!
    let program = ManagerPCMProbe(), monitor = ManagerPCMProbe()
    private let defaults: UserDefaults, suite = "stream.fixture.interview-manager.\(UUID())"
    init(directory: URL) {
        scenes = SceneStore(directory: directory); preview = .init(selected: scenes.selected)
        controller = .init(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        settings = .init(store: DesktopSettingsStore(directory: directory), controller: controller)
        defaults = UserDefaults(suiteName: suite)!
        recorder = .init(defaults: defaults, defaultDirectory: directory.appendingPathComponent("Recordings"))
        dispatcher = .init(controller: controller, sceneStore: scenes, session: settings, recorder: recorder, previewProgram: preview)
        manager = NativeInterviewManager(controller: controller, serviceFactory: { [weak self] configuration, credential in
            let client = NativeInterviewServiceClient(configuration: configuration, credential: credential)
            let value = ManagerService(client, configuration: configuration)
            self?.client = client; self?.service = value; self?.capturedCredentialProvider = credential; return value
        }, hostFactory: { [weak self] makeSink in
            let value = ManagerHostFactory(makeSink); self?.factory = value
            return .init(factory: value, shutdown: { value.shutdown() })
        })
        dispatcher.bindInterviewManager(manager)
    }
    func command(_ value: NativeInterviewCommand) throws {
        try require(dispatcher.execute(.interview(value)).error == nil, "Actual dispatcher refused \(value.displayName)")
    }
    func close() async {
        manager.shutdown(); controller.retireGuestMedia(); await mixer.stop()
        scenes.flushPendingWrites(); defaults.removePersistentDomain(forName: suite)
    }
    func measure(_ title: String, program expectedProgram: Double, monitor expectedMonitor: Double) async throws {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.12, end = start + 0.25
        try await Task.sleep(for: .milliseconds(450))
        for (name, probe, expected) in [("Program", program, expectedProgram), ("Monitor", monitor, expectedMonitor)] {
            let actual = probe.amplitude(from: start, to: end)
            try require(abs(actual - expected) < 0.012, "\(title) \(name) actual \(actual), expected \(expected)")
            trace("\(title) \(name) amplitude=\(actual)")
        }
    }
}

@MainActor enum InterviewWindowReceipts {
    static var appeared: [ObjectIdentifier: Int] = [:], disappeared: [ObjectIdentifier: Int] = [:]
    static var previewSuppressed: [ObjectIdentifier: Int] = [:]
}
@main @MainActor private enum NativeInterviewManagerHarness {
    static func wait(_ message: String, until: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !until() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(until(), message)
    }
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: actual owned SwiftUI window needs WindowServer"); exit(77) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: actual Worker + shipping manager/controller/dispatcher/mixer + owned SwiftUI window lifecycle"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    static func connectGuest(_ studio: ManagerStudio) async throws -> (ManagerGuest, UUID) {
        let url = try await studio.manager.inviteForSharing()
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let room = UUID(uuidString: parts.queryItems!.first(where: { $0.name == "room" })!.value!)!
        // Only our owned synthetic invite exists in this private local fixture.
        // It is never printed, copied to the clipboard or written to disk.
        let client = studio.client!
        let capability = try NativeInterviewSecret(parts.fragment!)
        let socket = try await client.connect(room: room, host: .init(id: UUID(), expires: studio.manager.state.snapshot.expires!, secret: capability))
        let guest = ManagerGuest(socket: socket); try await guest.start()
        try await wait("Actual Worker lobby missing") { studio.manager.state.snapshot.members.contains { $0.membership == .waiting } }
        return (guest, studio.manager.state.snapshot.members.first!.id)
    }
    static func admit(_ studio: ManagerStudio, guest: ManagerGuest, id: UUID, since cursor: Int = 0) async throws -> ManagerHost {
        try studio.command(.admit(id)); let offer = try await guest.nextOffer(since: cursor); try await guest.answer(offer)
        try await wait("Actual ready lease missing") { studio.manager.currentReadyLease?.receive.peerID == id }
        return studio.factory!.hosts.last!
    }
    static func producer(_ host: ManagerHost) -> Task<Void, Error> {
        let sink = host.sink, lease = host.context.receive, mapping = host.mapping
        return Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock(), started = clock.now
            let source = CMClockGetTime(CMClockGetHostTimeClock()).seconds, base = source + 0.08
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            var index = 0
            while !Task.isCancelled {
                try await clock.sleep(until: started.advanced(by: .milliseconds(index * 10)))
                index = max(index, Int((CMClockGetTime(CMClockGetHostTimeClock()).seconds - source) * 100))
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!; pcm.frameLength = 480
                for frame in 0..<480 {
                    let value = Float(sin((Double(index) / 100 + Double(frame) / 48_000) * 2 * .pi * 2_000)) * 0.25
                    pcm.floatChannelData![0][frame] = value; pcm.floatChannelData![1][frame] = value
                }
                _ = sink.receive(.init(lease: lease, pcm: pcm, pts: CMTime(seconds: base + Double(index) / 100, preferredTimescale: 48_000),
                    duration: CMTime(value: 480, timescale: 48_000), mappingGeneration: mapping, clockQuality: .senderReportAligned))
                index += 1; precondition(index < 2_000, "Owned PCM producer lifetime is bounded")
            }
        }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]),
              let token = ProcessInfo.processInfo.environment["STREAM_NATIVE_INTERVIEW_FIXTURE_TOKEN"], token.hasPrefix("native-fixture-") else {
            throw ManagerFixtureError.failed("Explicit owned local Worker required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-interview-manager-\(UUID())")
        try DesktopStorage.prepare(directory); defer { try? FileManager.default.removeItem(at: directory) }
        var settings = StreamSettings.default; settings.micVolume = 0; settings.audioInputs = []
        DesktopSettingsStore(directory: directory).saveNonSecret(settings)
        let studio = ManagerStudio(directory: directory)
        let configuration = try NativeInterviewConfiguration(serviceURL: url, allowedOrigin: URL(string: "https://interviews.example.test")!, allowLoopbackHTTPForValidation: true)
        let credential = try NativeInterviewSecret(token)
        do {
            try await studio.manager.create(configuration: configuration, credential: try .init("owned-fixture-invalid-operator"))
            throw ManagerFixtureError.failed("Actual Worker accepted invalid operator credential")
        } catch NativeInterviewError.authorization {}
        try require(studio.manager.state.snapshot.phase == .failed && studio.manager.state.snapshot.room == nil,
                    "Failed creation retained a room or invented service state")
        do { _ = try await studio.capturedCredentialProvider!(); throw ManagerFixtureError.failed("Failed creation retained future credential reads") }
        catch NativeInterviewError.closed {}
        try await studio.manager.create(configuration: configuration, credential: credential)
        try await wait("Actual manager welcome missing") { studio.manager.state.snapshot.phase == .connected && !studio.manager.state.busy }
        trace("actual manager room created and host welcome acknowledged")
        let (guest, id) = try await connectGuest(studio)
        var prepared = studio.scenes.createGuestSlot(name: "Prepared Interview Position")!
        prepared.title = "Guest speaker"; prepared.cameraPlaceholder.message = "Waiting for speaker"
        studio.scenes.replaceGuestSlot(prepared)
        let preparedSourceIDs = studio.scenes.sources.compactMap { source -> SourceDefinitionID? in
            if case .guest(let payload) = source.payload, payload.slotID == prepared.id { return source.id }
            return nil
        }
        try require(studio.manager.assignSlot(prepared.id, to: id), "Actual waiting guest could not choose a prepared project slot")
        try require(!studio.dispatcher.canExecute(.interview(.onair(id))), "Waiting guest received a Program command")
        let host = try await admit(studio, guest: guest, id: id)
        let lease = host.context.receive
        try require(lease.slot == prepared.id && studio.scenes.guestSlots.first?.reconnectPeerID == id,
                    "Actual Worker admission ignored the saved public slot assignment")
        try require(studio.scenes.sources.filter { if case .guest(let p) = $0.payload { return p.slotID == prepared.id }; return false }.map(\.id) == preparedSourceIDs,
                    "Actual Worker admission replaced the prepared source IDs")
        studio.scenes.flushPendingWrites()
        let savedSlots = SceneStore(directory: directory)
        try require(savedSlots.guestSlots == studio.scenes.guestSlots
            && savedSlots.sources.map(\.id) == studio.scenes.sources.map(\.id), "Actual active-room slot document did not reload")
        try require(studio.manager.state.routes[id]?.programAllowed == false, "Admission granted Program")
        let cameraPTS = try host.paint(.camera, color: 0xffe02020)
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .camera, at: cameraPTS, program: false) != nil,
                    "Backstage camera missing from private Preview")
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .camera, at: cameraPTS, program: true) == nil,
                    "Backstage camera leaked into Program")
        let camera = studio.scenes.sources.first { source in
            if case .guest(let guest) = source.payload { return guest.slotID == lease.slot && guest.role == .camera }
            return false
        }
        let screen = studio.scenes.sources.first { source in
            if case .guest(let guest) = source.payload { return guest.slotID == lease.slot && guest.role == .screen }
            return false
        }
        try require(camera != nil && screen != nil && camera!.id != screen!.id, "Independent bound camera/screen sources missing")
        var scene = studio.preview.stagedScene!
        scene.layers.append(.init(name: "Guest Camera", sourceID: camera!.id, payload: camera!.payload, transform: .fullscreen))
        scene.layers.append(.init(name: "Guest Screen", sourceID: screen!.id, payload: screen!.payload,
                                  transform: .init(pipCorner: .bottomRight, scale: 0.5)))
        try require(studio.dispatcher.execute(.updateScene(scene)).error == nil, "Actual dispatcher refused independent framing")
        try require(studio.preview.stagedScene?.layers.suffix(2).map(\.sourceID) == [camera!.id, screen!.id], "Bound identities did not survive Preview edit")

        await studio.mixer.addTap(bus: .program, token: UUID(), capacity: 64, sink: studio.program.receive)
        await studio.mixer.addTap(bus: .monitor, token: UUID(), capacity: 64, sink: studio.monitor.receive)
        await studio.mixer.run(); let pcm = producer(host)
        try await studio.measure("admitted backstage", program: 0, monitor: 0)
        try studio.command(.monitor(id, true)); try await studio.measure("private monitor", program: 0, monitor: 0.25)
        let receiptSocket = await studio.service!.socket!
        receiptSocket.hold(true)
        try studio.command(.onair(id))
        try await wait("Actual stage receipt was not withheld") { receiptSocket.heldCount >= 1 && studio.manager.state.snapshot.members.first?.membership == .onair }
        try require(studio.manager.state.routes[id]?.programAllowed == false, "Roster alone granted new On Air intent")
        try await studio.measure("stage before actual ACK", program: 0, monitor: 0.25)
        receiptSocket.hold(false); try receiptSocket.wake()
        try await wait("Actual stage ACK did not grant local intent") { studio.manager.state.routes[id]?.programAllowed == true }
        try await studio.measure("acknowledged onair", program: 0.25, monitor: 0.25)
        let acknowledgedRevision = studio.manager.state.snapshot.members.first!.membershipRevision
        receiptSocket.hold(true, suppress: true); let beforeRepeat = receiptSocket.heldCount
        try studio.command(.onair(id))
        try require(studio.manager.state.routes[id]?.programAllowed == true
            && studio.manager.state.snapshot.members.first?.membershipRevision == acknowledgedRevision,
            "Repeated no-op/withheld ACK invalidated an already acknowledged intent")
        try await studio.measure("repeated onair no new receipt", program: 0.25, monitor: 0.25)
        try require(receiptSocket.heldCount == beforeRepeat, "Idempotent On Air sent a redundant stage request")
        receiptSocket.hold(false)
        try studio.command(.backstage(id))
        try require(studio.manager.state.routes[id]?.programAllowed == false && studio.manager.state.routes[id]?.monitorAllowed == true,
                    "Synchronous Backstage did not preserve only explicit private Monitor")
        try await studio.measure("backstage keeps private monitor", program: 0, monitor: 0.25)
        try studio.command(.monitor(id, false)); try await studio.measure("backstage no monitor intent", program: 0, monitor: 0)

        try await wait("Actual Backstage receipt missing before reversal") {
            studio.manager.state.snapshot.members.first?.membership == .backstage
        }
        let beforeReversal = receiptSocket.heldCount
        let reversalRevision = studio.manager.state.snapshot.members.first!.membershipRevision
        receiptSocket.hold(true)
        try studio.command(.onair(id))
        try await wait("First actual stage receipt not held") { receiptSocket.heldCount == beforeReversal + 1 }
        try studio.command(.backstage(id))
        try await wait("Reversing actual Backstage receipt not held") { receiptSocket.heldCount == beforeReversal + 2 }
        try studio.command(.onair(id))
        try await wait("Latest actual stage receipt not held") {
            receiptSocket.heldCount == beforeReversal + 3 && studio.manager.state.snapshot.members.first?.membership == .onair
        }
        try receiptSocket.releaseNext()
        try await wait("First old stage receipt not delivered") {
            studio.manager.state.snapshot.members.first!.membershipRevision == reversalRevision + 1
        }
        try await studio.measure("old stage ACK cannot satisfy reversed intent", program: 0, monitor: 0)
        try require(studio.manager.state.routes[id]?.programAllowed == false,
                    "First old stage receipt granted latest reversed intent")
        try receiptSocket.releaseNext()
        try await wait("Reversing Backstage receipt not delivered") {
            studio.manager.state.snapshot.members.first!.membershipRevision == reversalRevision + 2
        }
        try await studio.measure("old Backstage ACK keeps reversed intent closed", program: 0, monitor: 0)
        try receiptSocket.releaseNext()
        try await wait("Latest matching stage receipt did not grant reversed intent") {
            studio.manager.state.routes[id]?.programAllowed == true
        }
        try await studio.measure("latest reversed stage ACK", program: 0.25, monitor: 0)
        receiptSocket.hold(false)
        try studio.command(.backstage(id))
        try await studio.measure("reversal final Backstage", program: 0, monitor: 0)
        trace("actual Worker On Air/Backstage/On Air receipts delivered individually; only latest matching stage ACK grants Program")

        let boundedStart = receiptSocket.heldCount
        let boundedRevision = studio.manager.state.snapshot.members.first!.membershipRevision
        receiptSocket.hold(true)
        for count in 1...32 {
            try studio.command(.onair(id))
            try await wait("Bounded actual stage receipt missing") { receiptSocket.heldCount == boundedStart + count }
            // Stay within the actual Worker's command rate limit while its
            // real receipts remain deliberately held and already ACKed.
            try await Task.sleep(for: .milliseconds(35))
        }
        try require(studio.dispatcher.execute(.interview(.onair(id))).error != nil,
                    "An uncertain membership queue admitted a 33rd request")
        try receiptSocket.releaseNext()
        try await wait("First bounded stage receipt missing") {
            studio.manager.state.snapshot.members.first!.membershipRevision == boundedRevision + 1
        }
        try await studio.measure("bounded queue retains latest ordinal", program: 0, monitor: 0)
        receiptSocket.hold(false); try receiptSocket.wake()
        try await wait("Last bounded stage receipt did not grant its own intent") {
            studio.manager.state.snapshot.members.first!.membershipRevision == boundedRevision + 32
                && studio.manager.state.routes[id]?.programAllowed == true
        }
        try await studio.measure("bounded final stage ACK", program: 0.25, monitor: 0)
        try studio.command(.backstage(id)); try await studio.measure("bounded final Backstage", program: 0, monitor: 0)
        trace("actual Worker holds 32 membership requests; 33rd refused, no ordinal eviction, only final matching receipt opens Program")

        try studio.command(.approveScreen(id, true)); try host.screenSharing(true)
        try await wait("Screen sharing metadata missing") { studio.manager.state.snapshot.members.first?.screenSharing == true }
        let screenPTS = try host.paint(.screen, color: 0xff20e020)
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .screen, at: screenPTS, program: false) != nil,
                    "Actual adapter bridge approval did not open the controller screen gate")
        try studio.command(.approveScreen(id, false))
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .screen, at: screenPTS, program: false) == nil,
                    "Screen revoke retained cached private screen")
        try studio.command(.approveScreen(id, true)); try host.screenSharing(true)
        let secondScreen = try host.paint(.screen, color: 0xff20e020)
        host.controlClosed()
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .screen, at: secondScreen, program: false) == nil,
                    "Actual adapter control closure did not revoke screen synchronously")
        try await wait("Control closure metadata missing") { studio.manager.state.snapshot.members.first?.screenApproved == false }
        try require(studio.dispatcher.execute(.interview(.approveScreen(id, true))).error != nil,
                    "Approval restored a closed control channel")
        try host.screenSharing(true)
        try require(studio.controller.guestVideoFrames.pixels(slot: lease.slot, role: .screen, at: secondScreen, program: false) == nil,
                    "Late sharing restored a closed control channel")
        _ = try host.paint(.camera, color: 0xffe02020)
        trace("real adapter event bridge: approval opens screen; revoke/control-close synchronously clear screen while camera/audio remain independent")

        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 500, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: NativeInterviewView(manager: studio.manager)
            .environmentObject(studio.dispatcher).environmentObject(studio.scenes).environmentObject(studio.preview))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100)); window.contentView = nil; window.close()
        try require(studio.manager.currentReadyLease == host.context && !host.retired, "Closing actual Guests view retired a runtime-owned peer")
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        try require(studio.manager.currentReadyLease == host.context && studio.manager.state.snapshot.phase == .connected,
                    "Reopening Guests replaced or reconnected the runtime-owned session")
        window.contentView = nil; window.close()
        trace("actual NSWindow/NativeInterviewView close-reopen retained exact full ready lease without service/media replay")

        let actions = studio.dispatcher.paletteActions(scenes: studio.scenes.scenes, sources: studio.scenes.sources, stagedScene: studio.preview.stagedScene)
        let actionID = "interview.guest.\(id.uuidString.lowercased()).onair"
        guard let action = actions.first(where: { $0.id == actionID }),
              case .interview(.onair(let commandGuest)) = action.command, commandGuest == id else {
            throw ManagerFixtureError.failed("Palette/adapter stable command did not resolve")
        }
        let firstGeneration = lease.generation
        pcm.cancel(); _ = try? await pcm.value
        try studio.command(.disconnect)
        try require(studio.manager.currentReadyLease == nil && studio.controller.registeredGuestAudioChannel(slot: lease.slot) == nil,
                    "Disconnect left old lease authority")
        try studio.command(.rejoin)
        try await wait("Actual host rejoin did not connect") { studio.manager.state.snapshot.phase == .connected && !studio.manager.state.busy }
        try await wait("Rejoin did not return guest to waiting") { studio.manager.state.snapshot.members.first?.membership == .waiting }
        let cursor = await guest.count
        let rejoined = try await admit(studio, guest: guest, id: id, since: cursor)
        try require(rejoined.context.receive.slot == lease.slot && rejoined.context.receive.generation > firstGeneration
            && rejoined.context.hostGeneration != host.context.hostGeneration && !studio.manager.state.routes[id]!.programAllowed,
                    "Rejoin did not keep stable identity and replace authority privately")
        let secondGeneration = rejoined.context.receive.generation
        try studio.command(.end)
        do { _ = try await studio.capturedCredentialProvider!(); throw ManagerFixtureError.failed("End retained future operator credential reads") }
        catch NativeInterviewError.closed {}
        try require(studio.manager.currentReadyLease == nil, "End did not close local authority before its HTTP/WS acknowledgment")
        try await wait("Actual end acknowledgment missing") { studio.manager.state.snapshot.phase == .ended }
        await guest.stop()
        try await studio.manager.create(configuration: configuration, credential: credential)
        try await wait("Second room host welcome missing") { studio.manager.state.snapshot.phase == .connected && !studio.manager.state.busy }
        let (secondGuest, secondID) = try await connectGuest(studio)
        let secondHost = try await admit(studio, guest: secondGuest, id: secondID)
        try require(secondHost.context.receive.generation > secondGeneration, "Second room reused runtime receive high-water")
        trace("actual two rooms plus host rejoin use stable per-invite sources and monotonically increasing full-lease generations")
        try studio.command(.remove(secondID))
        try require(studio.controller.registeredGuestAudioChannel(slot: secondHost.context.receive.slot) == nil, "Remove did not revoke controller channel synchronously")
        try await wait("Actual revoked guest not removed") { studio.manager.state.snapshot.members.isEmpty }
        try require(!studio.dispatcher.canExecute(.interview(.onair(secondID))), "Deleted guest command remained available")

        // Hold the real mixer actor, then remove while the controller's actual
        // registerGuest await is occupied. No synthetic mirror of admission.
        let (pendingGuest, pendingID) = try await connectGuest(studio)
        let hold = ManagerActorHold()
        let held = Task { await studio.mixer.fixtureHoldActor(hold) }
        try await Task.detached { try require(hold.entered.wait(timeout: .now() + 1) == .success, "Real mixer actor hold did not enter") }.value
        try studio.command(.admit(pendingID))
        try await wait("Actual pending sink did not occupy admission") { studio.manager.occupiedSinkCount == 1 }
        let hostCount = studio.factory!.hosts.count
        try studio.command(.remove(pendingID)); hold.release.signal(); await held.value
        try await wait("Actual late admission did not clean occupied slot") { studio.manager.occupiedSinkCount == 0 }
        try require(studio.factory!.hosts.count == hostCount && studio.manager.currentReadyLease == nil,
                    "Late real actor registration resurrected a removed guest")
        await pendingGuest.stop(); await secondGuest.stop()
        try studio.command(.end); try await wait("Second actual room did not end") { studio.manager.state.snapshot.phase == .ended }
        await studio.close()
        trace("actual held mixer actor + dispatcher Remove rejects late admission, cleans occupancy and allocates no host")
        try await shippingWindowLifecycle(configuration: configuration, credential: credential)
    }

    static func shippingWindowLifecycle(configuration: NativeInterviewConfiguration, credential: NativeInterviewSecret) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-interview-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = StudioProjectCatalog()
        let directory = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: catalog.selectedProjectID, profile: catalog.selectedProfileID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("projects.v1.json"))
        let workspace = StudioWorkspace(root: root), original = workspace.runtime
        GuestFixtureDefaults.value.set(true, forKey: "onboarding.hasCompletedFirstRun")
        try await original.interviews.create(configuration: configuration, credential: credential)
        try await wait("Shipping runtime interview welcome missing") { original.interviews.state.snapshot.phase == .connected }
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1440, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: InterviewShippingApplicationRoot(workspace: workspace))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await wait("Actual shipping MainWindow did not appear") { InterviewWindowReceipts.appeared[ObjectIdentifier(original), default: 0] > 0 }
        let appeared = InterviewWindowReceipts.appeared[ObjectIdentifier(original), default: 0]
        window.contentView = nil; window.close()
        try await wait("Actual shipping MainWindow did not disappear") { InterviewWindowReceipts.disappeared[ObjectIdentifier(original), default: 0] > 0 }
        try require(original.interviews.state.snapshot.phase == .connected, "Window detach disconnected runtime-owned interview")
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await wait("Actual shipping MainWindow did not reopen") { InterviewWindowReceipts.appeared[ObjectIdentifier(original), default: 0] > appeared }
        try require(workspace.runtime === original && original.interviews.state.snapshot.phase == .connected, "Window reopening replayed or replaced interview owner")
        workspace.create(named: "Owned interview replacement")
        await workspace.applyPending()
        let replacement = workspace.runtime
        try require(replacement !== original && original.interviews.state.snapshot.phase == .closed,
                    "Actual runtime replacement did not retire the old session")
        try await replacement.interviews.create(configuration: configuration, credential: credential)
        try await wait("Replacement runtime interview welcome missing") { replacement.interviews.state.snapshot.phase == .connected }
        window.contentView = nil; window.close()
        try await Task.sleep(for: .milliseconds(150))
        try require(replacement.interviews.state.snapshot.phase == .connected, "Old-window disappearance retired replacement interview owner")
        await RecordingTerminationDelegate.finishSession?()
        try require(replacement.interviews.state.snapshot.phase == .closed, "Actual Quit hook did not retire the current interview owner")
        original.providerAccounts.shutdown(); original.localControl.shutdown()
        try require(!original.controller.isPreviewing && !replacement.controller.isPreviewing, "UI fixture allocated device capture")
        trace("actual shipping App root/MainWindow close-reopen preserves owner; profile apply synchronously retires old owner; old view cannot retire replacement")
    }
}
