import Foundation

public struct TwitchDevicePrompt: Sendable, Equatable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
}

/// Twitch's public-client device flow. Poll timing, expiry and cancellation are
/// enforced here, shared by native UI and the deterministic HTTP fixture tests.
public struct TwitchDeviceAuthorization: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Sleep = @Sendable (Double) async throws -> Void
    private let send: Transport
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    public init(send: @escaping Transport,
                sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send; self.sleep = sleep; self.now = now
    }
    public func authorize(clientID: String, prompt: @escaping @Sendable (TwitchDevicePrompt) async -> Void) async throws -> ProviderOAuthToken {
        guard !clientID.isEmpty, clientID.utf8.count <= 500 else { throw ProviderFailure(.invalidRequest) }
        let scopes = ManagedProvider.twitch.scopes.joined(separator: " ")
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ProviderOAuth.form(["client_id": clientID, "scopes": scopes])
        let (data, response) = try await send(request)
        try ProviderFailure.check(data: data, response: response)
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device_code"] as? String, !device.isEmpty, device.utf8.count <= 4_096,
              let user = object["user_code"] as? String, !user.isEmpty, user.utf8.count <= 64,
              let uri = object["verification_uri"] as? String, uri.utf8.count <= 2_048,
              let url = URL(string: uri), url.scheme == "https", ["www.twitch.tv", "twitch.tv"].contains(url.host ?? ""), url.user == nil, url.password == nil,
              let seconds = object["expires_in"] as? Double, seconds.isFinite, seconds > 0, seconds <= 1_800 else { throw ProviderFailure(.invalidResponse) }
        var interval = object["interval"] as? Double ?? 5
        guard interval.isFinite, interval > 0, interval <= 60 else { throw ProviderFailure(.invalidResponse) }
        interval = max(1, interval)
        let expiry = now().addingTimeInterval(seconds)
        await prompt(.init(userCode: user, verificationURL: url, expiresAt: expiry))
        while now() < expiry {
            try Task.checkCancellation()
            try await sleep(interval)
            guard now() < expiry else { break }
            let tokenRequest = try ProviderOAuth.tokenRequest(.twitch, fields: ["client_id": clientID, "scopes": scopes,
                "device_code": device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let (data, response) = try await send(tokenRequest)
            guard data.count <= 65_536 else { throw ProviderFailure(.invalidResponse) }
            if response.statusCode == 400 {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["message"] as? String ?? object?["error"] as? String
                if error == "authorization_pending" { continue }
                if error == "slow_down" { interval = min(60, interval + 5); continue }
                if ["access_denied", "expired_token", "invalid_device_code"].contains(error ?? "") { throw ProviderFailure(.authorization) }
            }
            try ProviderFailure.check(data: data, response: response)
            return try ProviderOAuthToken.parse(data, now: now())
        }
        throw ProviderFailure(.authorization)
    }
}
