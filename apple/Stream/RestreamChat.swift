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
    /// Custom URL scheme for the OAuth redirect. Register the full redirect URI
    /// below on your Restream application's settings.
    static let redirectScheme = "streamchat"
    static let redirectURI = "streamchat://oauth"
    static let authorizeURL = "https://api.restream.io/login"
    static let tokenURL = URL(string: "https://api.restream.io/oauth/token")!
    static let chatWebSocketURL = "wss://chat.api.restream.io/ws"
}

// MARK: - A single unified chat message (aggregated across platforms)

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let author: String
    let text: String
    let platform: String?
}

// MARK: - Minimal app-only Keychain for the Restream client credentials + tokens

private enum RestreamKeychain {
    #if os(macOS)
    private static let service = "com.joeblau.Stream.mac.restream"
    /// Copy once, preserving legacy iOS/shared credentials. A marker in the new
    /// service prevents sign-out from resurrecting the old access token.
    private static func migrateLegacyIfNeeded() {
        #if !STREAM_NATIVE_VALIDATION
        let flag = "restream.desktopCredentialMigration.v1"
        if UserDefaults.standard.bool(forKey: flag) || read("desktopMigration", service: service) != nil { return }
        // Record the attempt before copying. Even if Keychain is locked or an
        // item write fails, a later sign-out/relaunch must not restore an old
        // iOS token. Missing values can be repaired with explicit authorization.
        UserDefaults.standard.set(true, forKey: flag)
        for account in ["clientID", "clientSecret", "accessToken", "refreshToken"] {
            if read(account, service: service) == nil,
               let value = read(account, service: "com.joeblau.Stream.restream") {
                guard write(value, for: account) else { return }
            }
        }
        _ = write("1", for: "desktopMigration")
        #endif
    }
    #else
    private static let service = "com.joeblau.Stream.restream"
    #endif

    static func set(_ value: String?, for account: String) {
        #if os(macOS)
        migrateLegacyIfNeeded()
        #endif
        _ = write(value, for: account)
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var attrs = base
        for (key, value) in values { attrs[key] = value }
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        #endif
    }
    static func get(_ account: String) -> String? {
        #if os(macOS)
        migrateLegacyIfNeeded()
        #endif
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
        case needsCredentials   // client id/secret not set
        case signedOut          // credentials set, no token
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .needsCredentials
    private(set) var messages: [ChatMessage] = []

    @ObservationIgnored private var clientID = RestreamKeychain.get("clientID") ?? ""
    @ObservationIgnored private var clientSecret = RestreamKeychain.get("clientSecret") ?? ""
    @ObservationIgnored private var accessToken = RestreamKeychain.get("accessToken")
    @ObservationIgnored private var refreshToken = RestreamKeychain.get("refreshToken")
    #if os(macOS)
    var hasProviderAuthorization: Bool { accessToken != nil }

    /// The account boundary exposes documented REST data, never tokens. A GET
    /// may refresh once after 401; mutations are never replayed automatically.
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data {
        guard request.url?.scheme == "https", request.url?.host == "api.restream.io",
              request.url?.path.hasPrefix("/v2/user/") == true,
              request.url?.user == nil, request.url?.password == nil else { throw ProviderFailure(.invalidRequest) }
        let generation = sessionGeneration
        guard let token = accessToken else { throw ProviderFailure(.authorization) }
        var req = request; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await ProviderHTTP.shared.send(req)
        if response.statusCode == 401 && (request.httpMethod ?? "GET") == "GET" {
            guard await refreshAccessToken(), sessionGeneration == generation, let token = accessToken else { throw ProviderFailure(.authorization) }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await ProviderHTTP.shared.send(req)
        }
        guard sessionGeneration == generation else { throw CancellationError() }
        try ProviderFailure.check(data: data, response: response)
        return data
    }

    @ObservationIgnored var onStudioEnvelope: ((Data) -> Void)?
    @ObservationIgnored var onStudioReset: (() -> Void)?

    func disconnectStudioSession() {
        sessionGeneration = UUID(); oauthState = nil
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
    @ObservationIgnored private var oauthState: String?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?

    var hasCredentials: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    override init() {
        super.init()
        refreshStatus()
    }

    private func refreshStatus() {
        if !hasCredentials { status = .needsCredentials }
        else if accessToken == nil { status = .signedOut }
    }

    /// Store the Restream application's client id + secret (obtained by registering
    /// an app at dashboard.restream.io and whitelisting the redirect URI).
    func saveCredentials(clientID: String, clientSecret: String) {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialsChanged = clientID != self.clientID || clientSecret != self.clientSecret
        self.clientID = clientID
        self.clientSecret = clientSecret
        RestreamKeychain.set(self.clientID, for: "clientID")
        RestreamKeychain.set(self.clientSecret, for: "clientSecret")
        // OAuth tokens belong to the client credentials that issued them. Never
        // reuse an old token after the user replaces either credential.
        if credentialsChanged {
            sessionGeneration = UUID(); oauthState = nil
            tokenRefreshTask?.cancel(); tokenRefreshTask = nil
            authSession?.cancel(); authSession = nil
            #if os(macOS)
            onStudioReset?()
            #endif
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            accessToken = nil
            refreshToken = nil
            RestreamKeychain.set(nil, for: "accessToken")
            RestreamKeychain.set(nil, for: "refreshToken")
        }
        refreshStatus()
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
        sessionGeneration = UUID(); oauthState = nil
        tokenRefreshTask?.cancel(); tokenRefreshTask = nil
        authSession?.cancel(); authSession = nil
        #if os(macOS)
        onStudioReset?()
        #endif
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        accessToken = nil
        refreshToken = nil
        RestreamKeychain.set(nil, for: "accessToken")
        RestreamKeychain.set(nil, for: "refreshToken")
        messages.removeAll()
        status = .signedOut
    }

    // MARK: OAuth authorization-code flow

    private func startAuthorization() {
        let state = UUID().uuidString
        let generation = sessionGeneration
        oauthState = state
        var comps = URLComponents(string: RestreamAPI.authorizeURL)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: RestreamAPI.redirectURI),
            .init(name: "state", value: state)
        ]
        guard let url = comps.url else { return }

        status = .connecting
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: RestreamAPI.redirectScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
                self.handleCallback(callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func handleCallback(_ url: URL?, error: Error?) {
        if let error {
            // User-cancelled is not an error worth surfacing.
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                refreshStatus()
            } else {
                status = .failed("Authorization is unavailable. Review the app configuration and reconnect.")
            }
            return
        }
        guard let url, url.scheme == RestreamAPI.redirectScheme, url.host == "oauth",
              url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "code" }).count == 1,
              items.filter({ $0.name == "state" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              items.first(where: { $0.name == "state" })?.value == oauthState else {
            status = .failed("Authorization failed or was tampered with.")
            return
        }
        oauthState = nil
        let generation = sessionGeneration
        Task { await exchangeCode(code, generation: generation) }
    }

    private func exchangeCode(_ code: String, generation: UUID) async {
        do {
            let tokens = try await requestTokens(
                body: ProviderOAuth.form(["grant_type": "authorization_code", "redirect_uri": RestreamAPI.redirectURI, "code": code]))
            guard sessionGeneration == generation else { return }
            store(tokens)
            if let token = tokens.access { openWebSocket(token: token) }
        } catch {
            guard sessionGeneration == generation else { return }
            status = .failed("Token exchange failed — reconnect to retry.")
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
        guard let refresh = refreshToken else { return false }
        let generation = sessionGeneration
        do {
            let tokens = try await requestTokens(
                body: ProviderOAuth.form(["grant_type": "refresh_token", "refresh_token": refresh]))
            guard sessionGeneration == generation else { return false }
            store(tokens)
            return tokens.access != nil
        } catch {
            chatLog.error("Token refresh failed with code \((error as NSError).code)")
            return false
        }
    }

    private struct Tokens { let access: String?; let refresh: String? }

    private func requestTokens(body: Data) async throws -> Tokens {
        var req = URLRequest(url: RestreamAPI.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.httpBody = body; req.timeoutInterval = 30
        #if os(macOS)
        let (data, http) = try await ProviderHTTP.shared.send(req)
        let response: URLResponse = http
        #else
        let (data, response) = try await URLSession.shared.data(for: req)
        #endif
        guard data.count <= 65_536, (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.userAuthenticationRequired)
        }
        return Tokens(access: obj["access_token"] as? String,
                      refresh: obj["refresh_token"] as? String)
    }

    private func store(_ tokens: Tokens) {
        if let a = tokens.access { accessToken = a; RestreamKeychain.set(a, for: "accessToken") }
        if let r = tokens.refresh { refreshToken = r; RestreamKeychain.set(r, for: "refreshToken") }
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
                switch result {
                case .success(.string(let text)):
                    self.ingest(text)
                    self.reconnectAttempts = 0
                    self.status = .connected
                    self.receive(from: socket)
                case .success(.data(let data)):
                    self.ingest(String(decoding: data, as: UTF8.self))
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
    private func ingest(_ json: String) {
        guard let envelope = json.data(using: .utf8), envelope.count <= 262_144 else { return }
        #if os(macOS)
        onStudioEnvelope?(envelope)
        #endif
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
