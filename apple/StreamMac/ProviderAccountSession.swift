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
    @Published private(set) var viewers: [String: Int] = [:]
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
    init(restream: any ProviderRestreamBoundary, vault: ProviderTokenVault = .shared,
         transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network,
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.restream = restream; self.vault = vault; self.transport = transport; self.openBrowser = openBrowser
        for provider in ManagedProvider.allCases { accounts[provider] = .init() }
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
        generations[provider] = UUID(); jobs[provider]?.cancel(); jobs[provider] = nil
        receivers[provider]?.cancel(); receivers[provider] = nil
        accounts[provider]?.isWorking = false; accounts[provider]?.devicePrompt = nil
    }
    func shutdown() {
        directChat?.shutdown()
        boot?.cancel(); boot = nil; hourlyValidation?.cancel(); hourlyValidation = nil
        for provider in ManagedProvider.allCases { cancel(provider); cooldowns[provider]?.cancel(); cooldowns[provider] = nil }
    }
    func forget(_ provider: ManagedProvider) {
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
        guard [.youtube, .twitch].contains(provider) else { return }
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
        guard [.youtube, .twitch].contains(provider), canRequest(provider) else { throw ProviderFailure(.unavailable) }
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
                    event = try await api.youtubeEvent(id: id); count = try await api.youtubeViewers(eventID: id)
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
    func createYouTube(_ draft: YouTubeEventDraft) { mutateYouTube { try await $0.createYouTubeEvent(draft) } }
    func editYouTube(eventID: String, draft: YouTubeEventDraft) {
        mutateYouTube { try await $0.editYouTubeEvent(id: eventID, title: draft.title, description: draft.description, scheduledAt: draft.scheduledAt) }
    }
    func completeYouTube(eventID: String) { mutateYouTube { try await $0.completeYouTubeEvent(id: eventID) } }
    func canRequest(_ provider: ManagedProvider) -> Bool { (accounts[provider]?.retryUntil ?? .distantPast) <= Date() }
    private func mutateYouTube(_ operation: @escaping @Sendable (ProviderAPI) async throws -> ProviderEvent) {
        guard canRequest(.youtube) else { return }
        let generation = begin(.youtube, action: "Saving a YouTube event change")
        jobs[.youtube] = Task { [weak self] in
            guard let self else { return }
            do {
                let event = try await operation(api())
                guard isCurrent(.youtube, generation) else { return }
                accounts[.youtube]?.events = Self.merge((accounts[.youtube]?.events ?? []).filter { $0.id != event.id } + [event])
                accounts[.youtube]?.verifiedAt = Date()
                finish(.youtube, generation)
            } catch { finish(.youtube, generation, error: error) }
        }
    }
    func deleteYouTube(eventID: String) {
        guard canRequest(.youtube) else { return }
        let generation = begin(.youtube, action: "Deleting the selected upcoming YouTube event")
        jobs[.youtube] = Task { [weak self] in
            guard let self else { return }
            do {
                try await api().deleteYouTubeEvent(id: eventID)
                guard isCurrent(.youtube, generation) else { return }
                accounts[.youtube]?.events.removeAll { $0.id == eventID }
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
