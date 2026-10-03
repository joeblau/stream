import Combine
import Foundation
import StreamCore

/// A draft editor for one project's destinations. Secrets stay in memory until
/// Apply and persist only to machine Keychain accounts keyed by destination ID.
@MainActor
final class DestinationSession: ObservableObject {
    @Published private(set) var saved: [StreamDestination] = []
    @Published var draft: [StreamDestination] = []
    @Published var selectedID: UUID?
    @Published var credentials: [UUID: DestinationCredentials] = [:]
    @Published var errorMessage: String?
    @Published var measuredUplinkMbps: Double = UserDefaults.standard.double(forKey: "destinations.measuredUplinkMbps") {
        didSet { UserDefaults.standard.set(measuredUplinkMbps, forKey: "destinations.measuredUplinkMbps") }
    }
    @Published var measuredSessionLimit: Int = UserDefaults.standard.integer(forKey: "destinations.measuredSessionLimit") {
        didSet { UserDefaults.standard.set(measuredSessionLimit, forKey: "destinations.measuredSessionLimit") }
    }
    func encodingPlan(program: OutputProfile) -> DestinationEncodingPlan {
        DestinationEncodingPlan(destinations: enabled, program: program,
            measuredUplinkMbps: measuredUplinkMbps > 0 ? measuredUplinkMbps : nil,
            measuredSessionLimit: measuredSessionLimit > 0 ? measuredSessionLimit : nil,
            shareH264AAC: sharesFixedH264AAC)
    }

    @Published var sharesFixedH264AAC = false {
        didSet {
            guard encodingPolicyLoaded, !updatingEncodingPolicy else { return }
            updatingEncodingPolicy = true
            defer { updatingEncodingPolicy = false }
            if !saveEncodingPolicy() { sharesFixedH264AAC = oldValue }
        }
    }
    private struct EncodingPolicy: Codable { var version = 1; var sharesFixedH264AAC: Bool }
    private var encodingPolicyLoaded = false
    private var updatingEncodingPolicy = false
    private var encodingPolicyURL: URL?
    private func saveEncodingPolicy() -> Bool {
        guard let url = encodingPolicyURL else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                  size.intValue <= 16_384, let data = try? Data(contentsOf: url),
                  let old = try? JSONDecoder().decode(EncodingPolicy.self, from: data), old.version == 1 else {
                errorMessage = "This project's encoding preference could not be read by this version. Its existing document was preserved."
                return false
            }
        }
        do {
            try ProjectDocumentHistory.write(JSONEncoder().encode(EncodingPolicy(sharesFixedH264AAC: sharesFixedH264AAC)), to: url)
            return true
        } catch {
            errorMessage = "Could not save the fixed sharing preference. \(error.localizedDescription)"
            return false
        }
    }

    private var savedCredentials: [UUID: DestinationCredentials] = [:]
    private let store: DestinationStore

    init(fileURL: URL = DesktopStorage.projectDirectory.appendingPathComponent("destinations.json"),
         settings: StreamSettings, legacyStore: DesktopSettingsStore = DesktopSettingsStore()) {
        store = DestinationStore(fileURL: fileURL)
        encodingPolicyURL = fileURL.deletingLastPathComponent().appendingPathComponent("destination-encoding.v1.json")
        if let url = encodingPolicyURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           size.intValue <= 16_384, let data = try? Data(contentsOf: url),
           let policy = try? JSONDecoder().decode(EncodingPolicy.self, from: data), policy.version == 1 {
            sharesFixedH264AAC = policy.sharesFixedH264AAC
        }
        encodingPolicyLoaded = true
        do {
            saved = try store.migrateLegacyIfNeeded(settings: settings,
                                                    connection: legacyStore.connectionSecrets(for:))
            draft = saved
            savedCredentials = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, store.credentials(for: $0.id)) })
            credentials = savedCredentials
            selectedID = saved.first(where: \.isEnabled)?.id ?? saved.first?.id
        } catch {
            errorMessage = "Could not load destinations. \(error.localizedDescription)"
        }
    }

    var isDirty: Bool { draft != saved || credentials != savedCredentials }
    var errors: [String] {
        draft.flatMap { destination in
            DestinationValidator.errors(destination, credentials: credentials[destination.id] ?? .init())
                .map { "\(destination.name): \($0)" }
        }
    }
    var canApply: Bool { isDirty && errors.isEmpty }
    var enabled: [StreamDestination] { saved.filter(\.isEnabled) }

    func create(_ transport: StreamProtocol) {
        let destination = StreamDestination(name: "New \(transport.displayName)", transport: transport,
                                            isEnabled: saved.isEmpty && draft.isEmpty)
        draft.append(destination)
        credentials[destination.id] = .init()
        selectedID = destination.id
    }

    func create(_ template: DestinationProviderTemplate, transport: StreamProtocol) {
        let destination = template.makeDestination(transport: transport)
        draft.append(destination)
        credentials[destination.id] = .init()
        selectedID = destination.id
    }

    func createManual(_ provider: ManagedProvider) {
        let destination = StreamDestination(name: "\(provider.name) Manual RTMPS", isEnabled: false)
        draft.append(destination); credentials[destination.id] = .init(); selectedID = destination.id
    }

    func createManaged(provider: ManagedProvider, channel: ProviderChannel, event: ProviderEvent? = nil,
                       connection: DestinationCredentials) {
        let transport: StreamProtocol = URL(string: connection.endpoint)?.scheme == "rtmp" ? .rtmp : .rtmps
        let destination = StreamDestination(name: "\(provider.name): \(event?.title ?? channel.title)",
            transport: transport, isEnabled: false, videoCodec: .h264,
            providerBinding: .init(provider: provider, channelID: channel.id, eventID: event?.id))
        draft.append(destination); credentials[destination.id] = connection; selectedID = destination.id
    }

    func duplicate(_ id: UUID) {
        guard let source = draft.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated()
        draft.append(copy)
        credentials[copy.id] = credentials[id] ?? .init()
        selectedID = copy.id
    }

    func remove(_ id: UUID) {
        draft.removeAll { $0.id == id }
        credentials[id] = nil
        if selectedID == id { selectedID = draft.first?.id }
    }

    @discardableResult
    func apply() -> Bool {
        guard errors.isEmpty else { errorMessage = errors.joined(separator: "\n"); return false }
        do {
            try store.save(draft, credentials: credentials)
            saved = draft
            savedCredentials = credentials
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func revert() {
        draft = saved
        credentials = savedCredentials
        if !draft.contains(where: { $0.id == selectedID }) { selectedID = draft.first?.id }
        errorMessage = nil
    }

    func savedCredentials(for id: UUID) -> DestinationCredentials { savedCredentials[id] ?? .init() }

    func startErrors(program: OutputProfile) -> [String] {
        if enabled.isEmpty { return ["Enable a destination in the Destinations panel before going live."] }
        return encodingPlan(program: program).issues + enabled.flatMap { destination in
            DestinationValidator.startErrors(destination, credentials: savedCredentials(for: destination.id), program: program)
                .map { "\(destination.name): \($0)" }
        }
    }
}
