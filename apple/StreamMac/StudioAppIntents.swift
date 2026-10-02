import AppIntents
import Foundation

struct StudioAutomationProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show Profile"
    static let defaultQuery = StudioAutomationProfileQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct StudioAutomationProfileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudioAutomationProfileEntity] {
        let choices = await suggestedEntities()
        return choices.filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [StudioAutomationProfileEntity] {
        let choices = await suggestedEntities()
        return choices.filter { string.isEmpty || $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async -> [StudioAutomationProfileEntity] {
        await MainActor.run {
            guard let profile = StudioAutomationEndpoint.shared.currentProfile else { return [] }
            return [.init(id: profile.id, name: profile.name)]
        }
    }
}
struct StudioAutomationSceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Studio Scene"
    static let defaultQuery = StudioAutomationSceneQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct StudioAutomationSceneQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudioAutomationSceneEntity] {
        let choices = await suggestedEntities()
        return choices.filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [StudioAutomationSceneEntity] {
        let choices = await suggestedEntities()
        return choices.filter { string.isEmpty || $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async -> [StudioAutomationSceneEntity] {
        await MainActor.run { StudioAutomationEndpoint.shared.sceneChoices.map { .init(id: $0.resource.id, name: $0.name) } }
    }
}
struct StudioAutomationLayerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Staged Scene Layer"
    static let defaultQuery = StudioAutomationLayerQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct StudioAutomationLayerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudioAutomationLayerEntity] {
        let choices = await suggestedEntities()
        return choices.filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [StudioAutomationLayerEntity] {
        let choices = await suggestedEntities()
        return choices.filter { string.isEmpty || $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async -> [StudioAutomationLayerEntity] {
        await MainActor.run { StudioAutomationEndpoint.shared.layerChoices.map { .init(id: $0.resource.id, name: $0.name) } }
    }
}
enum StudioAutomationLocalOutput: String, AppEnum {
    case startPreview, stopPreview, startRecording, stopRecording
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Local Output Action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .startPreview: "Start Local Preview", .stopPreview: "Stop Local Preview",
        .startRecording: "Start Local Recording", .stopRecording: "Stop Local Recording"]
}
enum StudioAutomationStagedAction: String, AppEnum {
    case take, revert
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Staged Scene Action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.take: "Take Preview to Program", .revert: "Revert Preview"]
}

struct OpenStreamStudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Stream Studio"
    static let description = IntentDescription("Open or focus the one persistent studio window without starting a public broadcast.")
    // Retain the macOS 14-compatible foreground declaration. supportedModes
    // is only available on newer OS versions.
    static let openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        StudioAutomationEndpoint.shared.focusStudio()
        return .result()
    }
}
struct GetStreamStudioStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Stream Studio State"
    static let description = IntentDescription("Return a versioned JSON snapshot and permission context for the explicitly selected, open show profile. Contains no credentials.")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Show Profile") var profile: StudioAutomationProfileEntity
    static var parameterSummary: some ParameterSummary { Summary("Get studio state for \(\.$profile)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await StudioAutomationEndpoint.shared.awaitRuntime()
        StudioAutomationEndpoint.shared.focusStudio()
        return .result(value: try automationJSON(StudioAutomationEndpoint.shared.snapshot(profileID: profile.id)))
    }
}
struct SelectStreamStudioSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Stream Studio Scene"
    static let description = IntentDescription("Select a stable scene in its saved show profile. Obeys the studio's current preview/program mode and requires any capture permissions to be granted in the studio.")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Scene") var scene: StudioAutomationSceneEntity
    static var parameterSummary: some ParameterSummary { Summary("Select \(\.$scene) in the studio") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let target = try automationResource(scene.id, expectsLayer: false)
        return .result(value: try await runAutomation(.init(profileID: target.profileID, operation: .selectScene, sceneID: target.sceneID)))
    }
}
struct ApplyStreamStudioStagedSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Take or Revert Stream Studio Scene"
    static let description = IntentDescription("Take or Revert only when this explicit scene is currently staged. The action never silently selects another scene first.")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Action") var action: StudioAutomationStagedAction
    @Parameter(title: "Expected Staged Scene") var scene: StudioAutomationSceneEntity
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) for \(\.$scene)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let target = try automationResource(scene.id, expectsLayer: false)
        let operation: StudioAutomationOperation = action == .take ? .take : .revert
        return .result(value: try await runAutomation(.init(profileID: target.profileID, operation: operation, sceneID: target.sceneID)))
    }
}
struct SetStreamStudioLocalOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Stream Studio Local Output"
    static let description = IntentDescription("Explicitly start or stop local preview or recording in the saved, open show profile. Starting capture requires existing permission grants; this action does not start a public stream.")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Action") var action: StudioAutomationLocalOutput
    @Parameter(title: "Show Profile") var profile: StudioAutomationProfileEntity
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) in \(\.$profile)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let operation = StudioAutomationOperation(rawValue: action.rawValue)!
        return .result(value: try await runAutomation(.init(profileID: profile.id, operation: operation)))
    }
}
struct SetStreamStudioLayerVisibilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Stream Studio Layer Visibility"
    static let description = IntentDescription("Show or hide an explicit layer in its saved staged scene. Respects scene/layer locks and the studio's preview/program policy.")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Layer") var layer: StudioAutomationLayerEntity
    @Parameter(title: "Visible") var visible: Bool
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$layer) visibility to \(\.$visible)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let target = try automationResource(layer.id, expectsLayer: true)
        return .result(value: try await runAutomation(.init(profileID: target.profileID, operation: .setLayerVisibility,
            sceneID: target.sceneID, layerID: target.layerID, visible: visible)))
    }
}
struct StreamStudioAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenStreamStudioIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "Open Studio", systemImageName: "video")
    }
}
private func automationResource(_ id: String, expectsLayer: Bool) throws -> StudioAutomationResource {
    guard let resource = StudioAutomationResource(id: id), (resource.layerID != nil) == expectsLayer else {
        throw StudioAutomationFailure(code: "invalidTarget", message: "Choose an explicit resource from the open show profile.")
    }
    return resource
}
@MainActor private func runAutomation(_ request: StudioAutomationRequest) async throws -> String {
    try await StudioAutomationEndpoint.shared.awaitRuntime()
    try Task.checkCancellation()
    StudioAutomationEndpoint.shared.focusStudio()
    return try automationJSON(StudioAutomationEndpoint.shared.execute(request))
}
private func automationJSON(_ snapshot: StudioAutomationSnapshot) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
}
