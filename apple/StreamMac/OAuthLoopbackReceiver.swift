import Foundation
@preconcurrency import Network
import StreamCore

/// A single-use HTTP callback bound only to IPv4 loopback. Every mutable field
/// is confined to queue. It never logs or echoes the authorization code.
final class OAuthLoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.joeblau.Stream.oauth.loopback")
    private var listener: NWListener?
    private var redirect: URL?
    private var state: String?
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var received: URL?
    private var terminal: Error?
    private var timeout: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]
    func start(state: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard self.listener == nil, self.terminal == nil, self.received == nil else { continuation.resume(throwing: self.terminal ?? ProviderFailure(.invalidRequest)); return }
                self.state = state; self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] value in
                        guard let self else { return }
                        switch value {
                        case .ready:
                            guard let port = self.listener?.port else { self.finish(ProviderFailure(.unavailable)); return }
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!
                            self.redirect = url; self.ready?.resume(returning: url); self.ready = nil
                        case .failed: self.finish(ProviderFailure(.unavailable))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    let work = DispatchWorkItem { [weak self] in self?.finish(ProviderFailure(.authorization)) }
                    self.timeout = work; self.queue.asyncAfter(deadline: .now() + 180, execute: work)
                    listener.start(queue: self.queue)
                } catch { self.finish(ProviderFailure(.unavailable)) }
            }
        }
    }
    func response() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let value = self.received { continuation.resume(returning: value) }
                    else if let error = self.terminal { continuation.resume(throwing: error) }
                    else if self.callback != nil { continuation.resume(throwing: ProviderFailure(.invalidRequest)) }
                    else { self.callback = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { self.finish(CancellationError()) } }
    private func accept(_ connection: NWConnection) {
        guard terminal == nil, received == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        read(connection, id: id, bytes: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            connection?.cancel(); self?.connections[id] = nil
        }
    }
    private func read(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; if let data { bytes.append(data) }
            guard bytes.count <= 16_384, error == nil else { connection.cancel(); self.connections[id] = nil; return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                if !complete { self.read(connection, id: id, bytes: bytes) }
                else { connection.cancel(); self.connections[id] = nil }
                return
            }
            let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
                  let redirect = self.redirect, let state = self.state,
                  let callback = URL(string: "http://127.0.0.1:\(redirect.port!)\(parts[1])"),
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
                  items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                self.reply(connection, id: id, status: "404 Not Found", text: "Unknown callback."); return
            }
            self.received = callback
            self.callback?.resume(returning: callback); self.callback = nil
            self.timeout?.cancel(); self.timeout = nil; self.listener?.cancel(); self.listener = nil
            self.reply(connection, id: id, status: "200 OK", text: "Authorization received. Close this tab and return to Stream.")
        }
    }
    private func reply(_ connection: NWConnection, id: UUID, status: String, text: String) {
        let body = Data(text.utf8)
        let headers = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        connection.send(content: headers + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.connections[id] = nil
        })
    }
    private func finish(_ error: Error) {
        guard terminal == nil, received == nil else { return }
        terminal = error; timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections = [:]
        ready?.resume(throwing: error); ready = nil; callback?.resume(throwing: error); callback = nil
    }
}
