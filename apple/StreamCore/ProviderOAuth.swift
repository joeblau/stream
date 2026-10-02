import CryptoKit
import Foundation
import Security

public struct ProviderOAuthToken: Codable, Equatable, Sendable {
    public var access: String
    public var refresh: String?
    public var expiresAt: Date
    public var scopes: [String]
    public init(access: String, refresh: String? = nil, expiresAt: Date, scopes: [String] = []) {
        self.access = access; self.refresh = refresh; self.expiresAt = expiresAt; self.scopes = scopes
    }
    /// Only for a machine Keychain value, never a project or recovery document.
    public static func parse(_ data: Data, previous: Self? = nil, now: Date = Date()) throws -> Self {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16_384,
              access.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              let seconds = object["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw ProviderFailure(.invalidResponse) }
        let scopes = (object["scope"] as? [String]) ?? (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        let refresh = (object["refresh_token"] as? String) ?? previous?.refresh
        guard (refresh?.utf8.count ?? 0) <= 16_384, refresh == nil || refresh?.isEmpty == false,
              scopes.count <= 100, scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else { throw ProviderFailure(.invalidResponse) }
        return Self(access: access, refresh: refresh, expiresAt: now.addingTimeInterval(min(seconds, 31_536_000)), scopes: scopes)
    }
}

public enum ProviderOAuth {
    public static func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProviderFailure(.unavailable) }
        return base64URL(Data(bytes))
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    public static func tokenRequest(_ provider: ManagedProvider, fields: [String: String]) throws -> URLRequest {
        let url: URL
        switch provider {
        case .youtube: url = URL(string: "https://oauth2.googleapis.com/token")!
        case .twitch: url = URL(string: "https://id.twitch.tv/oauth2/token")!
        default: throw ProviderFailure(.unavailable)
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields); request.timeoutInterval = 30
        return request
    }
    public static func googleAuthorization(clientID: String, redirect: URL, state: String, verifier: String) throws -> URL {
        guard !clientID.isEmpty, clientID.utf8.count <= 500, verifier.count >= 43, state.count >= 32,
              redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.user == nil, redirect.password == nil, redirect.query == nil else { throw ProviderFailure(.invalidRequest) }
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = ["client_id": clientID, "redirect_uri": redirect.absoluteString, "response_type": "code",
                       "scope": ManagedProvider.youtube.scopes.joined(separator: " "), "state": state,
                       "code_challenge": challenge(verifier), "code_challenge_method": "S256",
                       "access_type": "offline", "prompt": "consent select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
    public static func googleCode(_ callback: URL, redirect: URL, state: String) throws -> String {
        guard callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port,
              callback.path == redirect.path, callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 8_192, !items.contains(where: { $0.name == "error" }) else { throw ProviderFailure(.authorization) }
        return code
    }
}
