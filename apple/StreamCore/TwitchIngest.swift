import CoreFoundation
import Foundation

public struct TwitchIngestEndpoint: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let endpoint: String
    /// `default`, `availability` and `priority` are reserved provider fields,
    /// not product promises about latency, health or the best endpoint.
    public static func parse(_ data: Data) throws -> [Self] {
        guard data.count <= 2_097_152,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["ingests"] as? [[String: Any]], rows.count <= 1_000 else { throw ProviderFailure(.invalidResponse) }
        var seen: Set<Int> = []
        return try rows.map { row in
            guard let id = row["_id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                  id.doubleValue.isFinite, id.doubleValue >= 0, id.doubleValue < Double(Int.max),
                  id.doubleValue.rounded() == id.doubleValue, seen.insert(id.intValue).inserted,
                  let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 1_024,
                  let template = row["url_template"] as? String, template.utf8.count <= 2_048,
                  template.hasSuffix("/{stream_key}"), template.components(separatedBy: "{stream_key}").count == 2 else { throw ProviderFailure(.invalidResponse) }
            let endpoint = String(template.dropLast("/{stream_key}".count))
            guard let c = URLComponents(string: endpoint), ["rtmp", "rtmps"].contains(c.scheme ?? ""),
                  let host = c.host?.lowercased(),
                  host.hasSuffix(".contribute.video.net") || host.hasSuffix(".contribute.live-video.net") || host == "ingest.global-contribute.live-video.net" || host == "live.twitch.tv",
                  c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.port == nil,
                  c.path == "/app" else { throw ProviderFailure(.invalidResponse) }
            return .init(id: id.intValue, name: String(name.prefix(200)), endpoint: endpoint)
        }
    }
}
