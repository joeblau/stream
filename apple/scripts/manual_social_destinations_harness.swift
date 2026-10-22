import Foundation
import StreamCore

// Only nonsecret storage identity/legacy lookup dependencies are substituted.
// An existing empty metadata file prevents migration or any Keychain lookup.
@MainActor enum DesktopStorage { static let projectDirectory = URL(fileURLWithPath: "/unused-manual-social-fixture") }
@MainActor struct DesktopSettingsStore {
    static var legacyReads = 0
    func connectionSecrets(for _: StreamProtocol) -> (url: String, key: String) {
        Self.legacyReads += 1
        preconditionFailure("An existing destination document must not read legacy credentials")
    }
}

@main @MainActor enum ManualSocialDestinationsHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-manual-social-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("destinations.json")
        try Data("[]".utf8).write(to: file)
        let session = DestinationSession(fileURL: file, settings: .default, legacyStore: DesktopSettingsStore())
        precondition(session.errorMessage == nil && session.draft.isEmpty && session.credentials.isEmpty)
        for (provider, template) in [(ManagedProvider.facebookPages, DestinationProviderTemplate.facebookPages), (.linkedinLive, .linkedinLive)] {
            session.createManual(provider)
            let id = session.selectedID!
            let index = session.draft.firstIndex { $0.id == id }!
            let destination = session.draft[index]
            precondition(destination.providerTemplate == template && destination.providerBinding == nil)
            precondition(!destination.isEnabled && destination.transport == .rtmps)
            precondition(session.credentials[id] == .init() && destination.followsProgramProfile)
            precondition(template.capabilityDisclosure.contains("Comments, viewer metrics, event scheduling and remote event state are unavailable"))
            session.draft[index].name = "Renamed " + provider.rawValue
            session.duplicate(id)
            let copy = session.draft.last!
            precondition(copy.id != id && copy.providerTemplate == template && !copy.isEnabled)
            precondition(session.credentials[copy.id] == .init() && copy.providerBinding == nil)
            let beforeDetach = session.draft[index]
            let synthetic = DestinationCredentials(endpoint: "rtmps://owned.invalid/live", streamKey: "owned-synthetic-key")
            session.credentials[id] = synthetic
            session.draft[index].providerTemplateID = nil // Exact existing Use as Custom Destination binding.
            precondition(session.draft[index].providerTemplate == nil && session.draft[index].id == id)
            precondition(session.draft[index].name == beforeDetach.name && session.draft[index].outputProfile == beforeDetach.outputProfile)
            precondition(session.credentials[id] == synthetic && session.draft[index].providerBinding == nil)
        }
        // Persist only actual Session drafts; actual Core metadata loader never
        // reads Keychain. Native Session.apply/reload credentials are not invoked.
        let data = try JSONEncoder().encode(session.draft)
        try data.write(to: file)
        let reloaded = try DestinationStore(fileURL: file).load()
        precondition(reloaded == session.draft)
        precondition(reloaded.filter { $0.providerTemplate != nil }.count == 2)
        precondition(reloaded.allSatisfy { !$0.isEnabled && $0.providerBinding == nil })
        let portable = String(decoding: data, as: UTF8.self)
        precondition(!portable.contains("streamKey") && !portable.contains("endpoint") && !portable.contains("channelID") && !portable.contains("eventID"))
        precondition(!portable.contains("owned.invalid") && !portable.contains("owned-synthetic-key"))
        precondition(DesktopSettingsStore.legacyReads == 0 && session.saved.isEmpty)
        print("PASS actual DestinationSession manual Facebook/LinkedIn creation, empty credential slots, rename, duplicate, explicit detach and actual DestinationStore metadata reload; no Apply/Keychain, OAuth, provider calls or publishers")
    }
}
