import AppKit
import Combine
import Foundation
import StreamCore

@MainActor protocol ProviderRestreamBoundary: AnyObject, Sendable {
    var hasProviderAuthorization: Bool { get }
    func signOut()
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data
}

struct ProviderAccountSnapshot {
    var clientID = ""
    var hasCredential = false
    var scopes: [String] = []
    var isWorking = false
    var action = ""
    var channels: [ProviderChannel] = []
    var events: [ProviderEvent] = []
    var verifiedAt: Date?
    var failure: ProviderFailure?
    var retryUntil: Date?
    var devicePrompt: TwitchDevicePrompt?
}

/// Native account/session UI owns no portable credentials. The machine vault
/// owns tokens; this workspace owns only verified metadata and cancellable work.
@MainActor
final class ProviderAccountSession: ObservableObject {
    @Published private(set) var accounts: [ManagedProvider: ProviderAccountSnapshot] = [:]
    @Published private(set) var lastThumbnailReceipt: (eventID: String, time: Date)?
    @Published private(set) var viewers: [String: Int] = [:]
    @Published private(set) var youtubeStreams: [YouTubeLiveStream] = []
    @Published private(set) var bindingReview: YouTubeBindingReview?
    @Published private(set) var lastSchedulingReceipt: ProviderSchedulingReceipt?
    /// Public receipt invalidation only; contains no credential information.
    @Published private(set) var managedReadRevision = UUID()
    let pending: ProviderPendingCatalog
    private var pendingScheduling: (generation: UUID, action: String, id: String, mutating: Bool)?
    private var closed = false
    weak var directChat: StudioDirectChatManager?
    private var viewerDates: [String: Date] = [:]
    private let restream: any ProviderRestreamBoundary
    private let vault: ProviderTokenVault
    private let transport: ProviderTokenVault.Transport
    private let openBrowser: (URL) -> Bool
    private var jobs: [ManagedProvider: Task<Void, Never>] = [:]
    private var generations: [ManagedProvider: UUID] = [:]
    private var cooldowns: [ManagedProvider: Task<Void, Never>] = [:]
    private var receivers: [ManagedProvider: OAuthLoopbackReceiver] = [:]
    private var hourlyValidation: Task<Void, Never>?
    private var boot: Task<Void, Never>?
    private var endingEpochs: [ManagedProvider: UUID] = [:]
    private var managedReadGenerations: [ManagedProvider: (session: UUID, credential: UUID, token: UUID)] = [:]
    private func endingEpoch(_ provider: ManagedProvider) -> UUID {
        if let epoch = endingEpochs[provider] { return epoch }
        let epoch = UUID(); endingEpochs[provider] = epoch; return epoch
    }
    private func hasEndingEpoch(_ provider: ManagedProvider, _ epoch: UUID) -> Bool { endingEpoch(provider) == epoch }
    init(restream: any ProviderRestreamBoundary, vault: ProviderTokenVault = .shared,
         transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network,
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, pendingDirectory: URL? = nil) {
        self.restream = restream; self.vault = vault; self.transport = transport; self.openBrowser = openBrowser
        self.pending = ProviderPendingCatalog(directory: pendingDirectory)
        for provider in ManagedProvider.allCases { accounts[provider] = .init() }
        accounts[.youtube]?.events = pending.document.records.filter { $0.kind == .event }.map(\.cachedEvent)
        youtubeStreams = pending.document.records.filter { $0.kind == .stream }.map(\.cachedStream)
        boot = Task { [weak self] in
            guard let self else { return }
            for provider in [ManagedProvider.youtube, .twitch] {
                let clientID = await vault.clientID(provider), present = await vault.hasToken(provider), scopes = await vault.scopes(provider)
                guard !Task.isCancelled else { return }
                guard generations[provider] == nil else { continue }
                accounts[provider]?.clientID = clientID; accounts[provider]?.hasCredential = present; accounts[provider]?.scopes = scopes
            }
            accounts[.restream]?.hasCredential = restream.hasProviderAuthorization
            if accounts[.twitch]?.hasCredential == true {
                do {
                    try await vault.validateTwitch()
                    let scopes = await vault.scopes(.twitch)
                    guard !Task.isCancelled, generations[.twitch] == nil else { return }
                    accounts[.twitch]?.scopes = scopes
                } catch {
                    let present = await vault.hasToken(.twitch)
                    guard !Task.isCancelled, generations[.twitch] == nil else { return }
                    accounts[.twitch]?.failure = Self.failure(error); accounts[.twitch]?.hasCredential = present
                }
            }
        }
        hourlyValidation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if await vault.hasToken(.twitch) {
                    do { try await vault.validateTwitch() }
                    catch {
                        let present = await vault.hasToken(.twitch)
                        guard !Task.isCancelled else { return }
                        accounts[.twitch]?.failure = Self.failure(error)
                        accounts[.twitch]?.hasCredential = present; accounts[.twitch]?.verifiedAt = nil
                        if !present { directChat?.stop(.twitch) }
                    }
                }
            }
        }
    }
    func snapshot(_ provider: ManagedProvider) -> ProviderAccountSnapshot { accounts[provider] ?? .init() }
    private func api() -> ProviderAPI {
        let restream = restream, vault = vault
        return ProviderAPI { provider, request in
            if provider == .restream { return try await restream.authorizedProviderRequest(request) }
            return try await vault.send(provider, request: request)
        }
    }
    private func begin(_ provider: ManagedProvider, action: String) -> UUID {
        cancel(provider)
        let generation = UUID(); generations[provider] = generation
        accounts[provider]?.isWorking = true; accounts[provider]?.action = action
        accounts[provider]?.failure = nil; accounts[provider]?.devicePrompt = nil
        return generation
    }
    private func isCurrent(_ provider: ManagedProvider, _ generation: UUID) -> Bool {
        generations[provider] == generation && !Task.isCancelled
    }
    private func finish(_ provider: ManagedProvider, _ generation: UUID, error: Error? = nil) {
        guard isCurrent(provider, generation) else { return }
        accounts[provider]?.isWorking = false; accounts[provider]?.devicePrompt = nil
        if let error {
            let failure = Self.failure(error)
            accounts[provider]?.failure = failure; accounts[provider]?.verifiedAt = nil
            if failure.kind == .authorization { accounts[provider]?.hasCredential = false; directChat?.stop(provider) }
            if failure.kind == .rateLimited {
                let delay = max(1, failure.retryAfter ?? 60)
                accounts[provider]?.retryUntil = Date().addingTimeInterval(delay)
                cooldowns[provider]?.cancel()
                cooldowns[provider] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self else { return }; accounts[provider]?.retryUntil = nil; cooldowns[provider] = nil
                }
            }
        }
        jobs[provider] = nil; receivers[provider]?.cancel(); receivers[provider] = nil
    }
    private static func failure(_ error: Error) -> ProviderFailure { error as? ProviderFailure ?? .init(.unavailable) }
    func cancel(_ provider: ManagedProvider) {
        if provider == .youtube {
            bindingReview = nil
            if let operation = pendingScheduling {
                lastSchedulingReceipt = .init(action: operation.action, resourceID: operation.id,
                    state: operation.mutating ? .unconfirmed : .blocked, failure: .init(.unavailable))
                pendingScheduling = nil
            }
        }
        generations[provider] = UUID(); jobs[provider]?.cancel(); jobs[provider] = nil
        receivers[provider]?.cancel(); receivers[provider] = nil
        accounts[provider]?.isWorking = false; accounts[provider]?.devicePrompt = nil
    }
    func shutdown() {
        closed = true
        managedReadRevision = UUID()
        lastThumbnailReceipt = nil
        for provider in ManagedProvider.allCases { endingEpochs[provider] = UUID() }
        directChat?.shutdown()
        boot?.cancel(); boot = nil; hourlyValidation?.cancel(); hourlyValidation = nil
        for provider in ManagedProvider.allCases { cancel(provider); cooldowns[provider]?.cancel(); cooldowns[provider] = nil }
    }
    func forget(_ provider: ManagedProvider) {
        guard !closed else { return }
        if provider == .youtube { lastThumbnailReceipt = nil }
        endingEpochs[provider] = UUID()
        if provider == .youtube { managedReadRevision = UUID() }
        directChat?.stop(provider)
        let generation = begin(provider, action: "Forgetting local authorization")
        jobs[provider] = Task { [weak self] in
            guard let self else { return }
            if provider == .restream { restream.signOut() } else { await vault.disconnect(provider) }
            guard isCurrent(provider, generation) else { return }
            accounts[provider]?.hasCredential = false; accounts[provider]?.channels = []; accounts[provider]?.events = []
            accounts[provider]?.verifiedAt = nil
            viewers = viewers.filter { !$0.key.hasPrefix(provider.rawValue + ":") }
            viewerDates = viewerDates.filter { !$0.key.hasPrefix(provider.rawValue + ":") }
            finish(provider, generation)
        }
    }
    func authorize(_ provider: ManagedProvider, clientID: String, additionalScopes: [String] = []) {
        guard !closed else { return }
        guard [.youtube, .twitch].contains(provider) else { return }
        if provider == .youtube { lastThumbnailReceipt = nil }
        endingEpochs[provider] = UUID()
        if provider == .youtube { managedReadRevision = UUID() }
        directChat?.stop(provider)
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = begin(provider, action: "Waiting for provider authorization")
        accounts[provider]?.clientID = clientID
        jobs[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let credentialGeneration = try await vault.configure(provider, clientID: clientID)
                let token: ProviderOAuthToken
                if provider == .youtube {
                    let receiver = OAuthLoopbackReceiver(); receivers[provider] = receiver
                    let state = try ProviderOAuth.randomURLSafe(), verifier = try ProviderOAuth.randomURLSafe()
                    let redirect = try await receiver.start(state: state)
                    guard isCurrent(provider, generation) else { receiver.cancel(); return }
                    let url = try ProviderOAuth.googleAuthorization(clientID: clientID, redirect: redirect, state: state, verifier: verifier)
                    guard openBrowser(url) else { throw ProviderFailure(.unavailable) }
                    let code = try ProviderOAuth.googleCode(await receiver.response(), redirect: redirect, state: state)
                    let request = try ProviderOAuth.tokenRequest(.youtube, fields: ["client_id": clientID, "code": code,
                        "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code"])
                    let (data, response) = try await transport(request)
                    try ProviderFailure.check(data: data, response: response)
                    token = try ProviderOAuthToken.parse(data)
                } else {
                    token = try await TwitchDeviceAuthorization(send: transport).authorize(clientID: clientID, additionalScopes: additionalScopes) { [weak self] prompt in
                        await MainActor.run {
                            guard let self, self.isCurrent(provider, generation) else { return }
                            self.accounts[provider]?.devicePrompt = prompt
                            _ = self.openBrowser(prompt.verificationURL)
                        }
                    }
                }
                guard isCurrent(provider, generation) else { return }
                try await vault.accept(token, provider: provider, generation: credentialGeneration)
                if provider == .youtube, isCurrent(provider, generation), !closed { managedReadRevision = UUID() }
                if provider == .twitch { try await vault.validateTwitch() }
                let scopes = await vault.scopes(provider)
                guard isCurrent(provider, generation) else { return }
                accounts[provider]?.hasCredential = true; accounts[provider]?.scopes = scopes
                finish(provider, generation)
                refresh(provider)
            } catch { finish(provider, generation, error: error) }
        }
    }
    /// Chat shares the machine vault; no bearer credential crosses into views
    /// or a second OAuth session. Readers do not cancel metadata/event jobs.
    func chatRequest(_ provider: ManagedProvider, _ request: URLRequest) async throws -> Data {
        guard !closed, [.youtube, .twitch].contains(provider) else { throw ProviderFailure(.unavailable) }
        if let until = accounts[provider]?.retryUntil, until > Date() {
            throw ProviderFailure(.rateLimited, retryAfter: until.timeIntervalSinceNow)
        }
        do { return try await vault.send(provider, request: request) }
        catch {
            if (error as? ProviderFailure)?.kind == .authorization {
                accounts[provider]?.hasCredential = false; accounts[provider]?.scopes = []; accounts[provider]?.verifiedAt = nil
                accounts[provider]?.failure = Self.failure(error)
            }
            if let failure = error as? ProviderFailure, failure.kind == .rateLimited {
                let delay = max(1, failure.retryAfter ?? 60)
                accounts[provider]?.failure = failure; accounts[provider]?.retryUntil = Date().addingTimeInterval(delay)
                cooldowns[provider]?.cancel()
                cooldowns[provider] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.accounts[provider]?.retryUntil = nil; self?.cooldowns[provider] = nil
                }
            }
            throw error
        }
    }
    func chatIdentity(_ provider: ManagedProvider) async throws -> DirectChatIdentity {
        guard [.youtube, .twitch].contains(provider) else { throw ProviderFailure(.unavailable) }
        guard canRequest(provider) else { throw ProviderFailure(.rateLimited) }
        let expected = await vault.generation(provider)
        if provider == .twitch { try await vault.validateTwitch() }
        let channels = try await api().channels(provider), scopes = await vault.scopes(provider)
        guard await vault.generation(provider) == expected, !Task.isCancelled else { throw CancellationError() }
        guard channels.count == 1 else { throw ProviderFailure(.permission) }
        return .init(channelID: channels[0].id, scopes: scopes)
    }
    func refresh(_ provider: ManagedProvider) {
        guard canRequest(provider), [.youtube, .twitch, .restream].contains(provider) else { return }
        let generation = begin(provider, action: "Reading authorized channels and events")
        jobs[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                if provider == .twitch { try await vault.validateTwitch() }
                let api = api(), channels = try await api.channels(provider)
                let events = provider == .twitch ? [] : try await api.upcoming(provider)
                let scopes = await vault.scopes(provider)
                guard isCurrent(provider, generation) else { return }
                accounts[provider]?.channels = channels
                // Eventual consistency or removal from an upcoming list is not
                // evidence of event completion. Retain acknowledged IDs as
                // unknown until an explicit ID read verifies their lifecycle.
                let present = Set(events.map(\.id))
                let retained = (accounts[provider]?.events ?? []).filter { !present.contains($0.id) }.map { event in
                    var cached = event
                    if cached.state != .ended { cached.state = .unknown }
                    return cached
                }
                accounts[provider]?.events = Self.merge(events + retained)
                accounts[provider]?.verifiedAt = Date(); accounts[provider]?.hasCredential = true
                accounts[provider]?.scopes = scopes
                finish(provider, generation)
            } catch { finish(provider, generation, error: error) }
        }
    }
    private static func merge(_ events: [ProviderEvent]) -> [ProviderEvent] {
        Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, second in first.verifiedAt > second.verifiedAt ? first : second })
            .values.sorted { $0.verifiedAt > $1.verifiedAt }.prefix(2_000).sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
    }
    func event(_ binding: ProviderDestinationBinding) -> ProviderEvent? {
        guard accounts[binding.provider]?.verifiedAt != nil,
              let event = accounts[binding.provider]?.events.first(where: { $0.id == binding.eventID }),
              Date().timeIntervalSince(event.verifiedAt) <= 60 else { return nil }
        return event
    }
    func recoveryEvents(activeIDs: [UUID], destinations: [StreamDestination]) -> [SessionRecoveryRemoteEvent] {
        activeIDs.prefix(10).map { id in
            guard let binding = destinations.first(where: { $0.id == id })?.providerBinding else { return .init(outputID: id) }
            return .init(outputID: id, eventID: binding.eventID, state: event(binding)?.state == .ended ? .ended : .unknown)
        }
    }
    /// An opaque process-local generation incorporates both account replacement
    /// and this workspace's retirement/authorization intent. Never journal it.
    /// Actual vault scopes, not cached UI metadata, authorize the GET boundary.
    func recoveryAuthorizationGeneration(_ provider: ManagedProvider = .youtube) async -> UUID? {
        guard !closed, provider == .youtube, !Task.isCancelled else { return nil }
        let epoch = endingEpoch(provider), credential = await vault.generation(provider)
        let present = await vault.hasToken(provider), scopes = await vault.scopes(provider)
        let finalCredential = await vault.generation(provider)
        guard present, scopes.contains(where: {
            ["https://www.googleapis.com/auth/youtube", "https://www.googleapis.com/auth/youtube.force-ssl",
             "https://www.googleapis.com/auth/youtube.readonly"].contains($0)
        }), !closed, endingEpoch(provider) == epoch, finalCredential == credential,
              !Task.isCancelled else { return nil }
        if let current = managedReadGenerations[provider], current.session == epoch, current.credential == credential { return current.token }
        let token = UUID()
        managedReadGenerations[provider] = (epoch, credential, token)
        return token
    }
    /// Shared by explicit recovery and managed-start reviews. This boundary
    /// accepts only three YouTube read resources; token/mutation endpoints are
    /// unavailable. Callers keep any raw API fields ephemeral and normalize
    /// public metadata before publishing it to views or portable documents.
    func managedReadRequest(_ original: URLRequest, provider: ManagedProvider = .youtube,
                            expectedGeneration: UUID) async throws -> Data {
        guard !closed, provider == .youtube else { throw ProviderFailure(.unavailable) }
        guard canRequest(provider) else { throw ProviderFailure(.rateLimited) }
        guard original.httpMethod == "GET", original.httpBody == nil, original.httpBodyStream == nil,
              let url = original.url, url.scheme == "https", url.host == "www.googleapis.com",
              url.user == nil, url.password == nil, url.fragment == nil, url.port == nil,
              ["/youtube/v3/channels", "/youtube/v3/liveBroadcasts", "/youtube/v3/liveStreams"].contains(url.path) else {
            throw ProviderFailure(.invalidRequest)
        }
        let current = await recoveryAuthorizationGeneration(provider)
        guard current == expectedGeneration, !closed,
              let generation = managedReadGenerations[provider], generation.token == expectedGeneration,
              generation.session == endingEpoch(provider) else { throw ProviderFailure(.authorization) }
        try Task.checkCancellation()
        var request = original
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 30
        let data = try await vault.send(provider, request: request, expectedGeneration: generation.credential, retryAuthorizedGET: false)
        let final = await recoveryAuthorizationGeneration(provider)
        guard final == expectedGeneration, !closed, generation.session == endingEpoch(provider) else { throw ProviderFailure(.authorization) }
        try Task.checkCancellation()
        return data
    }
    func verifyRecoveryEvent(_ identity: RecoveryEventIdentity) async throws -> RecoveryEventVerification {
        guard identity.provider == .youtube else { throw ProviderFailure(.unavailable) }
        guard let generation = await recoveryAuthorizationGeneration(.youtube) else { throw ProviderFailure(.authorization) }
        let reader = RecoveryEventReader { [weak self] provider, request in
            guard let self else { throw ProviderFailure(.unavailable) }
            return try await self.managedReadRequest(request, provider: provider, expectedGeneration: generation)
        }
        let receipt = try await reader.verify(identity)
        let final = await recoveryAuthorizationGeneration(.youtube)
        guard final == generation, !closed,
              managedReadGenerations[.youtube]?.session == endingEpoch(.youtube), !Task.isCancelled else { throw ProviderFailure(.authorization) }
        return receipt
    }
    func viewerCount(_ binding: ProviderDestinationBinding) -> Int? {
        let key = Self.viewerKey(binding)
        guard accounts[binding.provider]?.failure == nil, let date = viewerDates[key], Date().timeIntervalSince(date) <= 60 else { return nil }
        return viewers[key]
    }
    static func viewerKey(_ binding: ProviderDestinationBinding) -> String { "\(binding.provider.rawValue):\(binding.eventID ?? binding.channelID)" }
    func refreshLive(_ binding: ProviderDestinationBinding) {
        guard canRequest(binding.provider) else { return }
        let provider = binding.provider, generation = begin(binding.provider, action: "Reading remote broadcast state")
        jobs[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let api = api()
                var event: ProviderEvent?, count: Int?
                if provider == .youtube, let id = binding.eventID {
                    event = try await api.youtubeEvent(id: id)
                    guard event?.channelID == binding.channelID else { throw ProviderFailure(.permission) }
                    count = try await api.youtubeViewers(eventID: id)
                } else if provider == .twitch { count = try await api.twitchViewers(channelID: binding.channelID) }
                else { throw ProviderFailure(.unavailable) }
                guard isCurrent(provider, generation) else { return }
                if let event { accounts[provider]?.events = Self.merge((accounts[provider]?.events ?? []).filter { $0.id != event.id } + [event]) }
                viewers[Self.viewerKey(binding)] = count; viewerDates[Self.viewerKey(binding)] = Date()
                accounts[provider]?.verifiedAt = Date(); accounts[provider]?.hasCredential = true
                finish(provider, generation)
            } catch {
                guard isCurrent(provider, generation) else { return }
                viewers[Self.viewerKey(binding)] = nil
                finish(provider, generation, error: error)
            }
        }
    }
    /// The UI awaits this before adding a disabled draft. Credentials pass only
    /// from the authorized API into DestinationSession's Keychain-backed editor.
    func importConnection(provider: ManagedProvider, channel: ProviderChannel, event: ProviderEvent?, endpoint: String) async throws -> DestinationCredentials {
        guard canRequest(provider) else { throw ProviderFailure(.rateLimited) }
        if provider == .youtube, let event {
            let api = api(), current = try await api.youtubeEvent(id: event.id)
            guard current.channelID == channel.id, [.upcoming, .live].contains(current.state) else { throw ProviderFailure(.invalidRequest) }
            return try await api.youtubeIngest(eventID: event.id)
        }
        if provider == .twitch {
            guard let url = URL(string: endpoint), ["rtmp", "rtmps"].contains(url.scheme ?? ""), url.host != nil else { throw ProviderFailure(.invalidRequest) }
            return .init(endpoint: endpoint, streamKey: try await api().twitchStreamKey(channelID: channel.id))
        }
        throw ProviderFailure(.unavailable)
    }
    func createYouTube(_ draft: YouTubeEventDraft, channelID: String? = nil) {
        guard pending.canCreate, let channelID = channelID ?? (snapshot(.youtube).channels.count == 1 ? snapshot(.youtube).channels.first?.id : nil) else { return }
        runScheduling(action: "Create event") { api in
            let owned = try await api.channels(.youtube)
            guard owned.contains(where: { $0.id == channelID }) else { throw ProviderFailure(.permission) }
            try Task.checkCancellation()
            let event = try await api.createYouTubeEvent(draft)
            guard event.channelID == channelID else { throw ProviderFailure(.invalidResponse) }
            return .event(event)
        }
    }
    func editYouTube(eventID: String, draft: YouTubeEventDraft) {
        guard let owner = snapshot(.youtube).events.first(where: { $0.id == eventID })?.channelID else { return }
        mutateYouTube { try await $0.editYouTubeEvent(id: eventID, title: draft.title, description: draft.description, scheduledAt: draft.scheduledAt, privacy: draft.privacy, expectedChannelID: owner) }
    }
    func uploadYouTubeThumbnail(eventID: String, channelID: String, image: Data, mimeType: String) {
        guard canRequest(.youtube) else { return }
        lastThumbnailReceipt = nil
        let generation = begin(.youtube, action: "Uploading the selected event thumbnail")
        jobs[.youtube] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api().uploadYouTubeThumbnail(eventID: eventID, expectedChannelID: channelID, image: image, mimeType: mimeType)
                guard isCurrent(.youtube, generation) else { return }
                lastThumbnailReceipt = (eventID, Date())
                finish(.youtube, generation)
            } catch { finish(.youtube, generation, error: error) }
        }
    }
    func completeYouTube(eventID: String) { mutateYouTube { try await $0.completeYouTubeEvent(id: eventID) } }
    func refreshYouTubeStreams() {
        guard canRequest(.youtube), !snapshot(.youtube).isWorking else { return }
        let generation = begin(.youtube, action: "Reading owned YouTube streams"), boundary = api()
        jobs[.youtube] = Task { [weak self] in
            do {
                let streams = try await boundary.youtubeStreams()
                guard let self, self.isCurrent(.youtube, generation) else { return }
                let seen = Set(streams.map(\.id))
                let cached = self.youtubeStreams.filter { !seen.contains($0.id) }.map { stream in
                    var value = stream; value.state = .unknown; value.verifiedAt = .distantPast; return value
                }
                self.youtubeStreams = Array((streams + cached).prefix(2000))
                self.finish(.youtube, generation)
            } catch { self?.finish(.youtube, generation, error: error) }
        }
    }
    func createYouTubeStream(_ draft: YouTubeStreamDraft, channelID: String) {
        guard pending.canCreate else { return }
        runScheduling(action: "Create stream") { api in
            .stream(try await api.createYouTubeStream(draft, expectedChannelID: channelID))
        }
    }
    func reviewYouTubeBinding(eventID: String, streamID: String, channelID: String) {
        runScheduling(action: "Review binding", id: eventID, mutating: false) { api in
            .review(try await api.reviewYouTubeBinding(eventID: eventID, streamID: streamID, expectedChannelID: channelID))
        }
    }
    func clearBindingReview() { bindingReview = nil }
    func bindYouTube(_ review: YouTubeBindingReview, replacingExisting: Bool = false) {
        guard pending.canRetain([.init(review.event), .init(review.stream)]) else { return }
        runScheduling(action: "Bind event to stream", id: review.event.id) { api in
            .bound(try await api.bindYouTube(review, replacingExisting: replacingExisting), review.stream,
                   observed: review.event.boundStreamID == review.stream.id)
        }
    }
    private enum SchedulingOutcome: Sendable {
        case event(ProviderEvent), stream(YouTubeLiveStream), review(YouTubeBindingReview)
        case bound(ProviderEvent, YouTubeLiveStream, observed: Bool)
    }
    private func runScheduling(action: String, id: String = "", mutating: Bool = true,
                               operation: @escaping @Sendable (ProviderAPI) async throws -> SchedulingOutcome) {
        guard canRequest(.youtube), !snapshot(.youtube).isWorking,
              snapshot(.youtube).scopes.contains("https://www.googleapis.com/auth/youtube") ||
              snapshot(.youtube).scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl") else { return }
        let generation = begin(.youtube, action: action), boundary = api()
        pendingScheduling = (generation, action, id, mutating)
        jobs[.youtube] = Task { [weak self] in
            do {
                let result = try await operation(boundary)
                guard let self, self.isCurrent(.youtube, generation) else { return }
                var event: ProviderEvent?, stream: YouTubeLiveStream?, state = ProviderSchedulingReceipt.State.acknowledged
                switch result {
                case .event(let value): event = value
                case .stream(let value): stream = value
                case .review(let value): self.bindingReview = value; state = .observed
                case .bound(let value, let source, let observed): event = value; stream = source; state = observed ? .observed : .acknowledged
                }
                // Synchronously retain acknowledged IDs before any subsequent
                // request; bind failure never replaces the earlier stream ID.
                var retained: [ProviderPendingRecord] = []
                if let event {
                    self.accounts[.youtube]?.events = Self.merge((self.accounts[.youtube]?.events ?? []).filter { $0.id != event.id } + [event])
                    retained.append(.init(event))
                }
                if let stream {
                    self.youtubeStreams.removeAll { $0.id == stream.id }; self.youtubeStreams.insert(stream, at: 0)
                    retained.append(.init(stream))
                }
                if !retained.isEmpty { self.pending.retain(retained) }
                self.lastSchedulingReceipt = .init(action: action, resourceID: event?.id ?? stream?.id ?? id, state: state, failure: nil)
                self.pendingScheduling = nil
                self.finish(.youtube, generation)
            } catch {
                guard let self, self.isCurrent(.youtube, generation) else { return }
                let failure = Self.failure(error)
                self.lastSchedulingReceipt = .init(action: action, resourceID: id,
                    state: !mutating || [.permission, .authorization, .rateLimited, .invalidRequest].contains(failure.kind) ? .blocked : .unconfirmed, failure: failure)
                self.pendingScheduling = nil
                self.finish(.youtube, generation, error: error)
            }
        }
    }
    /// Independent explicit ending operations do not cancel metadata work or
    /// another target's completion. OAuth replacement still invalidates them.
    func endRemote(_ binding: ProviderDestinationBinding, reviewOnly: Bool = false) async -> ProviderCompletionReceipt {
        guard binding.provider == .youtube, let id = binding.eventID else { return .init(.unsupported) }
        guard canRequest(.youtube) else { return .init(.blocked, failure: .init(.rateLimited)) }
        let epoch = endingEpoch(.youtube), credential = await vault.generation(.youtube)
        let scopes = await vault.scopes(.youtube)
        let canWrite = scopes.contains("https://www.googleapis.com/auth/youtube") || scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl")
        guard canWrite || (reviewOnly && scopes.contains("https://www.googleapis.com/auth/youtube.readonly")) else {
            return .init(.blocked, failure: .init(.permission))
        }
        let vault = vault
        let boundary = ProviderAPI { [weak self] provider, request in
            guard await self?.hasEndingEpoch(provider, epoch) == true,
                  await vault.generation(provider) == credential, !Task.isCancelled else { throw CancellationError() }
            return try await vault.send(provider, request: request)
        }
        let result = reviewOnly ? await boundary.reviewYouTubeEnd(id: id, expectedChannelID: binding.channelID)
            : await boundary.endYouTubeEvent(id: id, expectedChannelID: binding.channelID)
        guard endingEpoch(.youtube) == epoch, await vault.generation(.youtube) == credential, !Task.isCancelled else {
            return .init(.unconfirmed, failure: .init(.unavailable))
        }
        if let event = result.event {
            accounts[.youtube]?.events = Self.merge((accounts[.youtube]?.events ?? []).filter { $0.id != event.id } + [event])
            accounts[.youtube]?.verifiedAt = result.receivedAt
        } else if let index = accounts[.youtube]?.events.firstIndex(where: { $0.id == id }) {
            accounts[.youtube]?.events[index].state = .unknown
        }
        accounts[.youtube]?.failure = result.failure
        if let failure = result.failure {
            accounts[.youtube]?.verifiedAt = nil
            if failure.kind == .authorization { accounts[.youtube]?.hasCredential = false; directChat?.stop(.youtube) }
            if failure.kind == .rateLimited {
                let delay = max(1, failure.retryAfter ?? 60)
                accounts[.youtube]?.retryUntil = Date().addingTimeInterval(delay)
                cooldowns[.youtube]?.cancel()
                cooldowns[.youtube] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.accounts[.youtube]?.retryUntil = nil; self?.cooldowns[.youtube] = nil
                }
            }
        }
        return result
    }
    func canRequest(_ provider: ManagedProvider) -> Bool { !closed && (accounts[provider]?.retryUntil ?? .distantPast) <= Date() }
    private func mutateYouTube(_ operation: @escaping @Sendable (ProviderAPI) async throws -> ProviderEvent) {
        guard canRequest(.youtube) else { return }
        let generation = begin(.youtube, action: "Saving a YouTube event change")
        jobs[.youtube] = Task { [weak self] in
            guard let self else { return }
            do {
                let event = try await operation(api())
                guard isCurrent(.youtube, generation) else { return }
                accounts[.youtube]?.events = Self.merge((accounts[.youtube]?.events ?? []).filter { $0.id != event.id } + [event])
                if pending.document.records.contains(where: { $0.kind == .event && $0.providerID == event.id && $0.channelID == event.channelID }) {
                    pending.retain([.init(event)])
                }
                accounts[.youtube]?.verifiedAt = Date()
                finish(.youtube, generation)
            } catch { finish(.youtube, generation, error: error) }
        }
    }
    func deleteYouTube(eventID: String) {
        guard canRequest(.youtube), let owner = snapshot(.youtube).events.first(where: { $0.id == eventID })?.channelID else { return }
        let generation = begin(.youtube, action: "Deleting the selected upcoming YouTube event")
        jobs[.youtube] = Task { [weak self] in
            guard let self else { return }
            do {
                try await api().deleteYouTubeEvent(id: eventID, expectedChannelID: owner)
                guard isCurrent(.youtube, generation) else { return }
                accounts[.youtube]?.events.removeAll { $0.id == eventID }
                pending.remove("youtube:event:\(eventID)")
                finish(.youtube, generation)
            } catch { finish(.youtube, generation, error: error) }
        }
    }
    func setTwitchTitle(channelID: String, title: String) {
        guard canRequest(.twitch) else { return }
        let generation = begin(.twitch, action: "Updating the Twitch channel title")
        jobs[.twitch] = Task { [weak self] in
            guard let self else { return }
            do { try await api().setTwitchTitle(channelID: channelID, title: title); finish(.twitch, generation) }
            catch { finish(.twitch, generation, error: error) }
        }
    }
}
