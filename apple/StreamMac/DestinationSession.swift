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
    private var savedCredentials: [UUID: DestinationCredentials] = [:]
    private let store: DestinationStore

    init(fileURL: URL = DesktopStorage.projectDirectory.appendingPathComponent("destinations.json"),
         settings: StreamSettings, legacyStore: DesktopSettingsStore = DesktopSettingsStore()) {
        store = DestinationStore(fileURL: fileURL)
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
        return enabled.flatMap { destination in
            DestinationValidator.startErrors(destination, credentials: savedCredentials(for: destination.id), program: program)
                .map { "\(destination.name): \($0)" }
        }
    }
}
