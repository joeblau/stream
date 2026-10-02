import AppKit
import AppIntents
import Foundation

struct GraphID<Tag>: Hashable, Sendable { var rawValue: UUID; init(_ id: UUID = UUID()) { rawValue = id } }
enum SceneTag {}; enum LayerTag {}
typealias SceneID = GraphID<SceneTag>; typealias LayerID = GraphID<LayerTag>
struct LayerNode { var id: LayerID; var name: String }
enum StudioCommand { case selectScene(SceneID), take, revert, setLayerVisibility(LayerID, visible: Bool, in: SceneID?), startPreview, stopPreview, startRecording, stopRecording }
enum StudioCommandError: Error { case invalidTarget(String), invalidValue(String), unavailable(String) }
enum PreviewState { case idle, active }
enum OutputState { case idle, preparing, active; var isActive: Bool { self != .idle } }
struct StudioState {
    struct SceneRef { let id: SceneID; var name: String }
    var scenes: [SceneRef] = []; var stagedSceneID: SceneID?; var programSceneID: SceneID?
    var preview: PreviewState = .idle; var stream: OutputState = .idle; var recording: OutputState = .idle
    var hasPendingStagedEdits = false; var directLiveEditing = false
}
struct StudioCommandResult { var error: StudioCommandError?; var state: StudioState }
@MainActor enum DesktopStorage { static var projectDirectory = URL(fileURLWithPath: "/tmp/automation/profile-a") }
@MainActor final class PermissionsManager {
    enum Kind: String, CaseIterable { case camera, microphone, screenCapture; var title: String { rawValue } }
    enum Status { case needsRequest, granted, denied }
    var statuses: [Kind: Status] = [.camera: .granted, .microphone: .granted, .screenCapture: .granted]
    var refreshes = 0
    func refresh() { refreshes += 1 }
    func status(for kind: Kind) -> Status { statuses[kind] ?? .needsRequest }
}
@MainActor final class StudioCommandDispatcher {
    var state = StudioState(); var executions = 0; var rejection: StudioCommandError?
    var required: Set<PermissionsManager.Kind> = [.microphone]
    func automationCapturePermissions(for command: StudioCommand?) -> Set<PermissionsManager.Kind> { required }
    func availabilityError(for command: StudioCommand) -> StudioCommandError? {
        if let rejection { return rejection }
        if case .selectScene(let id) = command, !state.scenes.contains(where: { $0.id == id }) { return .invalidTarget("Scene was deleted.") }
        return nil
    }
    func execute(_ command: StudioCommand) -> StudioCommandResult {
        if let error = availabilityError(for: command) { return .init(error: error, state: state) }
        executions += 1
        switch command {
        case .selectScene(let id): state.stagedSceneID = id
        case .take: state.programSceneID = state.stagedSceneID
        case .startPreview: state.preview = .active
        case .stopPreview: state.preview = .idle
        case .startRecording: state.recording = .preparing
        case .stopRecording: state.recording = .idle
        default: break
        }
        return .init(error: nil, state: state)
    }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
@MainActor func expectFailure(_ code: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection: \(code)") }
    catch let error as StudioAutomationFailure {
        check(error.code == code, "Expected \(code), got \(error.code)")
        let ns = error as NSError; check(ns.userInfo["StudioErrorCode"] as? String == code, "Missing structured error code")
    } catch { fatalError("Unexpected error: \(error)") }
}
@main struct Harness {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "stream.automation.harness.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = StudioAutomationEndpoint(defaults: defaults)
        let scene = SceneID(), second = SceneID(), layer = LayerID()
        let dispatcher = StudioCommandDispatcher(), permissions = PermissionsManager()
        dispatcher.state.scenes = [.init(id: scene, name: "Intro"), .init(id: second, name: "Closing")]
        dispatcher.state.stagedSceneID = scene
        var layers = [LayerNode(id: layer, name: "Camera")]
        endpoint.bind(dispatcher: dispatcher, permissions: permissions, profileName: "Demo / Main", stagedLayers: { layers })
        check(endpoint.currentProfile?.id == "profile-a", "Explicit profile scope missing")
        let target = StudioAutomationResource(profileID: "profile-a", sceneID: scene.rawValue, layerID: layer.rawValue)
        check(StudioAutomationResource(id: target.id) == target, "Resource scope round-trip failed")
        for id in ["../profile|\(scene.rawValue)", "profile-a|bad", "profile-a|\(scene.rawValue)|bad", "profile-a|\(scene.rawValue)|\(layer.rawValue)|extra"] {
            check(StudioAutomationResource(id: id) == nil, "Malformed resource accepted")
        }
        let unknownPublic = Data("{\"version\":1,\"profileID\":\"profile-a\",\"operation\":\"startStream\"}".utf8)
        check((try? JSONDecoder().decode(StudioAutomationRequest.self, from: unknownPublic)) == nil, "Public stream start must be absent from the schema")
        let select = StudioAutomationRequest(profileID: "profile-a", operation: .selectScene, sceneID: scene.rawValue)
        expectFailure("interactionRequired") { _ = try endpoint.execute(select) }
        check(dispatcher.executions == 0, "Setup rejection performed work")
        defaults.set(true, forKey: "onboarding.hasCompletedFirstRun")
        endpoint.interactionBlocked = true
        expectFailure("interactionRequired") { _ = try endpoint.execute(select) }; endpoint.interactionBlocked = false
        expectFailure("profileChanged") { _ = try endpoint.execute(.init(profileID: "profile-b", operation: .startRecording)) }
        expectFailure("invalidTarget") { _ = try endpoint.execute(.init(profileID: "profile-a", operation: .take, sceneID: second.rawValue)) }
        expectFailure("versionMismatch") { _ = try endpoint.execute(.init(version: 2, profileID: "profile-a", operation: .stopPreview)) }
        expectFailure("invalidValue") { _ = try endpoint.execute(.init(profileID: "profile-a", operation: .startRecording, sceneID: scene.rawValue)) }
        dispatcher.state.scenes[0].name = "Renamed Intro"
        check(endpoint.sceneChoices.first?.name == "Renamed Intro", "Rename lost stable identity")
        check(endpoint.sceneChoices.first?.resource.sceneID == scene.rawValue, "Rename retargeted UUID")
        layers[0].name = "Renamed Camera"; check(endpoint.layerChoices.first?.name == "Renamed Camera", "Layer query is stale")
        dispatcher.state.scenes.removeFirst()
        expectFailure("invalidTarget") { _ = try endpoint.execute(select) }
        dispatcher.state.scenes.insert(.init(id: scene, name: "Renamed Intro"), at: 0)
        permissions.statuses[.microphone] = .denied
        expectFailure("permissionRequired") { _ = try endpoint.execute(.init(profileID: "profile-a", operation: .startRecording)) }
        check(dispatcher.executions == 0, "Rejected automation performed work")
        // Scene preparation without an active output doesn't start capture.
        _ = try endpoint.execute(select); check(dispatcher.executions == 1, "Idle preparation was unnecessarily blocked")
        permissions.statuses[.microphone] = .granted
        let acknowledged = try endpoint.execute(.init(profileID: "profile-a", operation: .startRecording))
        check(acknowledged.recording == "preparing", "Acceptance invented an active recording")
        permissions.statuses[.camera] = .denied; dispatcher.required.insert(.camera)
        expectFailure("permissionRequired") { _ = try endpoint.execute(select) }
        dispatcher.rejection = .unavailable("A transition is already running.")
        expectFailure("unavailable") { _ = try endpoint.execute(select) }; dispatcher.rejection = nil
        let json = String(decoding: try JSONEncoder().encode(endpoint.snapshot(profileID: "profile-a")), as: UTF8.self)
        check(json.contains("permissions") && !json.contains("token"), "Snapshot leaks credentials or loses permission context")
        let beforeSwitch = dispatcher.executions
        DesktopStorage.projectDirectory = URL(fileURLWithPath: "/tmp/automation/profile-b")
        expectFailure("runtimeUnavailable") { _ = try endpoint.execute(select) }
        check(endpoint.sceneChoices.isEmpty && dispatcher.executions == beforeSwitch, "Old runtime survived project gap")
        endpoint.unbind(); let next = StudioCommandDispatcher()
        endpoint.bind(dispatcher: next, permissions: permissions, stagedLayers: { [] })
        expectFailure("profileChanged") { _ = try endpoint.execute(select) }
        endpoint.unbind(); check(!endpoint.isBound, "Unbind retained runtime")
        check(StudioAutomationLocalOutput.allCases.count == 4, "Local-output intents advertise public output")
        print("Studio automation harness passed: typed scope/targets, rename/delete, setup/permission gates, shared availability, authoritative preparing state, switch/rebind, no public start.")
    }
}
