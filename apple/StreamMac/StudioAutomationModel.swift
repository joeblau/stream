import Foundation

/// Native automation deliberately exposes a small, typed set. Public stream
/// start and macro execution are absent, including when decoding raw requests.
enum StudioAutomationOperation: String, Codable, CaseIterable, Sendable {
    case selectScene, take, revert, startPreview, stopPreview, startRecording, stopRecording, setLayerVisibility
}

struct StudioAutomationRequest: Codable, Equatable, Sendable {
    var version = 1
    var profileID: String
    var operation: StudioAutomationOperation
    var sceneID: UUID?
    var layerID: UUID?
    var visible: Bool?

    var validationError: StudioAutomationFailure? {
        guard version == 1 else { return .init(code: "versionMismatch", message: "This automation request requires version 1.") }
        guard Self.validProfileID(profileID) else { return .init(code: "invalidTarget", message: "Choose an explicit show profile.") }
        switch operation {
        case .selectScene, .take, .revert:
            guard sceneID != nil, layerID == nil, visible == nil else { return .init(code: "invalidTarget", message: "Choose the explicit scene for this action.") }
        case .setLayerVisibility:
            guard sceneID != nil, layerID != nil, visible != nil else { return .init(code: "invalidTarget", message: "Choose the explicit scene, layer, and visibility.") }
        case .startPreview, .stopPreview, .startRecording, .stopRecording:
            guard sceneID == nil, layerID == nil, visible == nil else { return .init(code: "invalidValue", message: "Local output actions target a show profile, without an implicit scene change.") }
        }
        return nil
    }
    static func validProfileID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && !id.contains("/") && !id.contains("\\") && !id.contains("|") && id != "." && id != ".."
    }
}
struct StudioAutomationFailure: Error, Codable, Equatable, Sendable, LocalizedError, CustomNSError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    static var errorDomain: String { "com.joeblau.StreamMac.Automation" }
    var errorCode: Int {
        ["versionMismatch", "invalidTarget", "invalidValue", "runtimeUnavailable", "profileChanged", "interactionRequired", "permissionRequired", "unavailable"].firstIndex(of: code).map { $0 + 1 } ?? 100
    }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message, "StudioErrorCode": code] }
}
struct StudioAutomationResource: Equatable, Sendable {
    var profileID: String
    var sceneID: UUID
    var layerID: UUID?
    var id: String { ([profileID, sceneID.uuidString] + (layerID.map { [$0.uuidString] } ?? [])).joined(separator: "|") }
    init(profileID: String, sceneID: UUID, layerID: UUID? = nil) { self.profileID = profileID; self.sceneID = sceneID; self.layerID = layerID }
    init?(id: String) {
        let components = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(components.count), StudioAutomationRequest.validProfileID(components[0]), let scene = UUID(uuidString: components[1]) else { return nil }
        self.init(profileID: components[0], sceneID: scene)
        if components.count == 3 { guard let layer = UUID(uuidString: components[2]) else { return nil }; layerID = layer }
    }
}
struct StudioAutomationSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let profileID: String
    let profileName: String
    let stream: String
    let recording: String
    let preview: String
    let stagedSceneID: UUID?
    let programSceneID: UUID?
    let pendingStagedEdits: Bool
    let directLiveEditing: Bool
    let permissions: [String: String]
    let unavailablePermissions: [String]
}
