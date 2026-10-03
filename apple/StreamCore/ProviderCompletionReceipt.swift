import Foundation

/// An explicit remote end is acknowledged only by a matching completed
/// resource. Transport failure after POST leaves remote state unconfirmed.
public struct ProviderCompletionReceipt: Equatable, Sendable {
    public enum Disposition: String, Sendable { case ended, alreadyEnded, observed, blocked, unconfirmed, unsupported }
    public let disposition: Disposition
    public let event: ProviderEvent?
    public let failure: ProviderFailure?
    public let receivedAt: Date
    public init(_ disposition: Disposition, event: ProviderEvent? = nil, failure: ProviderFailure? = nil, receivedAt: Date = Date()) {
        self.disposition = disposition; self.event = event; self.failure = failure; self.receivedAt = receivedAt
    }
    public var confirmsEnd: Bool { disposition == .ended || disposition == .alreadyEnded || (disposition == .observed && event?.state == .ended) }
}
