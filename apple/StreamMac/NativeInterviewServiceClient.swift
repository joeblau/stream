import Foundation

protocol NativeInterviewHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func shutdown()
}

protocol NativeInterviewSocketTransport: AnyObject, Sendable {
    func receive() async throws -> String
    func send(_ text: String, acknowledgment: Bool) -> Bool
    var closeCode: Int? { get }
    func close()
}

protocol NativeInterviewService: Sendable {
    var configuration: NativeInterviewConfiguration { get }
    func createRoom() async throws -> NativeInterviewCreatedRoom
    func createInvite(room: UUID) async throws -> NativeInterviewInvite
    func endRoom(_ room: UUID) async throws
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport
    func shutdown() async
}

/// All mutations are explicit single requests. Neither a transport failure nor
/// reconnect replays room creation, invite creation, admission or room ending.
actor NativeInterviewServiceClient: NativeInterviewService {
    let configuration: NativeInterviewConfiguration
    private let credential: @Sendable () async throws -> NativeInterviewSecret
    private let http: any NativeInterviewHTTPTransport
    private let clock: @Sendable () -> Date
    private var occupied: Set<UUID> = []
    private var closed = false

    init(configuration: NativeInterviewConfiguration,
         credential: @escaping @Sendable () async throws -> NativeInterviewSecret,
         http: any NativeInterviewHTTPTransport = NativeInterviewURLSessionHTTP(),
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.credential = credential; self.http = http; self.clock = clock
    }

    func createRoom() async throws -> NativeInterviewCreatedRoom {
        let data = try await request("/v1/rooms", body: Data(#"{"capacity":1}"#.utf8), status: 201)
        let object = try NativeInterviewWire.object(data, limit: 16_384)
        let host = try NativeInterviewWire.invite(object["host"], now: clock())
        let guest = try NativeInterviewWire.invite(object["guest"], now: clock())
        let expires = try NativeInterviewWire.number(object["expires"]) / 1_000
        guard try NativeInterviewWire.number(object["capacity"]) == 1, host.id != guest.id,
              host.expires == guest.expires, expires == host.expires.timeIntervalSince1970,
              host.secret.capabilityProtocol != guest.secret.capabilityProtocol else { throw NativeInterviewError.malformed }
        return try .init(id: NativeInterviewWire.id(object["id"]), expires: host.expires, capacity: 1, host: host, guest: guest)
    }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite {
        let data = try await request(path(room, "invites"), status: 201)
        return try NativeInterviewWire.invite(NativeInterviewWire.object(data, limit: 16_384), now: clock())
    }
    func endRoom(_ room: UUID) async throws {
        let data = try await request(path(room, "end"), status: 200)
        guard try NativeInterviewWire.boolean(NativeInterviewWire.object(data, limit: 16_384)["ended"]) else {
            throw NativeInterviewError.malformed
        }
    }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        guard host.expires > clock() else { throw NativeInterviewError.expired }
        let data = try await request(path(room, "turn"), secret: host.secret, status: 200, mutation: false)
        let object = try NativeInterviewWire.object(data, limit: 16_384)
        let ttl = try NativeInterviewWire.number(object["ttl"])
        guard (120...3_600).contains(ttl), let entries = object["iceServers"] as? [[String: Any]],
              (1...8).contains(entries.count) else { throw NativeInterviewError.malformed }
        var hasRelay = false
        let servers = try entries.map { entry -> NativeInterviewRelayServer in
            let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
            guard (1...8).contains(urls.count) else { throw NativeInterviewError.malformed }
            for url in urls {
                guard url.utf8.count <= 512,
                      url.range(of: #"^(stun|stuns|turn|turns):[A-Za-z0-9.-]+(:[0-9]{1,5})?(\?transport=(udp|tcp))?$"#,
                                options: .regularExpression) != nil else { throw NativeInterviewError.malformed }
                if let range = url.range(of: #":[0-9]+(\?|$)"#, options: .regularExpression) {
                    let text = String(url[range]).dropFirst().prefix(while: { $0.isNumber })
                    guard let port = Int(text), (1...65_535).contains(port), port != 53 else { throw NativeInterviewError.malformed }
                }
            }
            let relay = urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            if relay {
                guard let username = entry["username"] as? String, !username.isEmpty, username.utf8.count <= 256,
                      !username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      let value = entry["credential"] as? String else { throw NativeInterviewError.malformed }
                hasRelay = true
                return .init(urls: urls, username: username, credential: try .init(value, maximumBytes: 2_048))
            }
            return .init(urls: urls, username: nil, credential: nil)
        }
        guard hasRelay else { throw NativeInterviewError.unavailable }
        let now = clock()
        return .init(servers: servers, expires: min(now.addingTimeInterval(ttl), host.expires),
                     refreshAt: min(now.addingTimeInterval(ttl * 0.8), host.expires))
    }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport {
        guard !closed else { throw NativeInterviewError.closed }
        guard host.expires > clock(), host.secret.isCapability else { throw NativeInterviewError.expired }
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.endpoint(path(room, "socket"), websocket: true),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.requestTimeout)
        request.setValue(configuration.allowedOrigin, forHTTPHeaderField: "Origin")
        request.setValue("stream-interview-v1, \(host.secret.capabilityProtocol)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return NativeInterviewURLSessionSocket(request: request)
    }
    func shutdown() { closed = true; http.shutdown() }
    var occupiedRequestCount: Int { occupied.count }
    private func path(_ room: UUID, _ action: String) -> String { "/v1/rooms/\(room.uuidString.lowercased())/\(action)" }
    private func request(_ path: String, secret: NativeInterviewSecret? = nil, body: Data? = nil,
                         status: Int, mutation: Bool = true) async throws -> Data {
        guard !closed else { throw NativeInterviewError.closed }
        guard occupied.count < 4 else { throw NativeInterviewError.busy }
        let attempt = UUID(); occupied.insert(attempt)
        // Cancelled/noncooperative transports continue occupying admission
        // until their actual read returns; repeated cancellation is bounded.
        defer { occupied.remove(attempt) }
        let authorization: NativeInterviewSecret
        do {
            if let secret { authorization = secret }
            else { authorization = try await credential() }
        } catch { throw NativeInterviewError.authorization }
        guard !closed else { throw NativeInterviewError.closed }
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.endpoint(path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue(authorization.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(configuration.allowedOrigin, forHTTPHeaderField: "Origin")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let reply: (Data, HTTPURLResponse)
        do { reply = try await http.send(request) }
        catch {
            if Task.isCancelled { throw NativeInterviewError.cancelled }
            if let error = error as? NativeInterviewError { throw error }
            throw mutation ? NativeInterviewError.uncertainMutation : NativeInterviewError.transport
        }
        guard !closed else { throw NativeInterviewError.closed }
        try Task.checkCancellation()
        guard reply.0.count <= 16_384 else { throw NativeInterviewError.malformed }
        guard reply.1.statusCode == status else {
            switch reply.1.statusCode {
            case 401, 403: throw NativeInterviewError.authorization
            case 404, 410: throw NativeInterviewError.expired
            case 409: throw NativeInterviewError.capacity
            case 429: throw NativeInterviewError.rateLimited
            case 500...599: throw mutation ? NativeInterviewError.uncertainMutation : NativeInterviewError.unavailable
            default: throw NativeInterviewError.malformed
            }
        }
        return reply.0
    }
}

final class NativeInterviewURLSessionHTTP: NSObject, NativeInterviewHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: URLSession] = [:]
    private var closed = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        let session = URLSession(configuration: configuration), id = UUID()
        try register(session, id: id)
        defer { remove(id); session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= 16_384 else { throw NativeInterviewError.malformed }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw NativeInterviewError.malformed }
            data.append(byte)
        }
        return (data, response)
    }
    private func register(_ session: URLSession, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { session.invalidateAndCancel(); throw NativeInterviewError.closed }
        sessions[id] = session
    }
    private func remove(_ id: UUID) { lock.lock(); sessions[id] = nil; lock.unlock() }
    func shutdown() {
        lock.lock(); closed = true; let active = Array(sessions.values); lock.unlock()
        active.forEach { $0.invalidateAndCancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class NativeInterviewSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: NativeInterviewURLSessionSocket?
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol selectedProtocol: String?) {
        if selectedProtocol != "stream-interview-v1" { owner?.close() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One bounded serial sender. ACKs have priority over media/actions; a stalled
/// write closes this socket within five seconds instead of retaining work.
final class NativeInterviewURLSessionSocket: NativeInterviewSocketTransport, @unchecked Sendable {
    private struct Message { let text: String; let ack: Bool; let size: Int }
    private enum Next { case message(Message), wait, done }
    private let lock = NSLock()
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: NativeInterviewSocketDelegate
    private var acknowledgments: [Message] = [], messages: [Message] = []
    private var lastAction: ContinuousClock.Instant?
    private var bytes = 0, count = 0, working = false, closed = false
    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.waitsForConnectivity = false
        delegate = NativeInterviewSocketDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request); task.maximumMessageSize = 65_536
        delegate.owner = self; task.resume()
    }
    var closeCode: Int? { task.closeCode.rawValue == 0 ? nil : task.closeCode.rawValue }
    func receive() async throws -> String {
        let value = try await task.receive()
        guard case .string(let text) = value, text.utf8.count <= 65_536 else { throw NativeInterviewError.malformed }
        return text
    }
    func send(_ text: String, acknowledgment: Bool = false) -> Bool {
        let size = text.utf8.count
        lock.lock()
        guard !closed, size <= 60_000, count < 64, bytes + size <= 131_072 else { lock.unlock(); return false }
        let message = Message(text: text, ack: acknowledgment, size: size)
        if acknowledgment { acknowledgments.append(message) } else { messages.append(message) }
        count += 1; bytes += size
        let start = !working; working = true; lock.unlock()
        if start { Task { [weak self] in await self?.drain() } }
        return true
    }
    private func next() -> Next {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { working = false; return .done }
        if !acknowledgments.isEmpty { return .message(acknowledgments.removeFirst()) }
        if !messages.isEmpty {
            let now = ContinuousClock.now
            // The service has both a 60-action/s limit and a 32-delivery
            // credit window. A permitted 50-action instantaneous burst can
            // exhaust that window before the first round-trip ACK arrives.
            // Pace normal writes; ACKs remain immediately eligible above.
            if let lastAction, now - lastAction < .milliseconds(20) { return .wait }
            lastAction = now
            return .message(messages.removeFirst())
        }
        working = false; return .done
    }
    private func consumed(_ message: Message) { lock.lock(); count -= 1; bytes -= message.size; lock.unlock() }
    private func drain() async {
        while true {
            let message: Message
            switch next() {
            case .done: return
            case .wait:
                // A pending normal action cannot prevent immediate ACKs.
                try? await Task.sleep(for: .milliseconds(5)); continue
            case .message(let next): message = next
            }
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.close() }
            }
            do { try await task.send(.string(message.text)) }
            catch { deadline.cancel(); consumed(message); close(); return }
            deadline.cancel(); consumed(message)
        }
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }
        closed = true
        count -= messages.count + acknowledgments.count
        bytes -= messages.reduce(0) { $0 + $1.size } + acknowledgments.reduce(0) { $0 + $1.size }
        messages.removeAll(); acknowledgments.removeAll(); lock.unlock()
        task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}
