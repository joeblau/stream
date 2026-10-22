import Foundation
import StreamCore
import AuthenticationServices
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import os

private let chatLog = Logger(subsystem: "com.joeblau.Stream", category: "chat")

// MARK: - Restream API constants

enum RestreamAPI {
    /// Native completion only. Restream registers the broker's HTTPS callback;
    /// the broker returns this fixed scheme after spending provider state.
    static let redirectScheme = "streamchat"
    static let redirectURI = "streamchat://oauth"
    static let chatWebSocketURL = "wss://chat.api.restream.io/ws"
}

// MARK: - A single unified chat message (aggregated across platforms)

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let author: String
    let text: String
    let platform: String?
}

// MARK: - App-only Keychain for broker configuration and device-bound grants

private enum RestreamKeychain {
    #if os(macOS)
    private static let service = "com.joeblau.Stream.mac.restream"
    #else
    private static let service = "com.joeblau.Stream.restream"
    #endif

    @discardableResult static func set(_ value: String?, for account: String) -> Bool {
        return write(value, for: account)
    }
    private static func write(_ value: String?, for account: String) -> Bool {
        #if STREAM_NATIVE_VALIDATION
        return false
        #else
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard let value, !value.isEmpty else {
            let result = SecItemDelete(base as CFDictionary)
            return result == errSecSuccess || result == errSecItemNotFound
        }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var attrs = base
        for (key, value) in values { attrs[key] = value }
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        #endif
    }
    static func get(_ account: String) -> String? {
        return read(account, service: service)
    }
    private static func read(_ account: String, service: String) -> String? {
        #if STREAM_NATIVE_VALIDATION
        return nil
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }
}

// MARK: - Restream OAuth2 + unified-chat controller

@MainActor
@Observable
final class RestreamChat: NSObject {
    enum Status: Equatable {
        case needsCredentials   // trusted broker not configured
        case signedOut          // credentials set, no token
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .needsCredentials
    private(set) var messages: [ChatMessage] = []

    @ObservationIgnored private var brokerURL = RestreamKeychain.get("brokerOrigin") ?? ""
    @ObservationIgnored private var brokerSession: RestreamBrokerSession?
    @ObservationIgnored private var authorizationJob: Task<Void, Never>?
    @ObservationIgnored private let brokerStore = RestreamBrokerGrantStore(
        readGrant: { RestreamKeychain.get("brokerGrant") },
        writeGrant: { RestreamKeychain.set($0, for: "brokerGrant") },
        isRetired: { UserDefaults.standard.bool(forKey: "restream.broker.retired.v1") },
        setRetired: { value in
            UserDefaults.standard.set(value, forKey: "restream.broker.retired.v1")
            return UserDefaults.standard.synchronize()
        })
    private var accessToken: String? { brokerSession?.authorizedGrant?.access }
    private var grantedScopes: Set<String>? { brokerSession?.authorizedGrant.map { Set($0.scopes) } }
    #if os(macOS)
    var hasProviderAuthorization: Bool { hasCredentials && accessToken != nil }
    var providerAuthorizationGeneration: UUID? { accessToken == nil ? nil : sessionGeneration }
    var providerGrantedScopes: Set<String>? { grantedScopes }

    /// The account boundary exposes documented REST data, never tokens. A GET
    /// may refresh once after 401; mutations are never replayed automatically.
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data {
        guard request.url?.scheme == "https", request.url?.host == "api.restream.io",
              request.url?.path.hasPrefix("/v2/user/") == true,
              request.url?.user == nil, request.url?.password == nil, request.url?.port == nil, request.url?.fragment == nil else { throw ProviderFailure(.invalidRequest) }
        try Task.checkCancellation()
        let generation = sessionGeneration
        guard hasCredentials, let token = accessToken else { throw ProviderFailure(.authorization) }
        var req = request; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await ProviderHTTP.shared.send(req)
        guard sessionGeneration == generation, hasProviderAuthorization else { throw CancellationError() }
        try Task.checkCancellation()
        if response.statusCode == 401 && (request.httpMethod ?? "GET") == "GET" {
            guard await refreshAccessToken(), sessionGeneration == generation, let token = accessToken else { throw ProviderFailure(.authorization) }
            try Task.checkCancellation()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await ProviderHTTP.shared.send(req)
        }
        guard sessionGeneration == generation, hasProviderAuthorization else { throw CancellationError() }
        try Task.checkCancellation()
        try ProviderFailure.check(data: data, response: response)
        return data
    }

    @ObservationIgnored var onStudioEnvelope: ((Data) -> Void)?
    @ObservationIgnored var onStudioReset: (() -> Void)?

    func disconnectStudioSession() {
        sessionGeneration = UUID()
        authorizationJob?.cancel(); authorizationJob = nil; brokerSession?.cancel()
        tokenRefreshTask?.cancel(); tokenRefreshTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        authSession?.cancel(); authSession = nil
        status = hasCredentials ? .signedOut : .needsCredentials
    }
    #endif

    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var tokenRefreshTask: Task<Bool, Never>?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?

    var hasCredentials: Bool { configuredBroker != nil }
    var configuredBrokerURL: String { brokerURL }
    private var configuredBroker: RestreamAuthBroker? {
        guard let url = URL(string: brokerURL) else { return nil }
        return try? RestreamAuthBroker(origin: url)
    }

    override init() {
        super.init()
        loadBrokerSession()
        refreshStatus()
    }

    private func refreshStatus() {
        if !hasCredentials { status = .needsCredentials }
        else if accessToken == nil { status = .signedOut }
    }

    /// The server owns Restream application credentials. Legacy native secrets
    /// remain untouched and inactive; no authorization is migrated implicitly.
    @discardableResult func saveBrokerURL(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let broker = try? RestreamAuthBroker(origin: url) else {
            status = .failed("Enter the trusted HTTPS Restream authorization service URL."); return false
        }
        sessionGeneration = UUID(); authorizationJob?.cancel(); brokerSession?.retireAuthorization()
        authSession?.cancel(); authSession = nil
        tokenRefreshTask?.cancel(); tokenRefreshTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil); webSocket = nil
        guard RestreamKeychain.set(broker.origin.absoluteString, for: "brokerOrigin") else {
            status = .failed("The authorization service configuration could not be saved."); return false
        }
        brokerURL = broker.origin.absoluteString; loadBrokerSession(); status = .signedOut
        #if os(macOS)
        onStudioReset?()
        #endif
        return true
    }
    private func loadBrokerSession() {
        guard let client = configuredBroker else { brokerSession = nil; return }
        brokerSession = RestreamBrokerSession(client: client, grant: brokerStore.load(), persist: brokerStore.save)
    }

    /// Reconnect silently when both credentials and a prior OAuth token are in
    /// Keychain. First-time authorization still requires the explicit Connect
    /// button because it presents Restream's consent UI.
    func autoConnect() {
        guard hasCredentials, accessToken != nil,
              status != .connecting, status != .connected else { return }
        connect()
    }

    /// Begin (or resume) a chat session: connect the WebSocket if we already hold a
    /// token, otherwise run the OAuth authorization-code flow first.
    func connect() {
        guard hasCredentials else { status = .needsCredentials; return }
        reconnectAttempts = 0
        if let token = accessToken {
            openWebSocket(token: token)
        } else {
            startAuthorization()
        }
    }

    func signOut() {
        sessionGeneration = UUID()
        authorizationJob?.cancel(); authorizationJob = nil
        let saved = brokerSession?.forget() ?? true
        tokenRefreshTask?.cancel(); tokenRefreshTask = nil
        authSession?.cancel(); authSession = nil
        #if os(macOS)
        onStudioReset?()
        #endif
        webSocket?.cancel(with: .goingAway, reason: nil); webSocket = nil
        messages.removeAll()
        status = saved ? (hasCredentials ? .signedOut : .needsCredentials)
            : .failed("Connection stopped. Stored authorization removal failed; retry sign-out when local storage is available.")
    }
    /// Cancel this connection without revoking another workspace's account.
    func cancelConnection() {
        sessionGeneration = UUID(); authorizationJob?.cancel(); authorizationJob = nil
        brokerSession?.cancel(); tokenRefreshTask?.cancel(); tokenRefreshTask = nil
        authSession?.cancel(); authSession = nil
        webSocket?.cancel(with: .goingAway, reason: nil); webSocket = nil
        #if os(macOS)
        onStudioReset?()
        #endif
        status = hasCredentials ? .signedOut : .needsCredentials
    }

    // Provider code and confidential tokens stay at the configured broker.
    private func startAuthorization() {
        guard let brokerSession else { status = .needsCredentials; return }
        sessionGeneration = UUID(); let generation = sessionGeneration
        authorizationJob?.cancel(); authSession?.cancel(); status = .connecting
        authorizationJob = Task { [weak self] in
            do {
                let attempt = try await brokerSession.begin()
                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: RestreamAPI.redirectScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.sessionGeneration == generation else { return }
                        if let error {
                            brokerSession.cancel()
                            self.status = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? .signedOut : .failed("Authorization is unavailable. Review the service configuration.")
                            return
                        }
                        guard let callback else { self.status = .failed("Authorization did not return a callback."); return }
                        self.authorizationJob = Task { [weak self] in
                            do {
                                let value = try await brokerSession.complete(attempt, callback: callback)
                                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                                self.openWebSocket(token: value.access)
                            } catch {
                                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                                self.status = .failed("Authorization could not be accepted. Reconnect through the configured service.")
                            }
                        }
                    }
                }
                session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = false
                self.authSession = session
                if !session.start() { brokerSession.cancel(); self.status = .failed("Authorization browser could not be opened.") }
            } catch {
                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                self.status = .failed("The Restream authorization service is unavailable or unconfigured.")
            }
        }
    }
    private func refreshAccessToken() async -> Bool {
        if let task = tokenRefreshTask { return await task.value }
        let generation = sessionGeneration
        let task = Task { [weak self] in await self?.performTokenRefresh() ?? false }
        tokenRefreshTask = task
        let result = await task.value
        if sessionGeneration == generation { tokenRefreshTask = nil }
        return result
    }
    private func performTokenRefresh() async -> Bool {
        guard let brokerSession else { return false }
        let generation = sessionGeneration
        do {
            _ = try await brokerSession.refresh()
            return sessionGeneration == generation && !Task.isCancelled
        } catch {
            if (error as? ProviderFailure)?.kind == .authorization, sessionGeneration == generation { brokerSession.forget() }
            return false
        }
    }

    // MARK: Chat WebSocket

    private func openWebSocket(token: String) {
        webSocket?.cancel(with: .goingAway, reason: nil)
        var comps = URLComponents(string: RestreamAPI.chatWebSocketURL)!
        comps.queryItems = [.init(name: "accessToken", value: token)]
        guard let url = comps.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        status = .connecting
        task.resume()
        receive(from: task)
    }

    private func receive(from socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.webSocket === socket else { return }
                guard self.hasCredentials, self.accessToken != nil else {
                    socket.cancel(with: .goingAway, reason: nil); self.webSocket = nil; self.status = .signedOut
                    #if os(macOS)
                    self.onStudioReset?()
                    #endif
                    return
                }
                switch result {
                case .success(.string(let text)):
                    self.ingest(Data(text.utf8))
                    self.reconnectAttempts = 0
                    self.status = .connected
                    self.receive(from: socket)
                case .success(.data(let data)):
                    self.ingest(data)
                    self.reconnectAttempts = 0
                    self.status = .connected
                    self.receive(from: socket)
                case .success:
                    self.reconnectAttempts = 0
                    self.status = .connected
                    self.receive(from: socket)
                case .failure(let error):
                    chatLog.error("Chat socket closed with code \((error as NSError).code)")
                    guard self.reconnectAttempts < 5 else {
                        self.status = .failed("Chat disconnected — reconnect to retry."); return
                    }
                    self.reconnectAttempts += 1
                    let delay = min(16, 1 << (self.reconnectAttempts - 1))
                    self.status = .connecting
                    Task {
                        try? await Task.sleep(for: .seconds(delay))
                        guard self.webSocket === socket else { return }
                        let refreshed = await self.refreshAccessToken()
                        guard self.webSocket === socket else { return }
                        if refreshed, let token = self.accessToken { self.openWebSocket(token: token) }
                        else { self.status = .failed("Chat disconnected — reconnect to retry.") }
                    }
                @unknown default:
                    self.reconnectAttempts = 0
                    self.status = .connected
                    self.receive(from: socket)
                }
            }
        }
    }

    /// The desktop decoder consumes documented typed events. The existing
    /// mobile feed retains its presentation mapping without logging content.
    private func ingest(_ envelope: Data) {
        guard envelope.count <= 262_144 else { return }
        #if os(macOS)
        onStudioEnvelope?(envelope)
        #endif
        guard let obj = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              (obj["action"] as? String) == "event" else { return }

        let payload = obj["payload"] as? [String: Any]
        let event = payload?["eventPayload"] as? [String: Any] ?? payload
        let author = (event?["author"] as? [String: Any])?["displayName"] as? String
            ?? (event?["author"] as? [String: Any])?["name"] as? String
            ?? event?["displayName"] as? String
            ?? event?["username"] as? String
            ?? event?["author"] as? String
            ?? "—"
        let text = event?["text"] as? String
            ?? event?["message"] as? String
            ?? (event?["message"] as? [String: Any])?["text"] as? String
            ?? ""
        guard !text.isEmpty else { return }

        let platform = (payload?["eventTypeId"] as? String)
            ?? (payload?["eventSourceId"]).map { "\($0)" }
        messages.append(ChatMessage(author: author, text: text, platform: platform))
        if messages.count > 500 { messages.removeFirst(messages.count - 500) }
    }
}

#if os(macOS)
extension RestreamChat: ProviderRestreamBoundary {}
#endif

// MARK: - OAuth presentation anchor

extension RestreamChat: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? NSWindow()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let key = windows.first(where: \.isKeyWindow) { return key }
            if let first = windows.first { return first }
            // OAuth is only started with visible UI, so a scene is guaranteed here.
            return UIWindow(windowScene: scenes.first!)
            #endif
        }
    }
}
