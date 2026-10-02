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
struct HarnessState {
    var stream: StreamSessionState = .idle
    var recording: RecordingSessionState = .idle
    var preview: PreviewSessionState = .idle
    var stagedSceneID: HarnessID?
    var programSceneID: HarnessID?
    var hasPendingStagedEdits = false
    var layerVisibility: [HarnessID: Bool] = [:]
}
enum StudioCommand { case action(String) }
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
    func catalogueActions() -> [StudioPaletteAction] { actions }
    func execute(_ command: StudioCommand) -> StudioCommandResult {
        switch command {
        case .action(let id):
            if id == "output.stream.start", state.stream.isActive { return .init(outcome: .rejected(.unavailable("Already active"))) }
            if id.hasPrefix("macro."), let uuid = UUID(uuidString: String(id.dropFirst(6).dropLast(4))) { macros.start(uuid) }
            emitted.append(id)
            return .init(outcome: .success)
        }
    }
}
@MainActor final class MemoryCredentials: StudioControlCredentials {
    var tokens: [UUID: String] = [:]
    func read(_ id: UUID) -> String? { tokens[id] }
    func write(_ token: String, for id: UUID) -> OSStatus { tokens[id] = token; return errSecSuccess }
    func delete(_ id: UUID) -> OSStatus { tokens.removeValue(forKey: id); return errSecSuccess }
}
@MainActor final class WireClient {
    let connection: NWConnection
    private var buffer = StudioControlFrameBuffer()
    private var frames: [StudioControlResponse] = []
    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
    }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func request(_ request: StudioControlRequest) async throws -> StudioControlResponse {
        var data = try JSONEncoder().encode(request); data.append(10)
        try await write(data)
        while true {
            let response = try await read()
            if response.id == request.id { return response }
        }
    }
    func read() async throws -> StudioControlResponse {
        while frames.isEmpty {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: StudioControlProtocolError(code: "closed", message: complete ? "Closed" : "Empty")) }
                }
            }
            frames += try buffer.append(data).map { try JSONDecoder().decode(StudioControlResponse.self, from: $0) }
        }
        return frames.removeFirst()
    }
}
@main struct StudioLocalControlHarness {
    @MainActor static func waitUntil(_ test: () -> Bool) async {
        for _ in 0..<2000 {
            if test() { return }; try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Local IPC harness timed out")
    }
    @MainActor static func main() async throws {
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
        let macro = ShowMacro(name: "Remote", steps: [ShowMacroStep(commandID: "output.stream.start", delaySeconds: 60)])
        dispatcher.macros.resolve = { _ in nil }
        precondition(dispatcher.macros.update(ShowMacroDocument(macros: [macro])) == nil)
        let macroCommandID = "macro.\(macro.id.uuidString).run"
        dispatcher.actions.append(.init(id: macroCommandID, title: "Run Remote", command: .action(macroCommandID)))
        let owner = WireClient(port: port)
        let ownerAuth = try await owner.request(.init(type: .authenticate, id: UUID(), clientID: pairing.id, token: pairing.token))
        let started = try await owner.request(.init(type: .command, id: UUID(), sessionID: ownerAuth.sessionID, commandID: macroCommandID))
        precondition(started.result?.succeeded == true && dispatcher.macros.isRunning)
        server.revoke(pairing.id)
        await waitUntil { !dispatcher.macros.isRunning && server.connectedClients == 0 }
        precondition(store.token(for: pairing.id) == nil && dispatcher.macros.progress.phase == .cancelled)
        owner.connection.cancel()
        server.setEnabled(false)
        precondition(server.listeningPort == nil)
        print("PASS: native loopback IPC, per-client pairing/no JSON secrets, token/version checks, fragmentation/bounds, capabilities/rename/delete, structured results, request dedup, snapshot/events, reconnect/no replay, malformed input, revoke/remote macro cancel, shutdown")
    }
}
