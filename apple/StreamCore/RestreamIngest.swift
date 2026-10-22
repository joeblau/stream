import CoreFoundation
import Foundation

/// Public routing metadata only. The account-wide relay key is never stored here.
public struct RestreamIngestEndpoint: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let url: URL
}

extension ProviderAPI {
    /// Reads the account's selected relay; it does not select downstream channels
    /// or attach an event. The caller separately fences its authorization lease.
    public func restreamSelectedIngest() async throws -> RestreamIngestEndpoint {
        let selection = try await restreamObject(path: "/v2/user/ingest")
        let selected = try Self.restreamID(selection["ingestId"])
        let data = try await restreamRead(path: "/v2/server/all")
        guard data.count <= 2_097_152,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 1_000 else { throw ProviderFailure(.invalidResponse) }
        var seen: Set<Int> = [], match: RestreamIngestEndpoint?
        for row in rows {
            let id = try Self.restreamID(row["id"])
            guard seen.insert(id).inserted else { throw ProviderFailure(.invalidResponse) }
            guard id == selected else { continue }
            guard let raw = row["rtmpUrl"] as? String, raw.utf8.count <= 2_048,
                  let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["rtmp", "rtmps"].contains(parts.scheme ?? ""), let host = parts.host?.lowercased(),
                  host == "restream.io" || host.hasSuffix(".restream.io"),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.port == nil || parts.port == (parts.scheme == "rtmp" ? 1935 : 443),
                  ["/live", "/live/"].contains(parts.path) else { throw ProviderFailure(.invalidResponse) }
            match = .init(id: id, name: String((row["name"] as? String ?? "Selected Restream ingest").prefix(200)), url: url)
        }
        guard let match else { throw ProviderFailure(.unavailable) }
        return match
    }

    /// Secrets remain ephemeral and are returned only after exact fresh account
    /// membership and selection checks. Missing SRT entitlement is not inferred.
    public func restreamIngest(channelID: String) async throws -> DestinationCredentials {
        guard ProviderChannel.validID(channelID), try await channels(.restream).contains(where: { $0.id == channelID }) else {
            throw ProviderFailure(.permission)
        }
        let ingest = try await restreamSelectedIngest()
        let object = try await restreamObject(path: "/v2/user/streamKey")
        guard let key = object["streamKey"] as? String, !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { throw ProviderFailure(.invalidResponse) }
        let current = try await restreamObject(path: "/v2/user/ingest")
        guard try Self.restreamID(current["ingestId"]) == ingest.id else { throw ProviderFailure(.invalidRequest) }
        return .init(endpoint: ingest.url.absoluteString, streamKey: key)
    }

    private func restreamRead(path: String) async throws -> Data {
        try await performRestreamRead(Self.request(.restream, path: path))
    }
    private func restreamObject(path: String) async throws -> [String: Any] {
        let data = try await restreamRead(path: path)
        guard data.count <= 2_097_152, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure(.invalidResponse)
        }
        return value
    }
    private static func restreamID(_ value: Any?) throws -> Int {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0, value.doubleValue < Double(Int.max),
              value.doubleValue.rounded() == value.doubleValue else { throw ProviderFailure(.invalidResponse) }
        return value.intValue
    }
}
