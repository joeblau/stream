import CryptoKit
import Foundation
import StreamCore

/// Resource selection and optional exact public event identity, never credentials.
struct StudioDestinationCommand: Equatable, Sendable {
    enum Kind: String, Sendable { case start, stop, endRemote, endBoth, reviewRemote }
    var kind: Kind
    var id: UUID?
    var binding: ProviderDestinationBinding? = nil
    var eventBound = false
    static func eventKey(_ binding: ProviderDestinationBinding) -> String {
        // Length prefixes prevent ambiguous channel/event identities. Renames are excluded.
        let fields = [binding.provider.rawValue, binding.channelID, binding.eventID.map { "event:\($0)" } ?? "no-event"]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
