import Foundation

// Data-only boundaries: no credential, provider request, authorization or live
// count is fabricated. The runner inserts the unmodified production mapper and
// Codable audience record. Explicit fixture readings test projection fidelity.
private enum Freshness: String { case current, expired, unavailable }
private struct ReadingValue { var count: Int?; var readAt: Date?; var freshness: Freshness }
private struct Destination { let id: UUID; let name: String; let providerBinding: UUID? }
private enum OutputState: Equatable { case live, connecting, stopping, reconnecting, failed }
private struct Destinations { var saved: [Destination] }
private struct Outputs { var states: [UUID:OutputState] = [:]; var acknowledgedStarts: [UUID:Date] = [:] }
private struct Controller { var destinations: Destinations; var destinationOutputs = Outputs() }
private struct Accounts {
    var values: [UUID:ReadingValue] = [:]
    func viewerReading(_ id: UUID, now: Date) -> ReadingValue { values[id] ?? .init(count:nil,readAt:nil,freshness:.unavailable) }
}
private enum ReceiptState { case sending, acknowledged, notSent, rejected, unconfirmed, stopped }
private struct Receipt { let id: UUID; let state: ReceiptState }
private struct DirectChat { var receipts: [Receipt] = [] }
private struct Chat { var directChat: DirectChat? }
private enum GuestPublicChatEnvelope {
    static func prefix(_ text: String, bytes: Int) -> String {
        precondition(text.utf8.count <= bytes, "Fixture labels are already within the shipping prefix bound")
        return text
    }
}
// PRODUCTION_AUDIENCE_RECORD
private struct Projection {
    var controller: Controller?
    var accounts: Accounts?
    var chat: Chat?
    var presetReceipts: [String:UUID] = [:]
// PRODUCTION_AUDIENCE_MAPPER
}

@main private enum AudienceProjectionHarness {
    static func main() throws {
        let destinations = (0..<65).map { Destination(id:UUID(),name:"Configured \($0)",providerBinding:UUID()) }
        let last = destinations.last!, binding = last.providerBinding!, date = Date(timeIntervalSince1970:1000)
        var projection = Projection(controller:.init(destinations:.init(saved:destinations)), accounts:Accounts())
        let missing = projection.audienceSnapshot(now:date)
        precondition(missing.readings.count == 65 && missing.readings.last?.destinationID == last.id)
        precondition(missing.readings.last?.count == nil && missing.readings.last?.freshness == "unavailable")
        projection.accounts!.values[binding] = .init(count:0,readAt:date,freshness:.current)
        let cached = projection.audienceSnapshot(now:date)
        precondition(cached.readings.count == 65 && cached.readings.last?.count == 0 && cached.readings.last?.freshness == "current")
        precondition(cached.readings.dropLast().allSatisfy { $0.count == nil && $0.freshness == "unavailable" })
        projection.accounts!.values[binding] = .init(count:nil,readAt:date,freshness:.expired)
        let expired = projection.audienceSnapshot(now:date.addingTimeInterval(61))
        precondition(expired.readings.last?.destinationID == last.id && expired.readings.last?.count == nil && expired.readings.last?.readAt == 1000 && expired.readings.last?.freshness == "expired")
        let encoded = try JSONEncoder().encode(expired)
        let decoded = try JSONDecoder().decode(StudioControlAudienceState.self,from:encoded)
        precondition(decoded == expired)
        print("PASS: exact production audienceSnapshot maps all65 stable destinations, including final unavailable/zero/current/expired reading and timestamp; no provider calls")
    }
}
