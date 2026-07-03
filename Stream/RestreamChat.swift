import Foundation
import AuthenticationServices
import Observation
import UIKit
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
    private static let service = "com.joeblau.Stream.restream"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        query.removeAll()
        return String(data: data, encoding: .utf8)
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
        if let token = accessToken {
            openWebSocket(token: token)
        } else {
            startAuthorization()
        }
    }

    func signOut() {
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
            Task { @MainActor in self?.handleCallback(callbackURL, error: error) }
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
                status = .failed(error.localizedDescription)
            }
            return
        }
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              items.first(where: { $0.name == "state" })?.value == oauthState else {
            status = .failed("Authorization failed or was tampered with.")
            return
        }
        Task { await exchangeCode(code) }
    }

    private func exchangeCode(_ code: String) async {
        do {
            let tokens = try await requestTokens(
                body: "grant_type=authorization_code&redirect_uri=\(RestreamAPI.redirectURI)&code=\(code)")
            store(tokens)
            if let token = tokens.access { openWebSocket(token: token) }
        } catch {
            status = .failed("Token exchange failed: \(error.localizedDescription)")
        }
    }

    private func refreshAccessToken() async -> Bool {
        guard let refresh = refreshToken else { return false }
        do {
            let tokens = try await requestTokens(
                body: "grant_type=refresh_token&refresh_token=\(refresh)")
            store(tokens)
            return tokens.access != nil
        } catch {
            chatLog.error("Token refresh failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private struct Tokens { let access: String?; let refresh: String? }

    private func requestTokens(body: String) async throws -> Tokens {
        var req = URLRequest(url: RestreamAPI.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
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
        status = .connected
        task.resume()
        receive()
    }

    private func receive() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.ingest(text)
                    self.receive()
                case .success(.data(let data)):
                    self.ingest(String(decoding: data, as: UTF8.self))
                    self.receive()
                case .success:
                    self.receive()
                case .failure(let error):
                    chatLog.error("Chat socket closed: \(String(describing: error), privacy: .public)")
                    // A closed socket is usually an expired 1h access token — refresh once.
                    Task {
                        if await self.refreshAccessToken(), let token = self.accessToken {
                            self.openWebSocket(token: token)
                        } else {
                            self.status = .failed("Chat disconnected — reconnect to retry.")
                        }
                    }
                @unknown default:
                    self.receive()
                }
            }
        }
    }

    /// The exact chat envelope is undocumented, so parse the common shapes and log
    /// the raw JSON so the mapping can be tightened once real events are observed.
    private func ingest(_ json: String) {
        chatLog.debug("chat: \(json, privacy: .public)")
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

// MARK: - OAuth presentation anchor

extension RestreamChat: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let key = windows.first(where: \.isKeyWindow) { return key }
            if let first = windows.first { return first }
            // OAuth is only started with visible UI, so a scene is guaranteed here.
            return UIWindow(windowScene: scenes.first!)
        }
    }
}
