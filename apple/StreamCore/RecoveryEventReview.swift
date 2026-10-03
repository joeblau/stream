import Foundation

/// Secret-free identity captured at a local publisher start. Credentials and
/// current destination edits cannot replace this interrupted-session binding.
public struct RecoveryEventIdentity: Equatable, Sendable {
    public var outputID: UUID
    public var publisherSessionID: UUID
    public var provider: ManagedProvider
    public var channelID: String
    public var eventID: String
    public var capturedAt: Date
    public init(outputID: UUID, publisherSessionID: UUID, provider: ManagedProvider,
                channelID: String, eventID: String, capturedAt: Date) {
        self.outputID = outputID; self.publisherSessionID = publisherSessionID
        self.provider = provider; self.channelID = channelID; self.eventID = eventID; self.capturedAt = capturedAt
    }
    public static func validID(_ value: String) -> Bool {
        value.utf8.count <= 200 && ProviderChannel.validID(value)
    }
    public var isValid: Bool {
        Self.validID(channelID) && Self.validID(eventID) && capturedAt.timeIntervalSince1970.isFinite
    }
}

/// A fresh read proves both current-account ownership and exact event state.
/// This receipt intentionally contains no titles, URLs, account tokens or keys.
public struct RecoveryEventVerification: Equatable, Sendable {
    public var provider: ManagedProvider
    public var eventID: String
    public var channelID: String?
    public var authorizedChannelIDs: [String]
    public var state: ProviderEvent.State
    public var readStartedAt: Date
    public var observedAt: Date
    public init(provider: ManagedProvider, eventID: String, channelID: String?, authorizedChannelIDs: [String],
                state: ProviderEvent.State, readStartedAt: Date, observedAt: Date) {
        self.provider = provider; self.eventID = eventID; self.channelID = channelID
        self.authorizedChannelIDs = authorizedChannelIDs; self.state = state
        self.readStartedAt = readStartedAt; self.observedAt = observedAt
    }
}

public struct RecoveryEventReview: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case notVerified, missingIdentity, unsupportedProvider, contextMismatch, authorizationNeeded
        case accountChanged, foreignOwnership, notLive, stale, invalidResponse, permissionDenied
        case unavailable, rateLimited, timedOut, ended, live
        public var message: String {
            switch self {
            case .notVerified: return "Remote state is unknown. Verify explicitly with the current account."
            case .missingIdentity: return "This journal has no verified session/account binding. Review the provider externally."
            case .unsupportedProvider: return "This provider has no supported fresh recovery-state reader. Review it externally."
            case .contextMismatch: return "Select the journal's project and profile before verifying."
            case .authorizationNeeded: return "Connect the current account with YouTube read permission before verifying."
            case .accountChanged: return "Authorization changed during verification. Verify again with the current account."
            case .foreignOwnership: return "The current authorized account does not own this exact channel and event."
            case .notLive: return "The event is not freshly confirmed live or ended. Review its provider controls."
            case .stale: return "The verification is stale or has invalid timing. Verify again."
            case .invalidResponse: return "The provider did not return the exact event and supported state."
            case .permissionDenied: return "The provider denied read access. Check permissions and account eligibility."
            case .unavailable: return "The provider could not be reached. Remote state remains unknown."
            case .rateLimited: return "Provider quota or rate limiting prevented verification. Wait before retrying."
            case .timedOut: return "Verification timed out. Remote state remains unknown."
            case .ended: return "The current account freshly confirmed this event has ended."
            case .live: return "The current account freshly confirmed this event is live. Review ingest settings and start locally only by explicit intent."
            }
        }
    }
    public var state: SessionRecoveryRemoteEvent.State
    public var reason: Reason
    public var checkedAt: Date?
    public init(state: SessionRecoveryRemoteEvent.State = .unknown, reason: Reason = .notVerified, checkedAt: Date? = nil) {
        self.state = state; self.reason = reason; self.checkedAt = checkedAt
    }
    public func current(at now: Date, lifetime: TimeInterval = 60) -> Self {
        guard state != .unknown else { return self }
        guard let checkedAt, now.timeIntervalSince(checkedAt) >= 0,
              now.timeIntervalSince(checkedAt) <= lifetime else { return .init(reason: .stale, checkedAt: checkedAt) }
        return self
    }
    public static func classify(_ receipt: RecoveryEventVerification, identity: RecoveryEventIdentity,
                                requestedAt: Date, now: Date) -> Self {
        guard identity.isValid, receipt.provider == identity.provider, receipt.eventID == identity.eventID,
              receipt.authorizedChannelIDs.count <= 2_000,
              receipt.authorizedChannelIDs.allSatisfy(ProviderChannel.validID) else { return .init(reason: .invalidResponse) }
        guard identity.provider == .youtube else { return .init(reason: .unsupportedProvider) }
        guard receipt.channelID == identity.channelID,
              receipt.authorizedChannelIDs.contains(identity.channelID) else { return .init(reason: .foreignOwnership) }
        let times = [requestedAt, now, receipt.readStartedAt, receipt.observedAt]
        guard times.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              receipt.readStartedAt >= requestedAt, receipt.observedAt >= receipt.readStartedAt,
              now >= receipt.observedAt, now.timeIntervalSince(receipt.observedAt) <= 60 else { return .init(reason: .stale) }
        switch receipt.state {
        case .ended: return .init(state: .ended, reason: .ended, checkedAt: receipt.observedAt)
        case .live: return .init(state: .reconnectable, reason: .live, checkedAt: receipt.observedAt)
        default: return .init(reason: .notLive, checkedAt: receipt.observedAt)
        }
    }
    public static func failure(_ error: Error) -> Self {
        guard let failure = error as? ProviderFailure else { return .init(reason: .unavailable) }
        switch failure.kind {
        case .authorization: return .init(reason: .authorizationNeeded)
        case .permission: return .init(reason: .permissionDenied)
        case .rateLimited: return .init(reason: .rateLimited)
        case .invalidResponse, .invalidRequest: return .init(reason: .invalidResponse)
        case .unavailable: return .init(reason: .unavailable)
        }
    }
}

/// Public GET-only API boundary. Ownership is read from channels.mine before
/// looking up the exact broadcast; request caching is explicitly bypassed.
/// Authorization generations must additionally be fenced by the caller.
public struct RecoveryEventReader: Sendable {
    private let send: ProviderAPI.Request
    private let now: @Sendable () -> Date
    public init(send: @escaping ProviderAPI.Request, now: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send; self.now = now
    }
    public func verify(_ identity: RecoveryEventIdentity) async throws -> RecoveryEventVerification {
        guard identity.isValid else { throw ProviderFailure(.invalidRequest) }
        guard identity.provider == .youtube else { throw ProviderFailure(.unavailable) }
        let started = now()
        let api = ProviderAPI { provider, original in
            guard provider == .youtube, original.httpMethod == "GET", original.httpBody == nil,
                  original.url?.host == "www.googleapis.com",
                  ["/youtube/v3/channels", "/youtube/v3/liveBroadcasts"].contains(original.url?.path ?? "") else {
                throw ProviderFailure(.invalidRequest)
            }
            try Task.checkCancellation()
            var request = original
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            return try await send(provider, request)
        }
        let channels = try await api.channels(.youtube)
        try Task.checkCancellation()
        // A foreign current account need not make even the event lookup.
        guard channels.contains(where: { $0.provider == .youtube && $0.id == identity.channelID }) else {
            return .init(provider: .youtube, eventID: identity.eventID, channelID: nil,
                authorizedChannelIDs: channels.map(\.id), state: .unknown, readStartedAt: started, observedAt: now())
        }
        let event = try await api.youtubeEvent(id: identity.eventID)
        try Task.checkCancellation()
        return .init(provider: event.provider, eventID: event.id, channelID: event.channelID,
            authorizedChannelIDs: channels.map(\.id), state: event.state, readStartedAt: started, observedAt: now())
    }
}
