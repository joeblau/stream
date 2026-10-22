import Combine
import Foundation
import StreamCore

/// Public read only. It never has an account, bearer, stream key or destination.
@MainActor final class TwitchIngestDiscovery: ObservableObject {
    @Published private(set) var endpoints: [TwitchIngestEndpoint] = []
    @Published private(set) var failure: ProviderFailure?
    @Published private(set) var isWorking = false
    @Published private(set) var retryUntil: Date?
    private let transport: ProviderTokenVault.Transport
    private var generation = UUID()
    private var target: String?
    private var task: Task<Void, Never>?
    private var cooldown: Task<Void, Never>?
    init(transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network) { self.transport = transport }
    func endpoint(id: Int, for target: String) -> String? {
        guard self.target == target, !isWorking else { return nil }
        return endpoints.first(where: { $0.id == id })?.endpoint
    }
    func cancel() {
        generation = UUID(); target = nil; task?.cancel(); task = nil
        isWorking = false; endpoints = []; failure = nil
    }
    func load(for target: String) {
        guard (retryUntil ?? .distantPast) <= Date() else { return }
        cancel(); self.target = target
        let generation = self.generation, transport = self.transport
        isWorking = true
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "https://ingest.twitch.tv/ingests")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.httpMethod = "GET"
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                guard let self, self.generation == generation, self.target == target else { return }
                try ProviderFailure.check(data: data, response: response)
                let endpoints = try TwitchIngestEndpoint.parse(data)
                guard !endpoints.isEmpty else { throw ProviderFailure(.unavailable) }
                self.endpoints = endpoints; self.isWorking = false; self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation, self.target == target else { return }
                let failure = error as? ProviderFailure ?? .init(.unavailable)
                self.failure = failure
                self.isWorking = false; self.task = nil
                if failure.kind == .rateLimited {
                    let delay = max(1, failure.retryAfter ?? 60)
                    self.retryUntil = Date().addingTimeInterval(delay)
                    self.cooldown?.cancel()
                    self.cooldown = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        self?.retryUntil = nil; self?.cooldown = nil
                    }
                }
            }
        }
    }
}
