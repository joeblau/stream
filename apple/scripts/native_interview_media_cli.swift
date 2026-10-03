import AVFoundation
import CoreMedia
import Darwin
import Foundation
import StreamCore

// Standalone validation entrypoint only. No shipping controller, publisher,
// capture devices, Keychain or user project is constructed here.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}
private struct InterviewMediaConfiguration: Decodable {
    let serviceURL: URL, operatorToken: String, turnURL: String, turnUsername: String, turnCredential: String
}
private struct OwnedLocalRelayService: NativeInterviewService {
    let client: NativeInterviewServiceClient
    let configuration: NativeInterviewConfiguration
    let ownedRelay: NativeInterviewRelayConfiguration
    func createRoom() async throws -> NativeInterviewCreatedRoom { try await client.createRoom() }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite { try await client.createInvite(room: room) }
    func endRoom(_ room: UUID) async throws { try await client.endRoom(room) }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport {
        try await client.connect(room: room, host: host)
    }
    func shutdown() async { await client.shutdown() }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        // Explicit local TURN override; all service control remains the real
        // Worker. This cannot qualify the deployed Cloudflare TURN broker.
        guard host.expires > Date(), ownedRelay.expires > Date() else { throw NativeInterviewError.expired }
        return ownedRelay
    }
}
private final class InterviewCLIInput: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var pending = Data(), closed = false
    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream; continuation = pair.continuation
    }
    func receive(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard !bytes.isEmpty, pending.count + bytes.count <= 16_384 else { closeLocked(); return }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending.prefix(upTo: newline)); pending.removeSubrange(...newline)
            guard !line.isEmpty, line.count <= 4_096 else { closeLocked(); return }
            if case .dropped = continuation.yield(line) { closeLocked(); return }
        }
    }
    func close() { lock.lock(); closeLocked(); lock.unlock() }
    private func closeLocked() { closed = true; pending.removeAll(); continuation.finish() }
}
private final class InterviewCLIOutput: @unchecked Sendable {
    private let lock = NSLock(), queue = DispatchQueue(label: "stream.interview.fixture.output")
    private var pending: [Data] = [], bytes = 0, working = false, failed = false
    private let failure: @Sendable () -> Void
    init(failure: @escaping @Sendable () -> Void) { self.failure = failure }
    @discardableResult func emit(_ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object), data.count <= 16_384 else { return false }
        data.append(10); lock.lock()
        guard !failed, pending.count < 64, bytes + data.count <= 65_536 else {
            let notify = !failed; failed = true; lock.unlock(); if notify { failure() }; return false
        }
        pending.append(data); bytes += data.count
        let start = !working; working = true; lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }; return true
    }
    private func drain() {
        while true {
            lock.lock(); guard !pending.isEmpty, !failed else { working = false; lock.unlock(); return }
            let data = pending.removeFirst(); bytes -= data.count; lock.unlock()
            let success = data.withUnsafeBytes { buffer in
                var offset = 0
                let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                while offset < buffer.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                    let written = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 { offset += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                    var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                }
                return true
            }
            if !success { lock.lock(); failed = true; lock.unlock(); failure(); return }
        }
    }
    func flushed() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
private final class InterviewSinkProbe: @unchecked Sendable {
    private struct Role {
        var count = 0, samples = 0
        var pts = 0.0, duration = 0.0
        var rgb: [Int] = [], rms: [Double] = [], mapping: UUID?
    }
    private let lock = NSLock()
    private var lease: GuestReceiveLease?
    private var roles = [Role(), Role(), Role()]
    func begin(_ lease: GuestReceiveLease) { lock.lock(); self.lease = lease; roles = [Role(), Role(), Role()]; lock.unlock() }
    func video(_ frame: GuestVideoFrame) {
        lock.lock(); defer { lock.unlock() }; guard lease == frame.lease else { return }
        let pixels = frame.pixels
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let pointer = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let index = CVPixelBufferGetBytesPerRow(pixels) * (height / 2) + width / 2 * 4
        let role = Int(frame.role.rawValue)
        roles[role].count += 1; roles[role].pts = frame.pts.seconds
        roles[role].rgb = [Int(pointer[index + 2]), Int(pointer[index + 1]), Int(pointer[index])]
        roles[role].mapping = frame.mappingGeneration
    }
    func audio(_ frame: GuestAudioFrame) {
        lock.lock(); defer { lock.unlock() }; guard lease == frame.lease else { return }
        let count = Int(frame.pcm.frameLength)
        let rms = (0..<2).map { side in
            let samples = frame.pcm.floatChannelData![side]
            return sqrt((0..<count).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(count))
        }
        roles[2].count += 1; roles[2].samples += count; roles[2].pts = frame.pts.seconds
        roles[2].duration = frame.duration.seconds; roles[2].rms = rms; roles[2].mapping = frame.mappingGeneration
    }
    func snapshot() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }; guard let lease else { return nil }
        return ["type": "accepted", "generation": lease.generation, "slot": lease.slot.uuidString.lowercased(),
                "peer": lease.peerID.uuidString.lowercased(), "negotiation": lease.negotiation.uuidString.lowercased(),
                "roles": roles.enumerated().map { index, role -> [String: Any] in
                    ["role": ["camera", "screen", "audio"][index], "count": role.count, "samples": role.samples,
                     "pts": role.pts, "duration": role.duration, "rgb": role.rgb, "rms": role.rms,
                     "mapping": role.mapping.map { $0.uuidString.lowercased() } ?? "", "clockQuality": "senderReportAligned"]
                }]
    }
}
@main @MainActor private enum NativeInterviewMediaCLI {
    static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        let input = InterviewCLIInput(), output = InterviewCLIOutput { input.close() }
        do {
            guard CommandLine.arguments.count == 2 else { throw NativeInterviewError.configuration }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= 16_384,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o077 == 0,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw NativeInterviewError.configuration }
            let owned = try JSONDecoder().decode(InterviewMediaConfiguration.self, from: Data(contentsOf: url))
            let configuration = try NativeInterviewConfiguration(serviceURL: owned.serviceURL,
                allowedOrigin: owned.serviceURL, allowLoopbackHTTPForValidation: true)
            let token = try NativeInterviewSecret(owned.operatorToken)
            let client = NativeInterviewServiceClient(configuration: configuration, credential: { token })
            let relay = NativeInterviewRelayConfiguration(servers: [.init(urls: [owned.turnURL], username: owned.turnUsername,
                credential: try .init(owned.turnCredential))], expires: Date().addingTimeInterval(120), refreshAt: Date().addingTimeInterval(100))
            let service = OwnedLocalRelayService(client: client, configuration: configuration, ownedRelay: relay)
            let store = GuestVideoFrameStore(), audio = AudioMixEngine(), probe = InterviewSinkProbe()
            await audio.run()
            let factory = NativeInterviewReceiverFactory { context in
                guard await audio.registerGuest(context.receive), store.register(context.receive) else { throw NativeInterviewError.changed }
                probe.begin(context.receive)
                return NativeGuestMediaSink(registered: context.receive, video: store, audio: audio,
                    acceptedVideo: probe.video, acceptedAudio: probe.audio)
            }
            var highwater: UInt64 = 0
            let session = NativeInterviewSession(service: service, factory: factory, nextGeneration: {
                guard highwater < UInt64.max else { return nil }; highwater += 1; return highwater
            })
            var terminal = false
            let poll = Task {
                while !Task.isCancelled && !terminal {
                    let value = session.snapshot
                    var state: [String: Any] = ["type": "state", "phase": value.phase.rawValue,
                        "failure": value.failure.map { $0.rawValue } ?? "", "members": value.members.map {
                            ["id": $0.id.uuidString.lowercased(), "membership": $0.membership.rawValue,
                             "media": $0.media.rawValue, "approved": $0.screenApproved, "sharing": $0.screenSharing] as [String: Any]
                        }]
                    if let pair = factory.selectedICEPair {
                        state["transport"] = ["local": pair.local.label, "remote": pair.remote.label, "udp": pair.udp]
                    }
                    _ = output.emit(state)
                    if let accepted = probe.snapshot() { _ = output.emit(accepted) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let lifetime = Task { try? await Task.sleep(for: .seconds(90)); input.close() }
            defer {
                terminal = true; poll.cancel(); lifetime.cancel(); input.close()
                FileHandle.standardInput.readabilityHandler = nil
                session.shutdown(); factory.retire(); store.retire(); audio.retireGuestAdmissions()
            }
            FileHandle.standardInput.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; input.close() }
                else { input.receive(data) }
            }
            commandLoop: for await line in input.stream {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = object["type"] as? String else { throw NativeInterviewError.malformed }
                let guest = (object["id"] as? String).flatMap(UUID.init(uuidString:))
                switch command {
                case "create":
                    try await session.create()
                    guard let room = session.snapshot.room else { throw NativeInterviewError.changed }
                    let invite = try session.guestInvite(), privateURL = try invite.guestURL(configuration: configuration, room: room)
                    // PRIVATE IPC only. The Node parent consumes this capability
                    // without logging stdout, SDP, config or invitation URLs.
                    _ = output.emit(["type": "private-invite", "url": privateURL.absoluteString])
                    try await session.connect()
                case "admit": guard let guest, session.admit(guest) else { throw NativeInterviewError.changed }
                case "approval": guard let guest, let approved = object["approved"] as? Bool,
                    session.approveScreen(approved, guest: guest) else { throw NativeInterviewError.changed }
                case "rejoin": session.disconnectForRejoin(); try await session.connect()
                case "remove": guard let guest, session.remove(guest) else { throw NativeInterviewError.changed }
                case "end": session.end()
                case "stop": break commandLoop
                default: throw NativeInterviewError.malformed
                }
            }
            terminal = true; poll.cancel(); lifetime.cancel(); input.close()
            FileHandle.standardInput.readabilityHandler = nil
            session.shutdown(); factory.retire(); store.retire(); audio.retireGuestAdmissions(); await audio.stop()
            await service.shutdown()
            _ = output.emit(["type": "stopped"]); await output.flushed()
        } catch {
            input.close(); FileHandle.standardInput.readabilityHandler = nil
            _ = output.emit(["type": "error", "reason": (error as? NativeInterviewError ?? .transport).rawValue])
            await output.flushed(); Darwin.exit(1)
        }
    }
}
