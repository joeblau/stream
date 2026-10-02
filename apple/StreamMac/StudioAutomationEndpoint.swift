import AppKit
import Foundation
import StreamCore

/// The app owns one active runtime. This weak binding never creates a second
/// controller graph and rejects a stale profile during a switch/restore gap.
@MainActor
final class StudioAutomationEndpoint {
    static let shared = StudioAutomationEndpoint()
    private weak var dispatcher: StudioCommandDispatcher?
    private weak var permissions: PermissionsManager?
    private var directory: URL?
    private var name = "Current Show Profile"
    private var layers: () -> [LayerNode] = { [] }
    private let defaults: UserDefaults
    var interactionBlocked = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func bind(dispatcher: StudioCommandDispatcher, permissions: PermissionsManager,
              profileName: String = "Current Show Profile", stagedLayers: @escaping () -> [LayerNode]) {
        self.dispatcher = dispatcher; self.permissions = permissions
        directory = DesktopStorage.projectDirectory; name = profileName; layers = stagedLayers
    }
    func unbind() { dispatcher = nil; permissions = nil; directory = nil; layers = { [] } }
    var isBound: Bool { dispatcher != nil && directory == DesktopStorage.projectDirectory }
    var currentProfile: (id: String, name: String)? { isBound ? (directory!.lastPathComponent, name) : nil }
    var sceneChoices: [(resource: StudioAutomationResource, name: String)] {
        guard let currentProfile, let dispatcher else { return [] }
        return dispatcher.state.scenes.map { (.init(profileID: currentProfile.id, sceneID: $0.id.rawValue), $0.name) }
    }
    var layerChoices: [(resource: StudioAutomationResource, name: String)] {
        guard let currentProfile, let sceneID = dispatcher?.state.stagedSceneID else { return [] }
        return layers().map { (.init(profileID: currentProfile.id, sceneID: sceneID.rawValue, layerID: $0.id.rawValue), $0.name) }
    }
    func awaitRuntime() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !isBound {
            try Task.checkCancellation()
            guard Date() < deadline else { throw StudioAutomationFailure(code: "runtimeUnavailable", message: "Open the studio and its intended show profile, then run this action again.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func focusStudio() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && !window.isSheet {
            window.makeKeyAndOrderFront(nil); break
        }
    }
    func snapshot(profileID: String) throws -> StudioAutomationSnapshot {
        let dispatcher = try activeDispatcher(profileID: profileID)
        permissions?.refresh()
        return makeSnapshot(dispatcher.state)
    }
    func execute(_ request: StudioAutomationRequest) throws -> StudioAutomationSnapshot {
        if let error = request.validationError { throw error }
        let dispatcher = try activeDispatcher(profileID: request.profileID)
        guard defaults.bool(forKey: "onboarding.hasCompletedFirstRun"), !interactionBlocked,
              NSApp.modalWindow == nil, !hasSheet else {
            throw StudioAutomationFailure(code: "interactionRequired", message: "Finish setup or the visible studio dialog before running automation.")
        }
        permissions?.refresh()
        let command: StudioCommand
        switch request.operation {
        case .selectScene: command = .selectScene(SceneID(request.sceneID!))
        case .take, .revert:
            guard dispatcher.state.stagedSceneID?.rawValue == request.sceneID else {
                throw StudioAutomationFailure(code: "invalidTarget", message: "The requested scene is not staged. Select it explicitly before Take or Revert.")
            }
            command = request.operation == .take ? .take : .revert
        case .setLayerVisibility:
            command = .setLayerVisibility(LayerID(request.layerID!), visible: request.visible!, in: SceneID(request.sceneID!))
        case .startPreview: command = .startPreview
        case .stopPreview: command = .stopPreview
        case .startRecording: command = .startRecording
        case .stopRecording: command = .stopRecording
        }
        if let error = dispatcher.availabilityError(for: command) { throw failure(error) }
        let outputActive = dispatcher.state.preview == .active || dispatcher.state.stream.isActive || dispatcher.state.recording.isActive
        if request.operation == .startPreview || request.operation == .startRecording
            || (outputActive && (request.operation == .selectScene || request.operation == .take || request.visible == true)) {
            let missing = missingPermissions(dispatcher.automationCapturePermissions(for: command))
            guard missing.isEmpty else {
                throw StudioAutomationFailure(code: "permissionRequired", message: "Enable \(missing.map(\.title).sorted().joined(separator: ", ")) in the studio's permission controls before starting capture. Automation does not request permissions.")
            }
        }
        let result = dispatcher.execute(command)
        if let error = result.error { throw failure(error) }
        // Acceptance is not a promise that an asynchronous output has become
        // active: return its actual post-dispatch state, including preparing.
        return makeSnapshot(result.state)
    }
    private func activeDispatcher(profileID: String) throws -> StudioCommandDispatcher {
        guard isBound, let dispatcher, let directory else { throw StudioAutomationFailure(code: "runtimeUnavailable", message: "The studio is changing show profiles or has not opened yet.") }
        guard directory.lastPathComponent == profileID else { throw StudioAutomationFailure(code: "profileChanged", message: "Open the show profile saved in this shortcut. Automation does not select a different active session.") }
        return dispatcher
    }
    private var hasSheet: Bool {
        for window in NSApp.windows where window.attachedSheet != nil { return true }
        return false
    }
    private func missingPermissions(_ required: Set<PermissionsManager.Kind>) -> [PermissionsManager.Kind] {
        var missing: [PermissionsManager.Kind] = []
        // Keep MainActor permission checks outside a generic Bool predicate.
        for kind in required where permissions?.status(for: kind) != .granted { missing.append(kind) }
        return missing
    }
    private func makeSnapshot(_ state: StudioState) -> StudioAutomationSnapshot {
        let permissions = Dictionary(uniqueKeysWithValues: PermissionsManager.Kind.allCases.map { kind in
            (kind.rawValue, String(describing: self.permissions?.status(for: kind) ?? .needsRequest))
        })
        return StudioAutomationSnapshot(version: 1, profileID: directory!.lastPathComponent, profileName: name,
            stream: label(state.stream), recording: label(state.recording), preview: label(state.preview),
            stagedSceneID: state.stagedSceneID?.rawValue, programSceneID: state.programSceneID?.rawValue,
            pendingStagedEdits: state.hasPendingStagedEdits, directLiveEditing: state.directLiveEditing,
            permissions: permissions, unavailablePermissions: missingPermissions(dispatcher?.automationCapturePermissions(for: nil) ?? []).map(\.rawValue).sorted())
    }
    private func label<T>(_ state: T) -> String { String(describing: state).split(separator: "(", maxSplits: 1).first.map(String.init) ?? "unknown" }
    private func failure(_ error: StudioCommandError) -> StudioAutomationFailure {
        switch error {
        case .invalidTarget(let message): return .init(code: "invalidTarget", message: message)
        case .invalidValue(let message): return .init(code: "invalidValue", message: message)
        case .unavailable(let message): return .init(code: "unavailable", message: message)
        }
    }
}
