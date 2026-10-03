import Combine
import Foundation
import Network
import Security

// Native Network/Security framing and server code compile unchanged. This
// deterministic studio double avoids starting capture or publishing output.
@MainActor enum DesktopStorage {
    static var projectDirectory = FileManager.default.temporaryDirectory
    static var machineDirectory: URL { projectDirectory }
}
struct HarnessID: Hashable { var rawValue = UUID() }
/// Real interview snapshot values at the controlled studio boundary. The wire
/// fixture starts no service/media factory and makes no guest routing claim.
struct HarnessGuestRoute {
    var slot: UUID
    var programAllowed = false
    var monitorAllowed = false
}
struct HarnessInterviewState {
    var snapshot = NativeInterviewSnapshot()
    var routes: [UUID: HarnessGuestRoute] = [:]
}
struct HarnessState {
    var stream: StreamSessionState = .idle
    var recording: RecordingSessionState = .idle
    var preview: PreviewSessionState = .idle
    var stagedSceneID: HarnessID?
    var programSceneID: HarnessID?
    var hasPendingStagedEdits = false
    var layerVisibility: [HarnessID: Bool] = [:]
    var directLiveEditing = false
    var interview = HarnessInterviewState()
}
enum StudioCommand { case action(String), pdfGoToPage(UUID, page: Int), addRecordingMarker(String) }
enum StudioCommandError: Error {
    case unavailable(String), invalidTarget(String), invalidValue(String)
    var description: String {
        switch self { case .unavailable(let s), .invalidTarget(let s), .invalidValue(let s): s }
    }
}
struct StudioCommandResult {
    enum Outcome { case success, rejected(StudioCommandError) }
    var outcome: Outcome
}
struct StudioPaletteAction {
    var id: String
    var title: String
    var category = "Scenes"
    var command: StudioCommand?
    var unavailableReason: String?
}
@MainActor final class StudioCommandDispatcher: ObservableObject {
    @Published var state = HarnessState()
    let macros = ShowMacroController()
    var actions: [StudioPaletteAction] = []
    var emitted: [String] = []
    @Published var gain = 0.5
    var valueTargetExists = true
    var marker = "", page = 0
    func controllerTargets() -> [StudioControllerTarget] {
        guard valueTargetExists else { return [] }
        return [.init(id: "audio.microphone.gain", title: "Mic Gain", kind: .value, normalizedValue: gain, unavailableReason: nil, execute: { [weak self] value in self?.gain = value!; return nil })]
    }
    func controllerValueSnapshot() -> [String: Double] { valueTargetExists ? ["audio.microphone.gain": gain] : [:] }
    func controllerMuteSnapshot() -> [String: Bool] { ["audio.microphone.gain": false] }
    func controllerPlaybackSnapshot() -> [String: String] { [:] }
    func controllerProgramVisibility() -> [String: Bool] { [:] }
    func controllerGroupVisibility() -> [String: Bool] { [:] }
    func controllerOverlays() -> [HarnessLayer] { [] }
    func controllerChatSnapshot() -> StudioControlChatState? { nil }
    func catalogueActions() -> [StudioPaletteAction] { actions }
    func execute(_ command: StudioCommand) -> StudioCommandResult {
        switch command {
        case .addRecordingMarker(let text): marker = text; return .init(outcome: .success)
        case .pdfGoToPage(_, let page): self.page = page; return .init(outcome: .success)
        case .action(let id):
            if id == "output.stream.start", state.stream.isActive { return .init(outcome: .rejected(.unavailable("Already active"))) }
            if id.hasPrefix("macro."), let uuid = UUID(uuidString: String(id.dropFirst(6).dropLast(4))) { macros.start(uuid) }
            emitted.append(id)
            return .init(outcome: .success)
        }
    }
}
struct HarnessLayer { var id: HarnessID; var isVisible: Bool }
@MainActor final class MemoryCredentials: StudioControlCredentials {
    var tokens: [UUID: String] = [:]
    var deletionError: OSStatus = errSecSuccess
    func read(_ id: UUID) -> String? { tokens[id] }
    func write(_ token: String, for id: UUID) -> OSStatus { tokens[id] = token; return errSecSuccess }
    func delete(_ id: UUID) -> OSStatus {
        guard deletionError == errSecSuccess else { return deletionError }
        tokens.removeValue(forKey: id); return errSecSuccess
    }
}
private struct WireDeadlineFailure: Error {}

/// The Network callback and deadline may race after cancellation. Exactly one
/// owns the continuation; neither a late callback nor a canceled timer leaks it.
private final class WireOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func watch(_ timer: Task<Void, Never>) {
        let completed = lock.withLock {
            guard continuation != nil else { return true }
            self.timer = timer; return false
        }
        if completed { timer.cancel() }
    }
    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>, Task<Void, Never>?)? in
            guard let continuation else { return nil }
            let timer = self.timer
            self.continuation = nil; self.timer = nil
            return (continuation, timer)
        }
        guard let (continuation, timer) = pending else { return }
        timer?.cancel(); continuation.resume(with: result)
    }
}

@MainActor final class WireClient {
    let connection: NWConnection
    private var buffer = StudioControlFrameBuffer()
    private var frames: [StudioControlResponse] = []
    private(set) var receivedFrameCount = 0
    private var operationPhase = "idle"
    private let timeout: Duration
    init(port: UInt16, timeout: Duration = .seconds(5)) {
        self.timeout = timeout
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
    }
    private func arm<Value>(_ operation: WireOperation<Value>, deadline: ContinuousClock.Instant) {
        let connection = connection
        operation.watch(Task { @MainActor in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            operation.resolve(.failure(WireDeadlineFailure()))
            connection.cancel()
        })
    }
    func write(_ data: Data, deadline: ContinuousClock.Instant? = nil) async throws {
        operationPhase = "write"
        let deadline = deadline ?? .now.advanced(by: timeout)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = WireOperation(continuation)
            arm(operation, deadline: deadline)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { operation.resolve(.failure(error)) } else { operation.resolve(.success(())) }
            })
        }
        guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
    }
    func request(_ request: StudioControlRequest) async throws -> StudioControlResponse {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var data = try JSONEncoder().encode(request); data.append(10)
        do {
            try await write(data, deadline: deadline)
            while true {
                let response = try await read(deadline: deadline)
                if response.id == request.id { return response }
            }
        } catch is WireDeadlineFailure {
            // Never log requests, tokens or response bodies. A bounded phase
            // report distinguishes connect/write/response failures on CI.
            let report = "Local wire deadline: type=\(request.type.rawValue) phase=\(operationPhase) receivedFrames=\(receivedFrameCount) queuedFrames=\(frames.count) connection=\(connection.state)\n"
            try? FileHandle.standardOutput.write(contentsOf: Data(report.utf8))
            throw WireDeadlineFailure()
        }
    }
    func read(deadline: ContinuousClock.Instant? = nil) async throws -> StudioControlResponse {
        operationPhase = "read"
        let deadline = deadline ?? .now.advanced(by: timeout)
        guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
        while frames.isEmpty {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let operation = WireOperation(continuation)
                arm(operation, deadline: deadline)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { operation.resolve(.failure(error)) }
                    else if let data, !data.isEmpty { operation.resolve(.success(data)) }
                    else { operation.resolve(.failure(StudioControlProtocolError(code: "closed", message: complete ? "Closed" : "Empty"))) }
                }
            }
            guard ContinuousClock.now < deadline else { connection.cancel(); throw WireDeadlineFailure() }
            let decoded = try buffer.append(data).map { try JSONDecoder().decode(StudioControlResponse.self, from: $0) }
            receivedFrameCount += decoded.count; frames += decoded
        }
        return frames.removeFirst()
    }
}

/// Actual loopback peers either stay silent or send unrelated responses.
/// Cancellation exercises the real receive callback/deadline race.
private final class QuietWirePeer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var noiseTasks: [Task<Void, Never>] = []
    private var ready = false
    var port: UInt16? { lock.withLock { ready ? listener.port?.rawValue : nil } }
    init(noise: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.lock.withLock { self.ready = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: .global())
            if noise {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                    guard let self, data?.isEmpty == false else { return }
                    let frame = Data("{\"version\":1,\"type\":\"event\",\"id\":\"\(UUID().uuidString)\"}\n".utf8)
                    let task = Task.detached {
                        for _ in 0..<500 {
                            guard !Task.isCancelled else { return }
                            connection.send(content: frame, completion: .contentProcessed { _ in })
                            do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                        }
                    }
                    self.lock.withLock { self.noiseTasks.append(task) }
                }
            }
        }
        listener.start(queue: .global())
    }
    func stop() {
        listener.cancel()
        let tasks = lock.withLock { let old = noiseTasks; noiseTasks.removeAll(); return old }
        for task in tasks { task.cancel() }
        let connections = lock.withLock { let old = self.connections; self.connections.removeAll(); return old }
        for connection in connections { connection.cancel() }
    }
}
private final class BoundedProcessText: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var endOfFileCallbacks = 0
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; precondition(bytes.count + data.count <= 131_072, "External adapter exceeded fixture output bound"); bytes.append(data) }
    func ended() { lock.withLock { endOfFileCallbacks += 1 } }
    var eofCount: Int { lock.withLock { endOfFileCallbacks } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var snapshots: [[String: Any]] { text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
}

@MainActor private final class ExternalSampleProcess {
    let process = Process()
    let output = BoundedProcessText(), errors = BoundedProcessText()
    private let input = Pipe(), stdout = Pipe(), stderr = Pipe()
    init(script: URL, clientID: UUID, token: String, port: UInt16) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", script.path]
        process.standardInput = input; process.standardOutput = stdout; process.standardError = stderr
        let output = output, errors = errors
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; output.ended() }
            else { output.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; errors.ended() }
            else { errors.append(data) }
        }
        try process.run()
        var credential = try JSONSerialization.data(withJSONObject: ["version": 1, "clientID": clientID.uuidString,
            "token": token, "host": "127.0.0.1", "port": Int(port)])
        credential.append(10)
        try input.fileHandleForWriting.write(contentsOf: credential)
        try input.fileHandleForWriting.close()
    }
    func stop() {
        if process.isRunning { process.terminate() }
        stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
    }
    var pipesFinished: Bool { output.eofCount > 0 && errors.eofCount > 0 }
    var pipesRetired: Bool {
        output.eofCount == 1 && errors.eofCount == 1 &&
        stdout.fileHandleForReading.readabilityHandler == nil && stderr.fileHandleForReading.readabilityHandler == nil
    }
}

@main struct StudioLocalControlHarness {
    @MainActor static func progress(_ message: String) {
        // Direct bounded writes stay visible if a later fixture hangs/crashes;
        // process stdout buffering must not hide the last completed boundary.
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
    @MainActor static func waitUntil(_ test: () -> Bool) async {
        for _ in 0..<2000 {
            if test() { return }; try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Local IPC harness timed out")
    }
    @MainActor static func main() async throws {
        progress("Local control fixture: nonresponsive native peer deadline")
        let quiet = try QuietWirePeer()
        defer { quiet.stop() }
        await waitUntil { quiet.port != nil }
        for _ in 0..<3 {
            let client = WireClient(port: quiet.port!, timeout: .milliseconds(100))
            defer { client.connection.cancel() }
            let started = ContinuousClock.now
            do {
                _ = try await client.request(.init(type: .capabilities, id: UUID()))
                preconditionFailure("Nonresponsive peer fabricated a response")
            } catch is WireDeadlineFailure {
                precondition(ContinuousClock.now - started < .seconds(2), "Native fixture deadline was unbounded")
            }
        }
        let noisy = try QuietWirePeer(noise: true)
        defer { noisy.stop() }
        await waitUntil { noisy.port != nil }
        let noisyClient = WireClient(port: noisy.port!, timeout: .milliseconds(300))
        defer { noisyClient.connection.cancel() }
        do {
            _ = try await noisyClient.request(.init(type: .capabilities, id: UUID()))
            preconditionFailure("Unrelated event responses fabricated a matching receipt")
        } catch is WireDeadlineFailure {
            precondition(noisyClient.receivedFrameCount > 1, "Busy peer did not exercise repeated receives")
        }
        noisy.stop()
        progress("PASS: silent and busy unmatched native peers expire at the request deadline; cancellation resolves once and MainActor timers remain responsive")
        progress("Local control fixture: authenticated native socket and adapter permissions")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-local-api-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DesktopStorage.projectDirectory = directory
        let preferencesName = "stream.local-api-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let credentials = MemoryCredentials()
        let pairURL = directory.appendingPathComponent("pairs.json")
        let store = StudioControlPairingStore(url: pairURL, credentials: credentials)
        store.pair(name: "Test Controller")
        let pairing = store.pairing!
        let metadata = try String(contentsOf: pairURL, encoding: .utf8)
        precondition(!metadata.contains(pairing.token), "Credentials never enter JSON metadata")
        let restored = StudioControlPairingStore(url: pairURL, credentials: credentials)
        precondition(restored.token(for: pairing.id) == pairing.token)
        var session = StudioControlSession()
        let handshake = StudioControlRequest(type: .authenticate, id: UUID(), clientID: pairing.id, token: pairing.token)
        precondition(session.authorize(handshake, tokenForClient: store.token) == nil)
        let stale = StudioControlRequest(type: .command, id: UUID(), sessionID: UUID(), commandID: "studio.take")
        precondition(session.validate(stale, clientStillPaired: { _ in true })?.code == "unauthorized")
        var frameBuffer = StudioControlFrameBuffer()
        let incomplete = try frameBuffer.append(Data("{\"a\":".utf8))
        precondition(incomplete.isEmpty)
        let partialFrames = try frameBuffer.append(Data("1}\n{\"b\":2}\n".utf8))
        precondition(partialFrames.count == 2)
        do { _ = try frameBuffer.append(Data(repeating: 32, count: 65537)); preconditionFailure("Oversize frame accepted") }
        catch let error as StudioControlProtocolError { precondition(error.code == "messageSize") }
        let dispatcher = StudioCommandDispatcher()
        let stable = "scene.\(UUID()).select"
        dispatcher.actions = [.init(id: stable, title: "Intro", command: .action(stable)),
                              .init(id: "output.stream.start", title: "Start Stream", command: .action("output.stream.start"))]
        let server = StudioLocalControlServer(defaults: preferences, pairingStore: store, port: 0)
        server.bind(to: dispatcher); server.setEnabled(true)
        defer { server.shutdown() }
        await waitUntil { server.listeningPort != nil }
        let port = server.listeningPort!
        let bad = WireClient(port: port)
        let denied = try await bad.request(.init(type: .authenticate, id: UUID(), clientID: pairing.id, token: String(repeating: "0", count: 64)))
        precondition(denied.error?.code == "unauthorized")
        bad.connection.cancel()
        let incompatible = WireClient(port: port)
        let mismatch = try await incompatible.request(.init(version: 2, type: .authenticate, id: UUID(), clientID: pairing.id, token: pairing.token))
        precondition(mismatch.error?.code == "versionMismatch")
        incompatible.connection.cancel()
        let client = WireClient(port: port)
        let authenticated = try await client.request(handshake)
        let sessionID = authenticated.sessionID!
        precondition(authenticated.snapshot?.projectID == directory.lastPathComponent)
        let capabilityRequest = StudioControlRequest(type: .capabilities, id: UUID(), sessionID: sessionID)
        let discovery = try await client.request(capabilityRequest)
        precondition(discovery.commands?.contains { $0.id == stable && $0.title == "Intro" } == true)
        precondition(discovery.commands?.contains { $0.id == "audio.microphone.gain" && $0.kind == "value" } == true)
        let valueRequest = StudioControlRequest(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", value: 0.8)
        let absolute = try await client.request(valueRequest)
        precondition(absolute.result?.succeeded == true && absolute.snapshot?.values?["audio.microphone.gain"] == 0.8)
        let duplicateValue = try await client.request(valueRequest)
        precondition(duplicateValue.error?.code == "duplicateRequest" && dispatcher.gain == 0.8)
        let relative = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", delta: 0.1))
        precondition(relative.result?.succeeded == true && abs(dispatcher.gain - 0.9) < 0.00001)
        let bounded = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", delta: 1))
        precondition(bounded.result?.succeeded == true && dispatcher.gain == 1)
        let badValue = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", value: 2))
        precondition(badValue.error?.code == "invalidValue" && dispatcher.gain == 1)
        let conflictingValue = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", value: 0.5, delta: 0.1))
        precondition(conflictingValue.error?.code == "invalidValue")
        let wrongKind = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: stable, value: 0.5))
        precondition(wrongKind.result?.error?.code == "invalidValue" && dispatcher.emitted.isEmpty)
        dispatcher.valueTargetExists = false
        let deletedValue = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "audio.microphone.gain", delta: 0.1))
        precondition(deletedValue.result?.error?.code == "invalidTarget" && deletedValue.snapshot?.values?.isEmpty == true)
        dispatcher.valueTargetExists = true
        let pdfID = UUID(), jumpID = "pdf.\(UUID()).goto"
        dispatcher.actions.append(.init(id: jumpID, title: "Jump PDF", command: .pdfGoToPage(pdfID, page: 0)))
        dispatcher.actions.append(.init(id: "output.record.marker", title: "Marker", command: .addRecordingMarker("Chapter")))
        let jumped = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: jumpID, page: 12))
        precondition(jumped.result?.succeeded == true && dispatcher.page == 12)
        let marked = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "output.record.marker", text: "Interview"))
        precondition(marked.result?.succeeded == true && dispatcher.marker == "Interview")
        let wrongArgument = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: stable, page: 0))
        precondition(wrongArgument.result?.error?.code == "invalidValue")
        let oversizedMarker = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "output.record.marker", text: String(repeating: "x", count: 513)))
        precondition(oversizedMarker.error?.code == "invalidValue" && dispatcher.marker == "Interview")
        dispatcher.actions[0].title = "Renamed Intro"
        let renamed = try await client.request(.init(type: .capabilities, id: UUID(), sessionID: sessionID))
        precondition(renamed.commands?.contains { $0.id == stable && $0.title == "Renamed Intro" } == true)
        let command = StudioControlRequest(type: .command, id: UUID(), sessionID: sessionID, commandID: stable)
        let executed = try await client.request(command)
        precondition(executed.result?.succeeded == true && dispatcher.emitted == [stable])
        let duplicate = try await client.request(command)
        precondition(duplicate.error?.code == "duplicateRequest" && dispatcher.emitted == [stable])
        dispatcher.actions.removeFirst()
        let missing = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: stable))
        precondition(missing.result?.error?.code == "invalidTarget" && dispatcher.emitted == [stable])
        let subscribed = try await client.request(.init(type: .subscribe, id: UUID(), sessionID: sessionID))
        precondition(subscribed.type == "snapshot")
        dispatcher.state.stream = .live
        let event = try await client.read()
        precondition(event.type == "event" && event.snapshot?.stream == "live" && (event.snapshot?.revision ?? 0) > 0)
        let unavailable = try await client.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "output.stream.start"))
        precondition(unavailable.result?.error?.code == "unavailable")
        client.connection.cancel()
        let reconnect = WireClient(port: port)
        let reauthenticated = try await reconnect.request(.init(type: .authenticate, id: UUID(), clientID: pairing.id, token: pairing.token))
        precondition(reauthenticated.sessionID != sessionID)
        let noReplay = try await reconnect.request(.init(type: .command, id: UUID(), sessionID: sessionID, commandID: "output.stream.start"))
        precondition(noReplay.error?.code == "unauthorized" && dispatcher.emitted == [stable])
        reconnect.connection.cancel()
        let malformed = WireClient(port: port)
        try await malformed.write(Data("not-json\n".utf8))
        let malformedReply = try await malformed.read()
        precondition(malformedReply.error?.code == "malformedMessage")
        malformed.connection.cancel()
        let manager = StudioAdapterManager(directory: directory)
        manager.bind(to: server)
        let adapterMacro = ShowMacro(name: "Adapter Delay", steps: [ShowMacroStep(commandID: stable, delaySeconds: 60)])
        dispatcher.macros.resolve = { _ in nil }
        precondition(dispatcher.macros.update(ShowMacroDocument(macros: [adapterMacro])) == nil)
        let adapterMacroID = "macro.\(adapterMacro.id.uuidString).run"
        dispatcher.actions.append(.init(id: adapterMacroID, title: "Adapter Delay", command: .action(adapterMacroID)))
        let manifest = StudioAdapterManifest(id: "com.stream.test-controller", name: "Test Adapter", vendor: "Stream", adapterVersion: "1", roles: [.control], resources: [], control: .init(allowedCommandIDs: [stable, adapterMacroID]))
        precondition(manifest.validationError == nil && manifest.hostCompatibilityError == nil)
        var unsupported = manifest; unsupported.roles = [.source]; unsupported.control = nil
        unsupported.source = .init(sourceID: UUID(), width: 1920, height: 1080, maximumFramesPerSecond: 30)
        precondition(unsupported.validationError == nil && unsupported.hostCompatibilityError != nil)
        unsupported.source?.maximumQueuedFrames = 100; precondition(unsupported.validationError != nil)
        unsupported.roles = [.output]; unsupported.source = nil; unsupported.output = .init(outputID: UUID())
        precondition(unsupported.validationError == nil && unsupported.hostCompatibilityError != nil)
        store.pair(name: "Dedicated Adapter"); let adapterPair = store.pairing!
        try manager.register(manifest, clientID: adapterPair.id)
        let registryURL = directory.appendingPathComponent("studio.adapters.v1.json")
        let registry = try String(contentsOf: registryURL, encoding: .utf8)
        precondition(!registry.contains(adapterPair.token) && !registry.contains(pairing.token))
        let disabledClient = WireClient(port: port)
        let disabled = try await disabledClient.request(.init(type: .authenticate, id: UUID(), clientID: adapterPair.id, token: adapterPair.token))
        precondition(disabled.error?.code == "adapterDisabled"); disabledClient.connection.cancel()
        try manager.setEnabled(manifest.id, true)
        dispatcher.actions.insert(.init(id: stable, title: "Restored Intro", command: .action(stable)), at: 0)
        let adapterClient = WireClient(port: port)
        let adapterAuth = try await adapterClient.request(.init(type: .authenticate, id: UUID(), clientID: adapterPair.id, token: adapterPair.token))
        precondition(server.authenticatedClientIDs.contains(adapterPair.id))
        let adapterCapabilities = try await adapterClient.request(.init(type: .capabilities, id: UUID(), sessionID: adapterAuth.sessionID))
        precondition(adapterCapabilities.commands?.first(where: { $0.id == "output.stream.start" })?.available == false)
        precondition(adapterCapabilities.commands?.first(where: { $0.id == stable })?.available == true)
        let grant = try await adapterClient.request(.init(type: .command, id: UUID(), sessionID: adapterAuth.sessionID, commandID: stable))
        precondition(grant.result?.succeeded == true)
        let adapterRun = try await adapterClient.request(.init(type: .command, id: UUID(), sessionID: adapterAuth.sessionID, commandID: adapterMacroID))
        precondition(adapterRun.result?.succeeded == true && dispatcher.macros.isRunning)
        let countBeforeDenied = dispatcher.emitted.count
        let outsideGrant = try await adapterClient.request(.init(type: .command, id: UUID(), sessionID: adapterAuth.sessionID, commandID: "output.stream.start"))
        precondition(outsideGrant.error?.code == "adapterCapabilityDenied" && dispatcher.emitted.count == countBeforeDenied)
        try manager.setEnabled(manifest.id, false)
        await waitUntil { !dispatcher.macros.isRunning }
        precondition(!server.authenticatedClientIDs.contains(adapterPair.id) && store.token(for: adapterPair.id) != nil)
        try manager.setEnabled(manifest.id, true)
        let adapterReconnect = WireClient(port: port)
        let freshAdapter = try await adapterReconnect.request(.init(type: .authenticate, id: UUID(), clientID: adapterPair.id, token: adapterPair.token))
        precondition(freshAdapter.sessionID != adapterAuth.sessionID && dispatcher.emitted.count == countBeforeDenied)
        credentials.deletionError = errSecAuthFailed
        do { try manager.remove(manifest.id); preconditionFailure("Failed revocation removed a restricted adapter") } catch {}
        precondition(manager.document.adapters.first?.enabled == false && store.token(for: adapterPair.id) != nil)
        credentials.deletionError = errSecSuccess; try manager.remove(manifest.id)
        precondition(manager.document.adapters.isEmpty && store.token(for: adapterPair.id) == nil)
        adapterClient.connection.cancel(); adapterReconnect.connection.cancel()
        let sampleRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("integrations/sample-adapter")
        progress("Local control fixture: actual external Python disabled admission")
        let sampleManifest = try JSONDecoder().decode(StudioAdapterManifest.self, from: Data(contentsOf: sampleRoot.appendingPathComponent("manifest.json")))
        store.pair(name: "Actual External Status Sample"); let samplePair = store.pairing!
        try manager.register(sampleManifest, clientID: samplePair.id)
        let sample = try ExternalSampleProcess(script: sampleRoot.appendingPathComponent("studio_status_adapter.py"), clientID: samplePair.id, token: samplePair.token, port: port)
        defer { sample.stop() }
        await waitUntil { !sample.process.isRunning }
        await waitUntil { sample.pipesFinished }
        precondition(sample.output.snapshots.isEmpty && sample.errors.text.contains("adapterDisabled"), "Actual external sample bypassed its disabled registration")
        try manager.setEnabled(sampleManifest.id, true)
        progress("Local control fixture: actual external Python enabled state and disable")
        let connected = try ExternalSampleProcess(script: sampleRoot.appendingPathComponent("studio_status_adapter.py"), clientID: samplePair.id, token: samplePair.token, port: port)
        defer { connected.stop() }
        await waitUntil { !connected.output.snapshots.isEmpty }
        precondition(server.authenticatedClientIDs.contains(samplePair.id) && connected.process.isRunning)
        let originalState = dispatcher.state, commandCount = dispatcher.emitted.count
        dispatcher.state.recording = .paused
        await waitUntil { connected.output.snapshots.contains { $0["recording"] as? String == "paused" } }
        try manager.setEnabled(sampleManifest.id, false)
        await waitUntil { !connected.process.isRunning }
        await waitUntil { connected.pipesFinished }
        precondition(connected.errors.text.contains("Studio disconnected") && dispatcher.emitted.count == commandCount,
            "External sample did not stop cleanly or emitted/replayed a production command")
        precondition(!connected.output.text.contains(samplePair.token) && !connected.errors.text.contains(samplePair.token))
        try manager.setEnabled(sampleManifest.id, true)
        progress("Local control fixture: actual external Python explicit restart and revoke")
        let restarted = try ExternalSampleProcess(script: sampleRoot.appendingPathComponent("studio_status_adapter.py"), clientID: samplePair.id, token: samplePair.token, port: port)
        defer { restarted.stop() }
        await waitUntil { restarted.output.snapshots.contains { $0["recording"] as? String == "paused" } }
        precondition(server.authenticatedClientIDs.contains(samplePair.id) && dispatcher.emitted.count == commandCount)
        try manager.remove(sampleManifest.id)
        await waitUntil { !restarted.process.isRunning }
        await waitUntil { restarted.pipesFinished }
        precondition(store.token(for: samplePair.id) == nil && !restarted.output.text.contains(samplePair.token) && !restarted.errors.text.contains(samplePair.token))
        dispatcher.state = originalState
        // Exercise the actual six Python pipes, not a second handler model.
        // EOF handlers left installed can spin and starve later native replies.
        try await Task.sleep(for: .milliseconds(100))
        precondition([sample, connected, restarted].allSatisfy(\.pipesRetired),
            "Completed external processes retained EOF handlers or repeated empty callbacks")
        progress("PASS: all six actual Python pipes retire at first EOF; no empty callback spin after exit")
        progress("PASS: actual bundled external Python process against native server; disabled admission, live authoritative state, disable, explicit restart, revoke and no command/secret replay")

        progress("Local control fixture: future registry preserves bytes and restores current grants")
        let futureDirectory = directory.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let futureData = Data("{\"version\":99,\"adapters\":[]}".utf8)
        let futureURL = futureDirectory.appendingPathComponent("studio.adapters.v1.json")
        try futureData.write(to: futureURL)
        let futureManager = StudioAdapterManager(directory: futureDirectory); futureManager.bind(to: server)
        precondition(server.clientAuthorization(pairing.id, nil)?.code == "adapterRegistryUnavailable")
        do { try futureManager.register(manifest, clientID: pairing.id); preconditionFailure("Future registry overwritten") } catch {}
        let preservedFuture = try Data(contentsOf: futureURL)
        precondition(preservedFuture == futureData)
        manager.bind(to: server)
        let macro = ShowMacro(name: "Remote", steps: [ShowMacroStep(commandID: "output.stream.start", delaySeconds: 60)])
        dispatcher.macros.resolve = { _ in nil }
        precondition(dispatcher.macros.update(ShowMacroDocument(macros: [macro])) == nil)
        let macroCommandID = "macro.\(macro.id.uuidString).run"
        dispatcher.actions.append(.init(id: macroCommandID, title: "Run Remote", command: .action(macroCommandID)))
        progress("Local control fixture: authenticate ordinary macro owner · native peers=\(server.connectedClients)")
        let owner = WireClient(port: port)
        let ownerAuth = try await owner.request(.init(type: .authenticate, id: UUID(), clientID: pairing.id, token: pairing.token))
        progress("Local control fixture: ordinary owner authenticated; request delayed macro")
        let started = try await owner.request(.init(type: .command, id: UUID(), sessionID: ownerAuth.sessionID, commandID: macroCommandID))
        precondition(started.result?.succeeded == true && dispatcher.macros.isRunning)
        progress("Local control fixture: delayed macro acknowledged; revoke owner and await cancellation")
        server.revoke(pairing.id)
        await waitUntil { !dispatcher.macros.isRunning && server.connectedClients == 0 }
        precondition(store.token(for: pairing.id) == nil && dispatcher.macros.progress.phase == .cancelled)
        owner.connection.cancel()
        server.setEnabled(false)
        precondition(server.listeningPort == nil)
        print("PASS: native loopback IPC, pairing/no JSON secrets, token/version/size checks, rename/delete/results/dedup/events, reconnect/no replay, adapter grants/disable/re-enable/revoke safety/future registry, malformed input, revoke/remote macro cancel, shutdown")
    }
}
