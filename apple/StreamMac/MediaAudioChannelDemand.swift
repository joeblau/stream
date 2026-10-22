import Foundation

/// A media insert's identity crosses the MainActor → mixer actor hop. The
/// mixer checks this table inside its synchronous mutation, so an older
/// reconciliation cannot install a retired box or remove a replacement.
final class MediaAudioChannelDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [AudioChannelID: UUID] = [:]
    private var revision: UInt64 = 0

    func replace(_ desired: [AudioChannelID: UUID]) {
        lock.withLock {
            guard identities != desired else { return }
            identities = desired; revision &+= 1
        }
    }
    func matches(_ id: AudioChannelID, identity: UUID?) -> Bool {
        lock.withLock { identities[id] == identity }
    }
    func currentRevision() -> UInt64 { lock.withLock { revision } }
    func matches(revision expected: UInt64) -> Bool { lock.withLock { revision == expected } }
}
