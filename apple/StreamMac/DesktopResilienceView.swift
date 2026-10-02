import SwiftUI
import StreamCore

/// Project-scoped fallback controls; every restore/start is an operator action.
struct DesktopResilienceView: View {
    @ObservedObject var coordinator: DesktopResilienceCoordinator
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var scenes: SceneStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = coordinator.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Picker("Failed source", selection: $coordinator.policy.defaultSourceMode) {
                ForEach(SourceFailureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Standby scene", selection: $coordinator.policy.standbySceneID) {
                Text("Use each source's fallback").tag(Optional<UUID>.none)
                ForEach(scenes.scenes) { Text($0.name).tag(Optional($0.id.rawValue)) }
            }
            ForEach(scenes.sources.filter(isVideoSource)) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(source.name, selection: mode(source.id.rawValue)) {
                        ForEach(SourceFailureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if mode(source.id.rawValue).wrappedValue == .standby {
                        Picker("Standby video", selection: standby(source.id.rawValue)) {
                            Text("None — show offline card").tag(Optional<UUID>.none)
                            ForEach(scenes.sources.filter { $0.id != source.id && isVideoSource($0) }) {
                                Text($0.name).tag(Optional($0.id.rawValue))
                            }
                        }
                    }
                }
            }
            Toggle("Restore recovered sources automatically", isOn: $coordinator.policy.automaticallyRestoreSources)
            Picker("On screen lock / inactive user session", selection: $coordinator.policy.lockAction) {
                ForEach(DesktopResiliencePolicy.LockAction.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Resume preview after wake", isOn: $coordinator.policy.previewAfterWake)
            ForEach(controller.sourceFailoverStatus, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Button("Restore Recovered Sources / Program") { controller.restoreResilienceProgram() }
                .disabled(coordinator.isLocked)
            Text("Sleep stops outputs. Wake and unlock never start publishing or recording. Standby video replaces pixels; audio retains the program mixer routing. A standby scene changes scene-bound audio. Freeze retains at most one frame per demanded source. Failed standby video shows an offline card.")
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: coordinator.policy) { _, _ in coordinator.save() }
    }
    private func isVideoSource(_ source: SourceDefinition) -> Bool {
        switch source.payload {
        case .camera, .screen, .media, .pdf, .web, .syphon: return true
        default: return false
        }
    }
    private func mode(_ id: UUID) -> Binding<SourceFailureMode> {
        Binding(get: { coordinator.policy.sourceRules.first { $0.sourceID == id }?.mode ?? coordinator.policy.defaultSourceMode },
                set: { value in update(id) { $0.mode = value } })
    }
    private func standby(_ id: UUID) -> Binding<UUID?> {
        Binding(get: { coordinator.policy.sourceRules.first { $0.sourceID == id }?.standbySourceID },
                set: { value in update(id) { $0.standbySourceID = value } })
    }
    private func update(_ id: UUID, change: (inout SourceFailoverRule) -> Void) {
        if let index = coordinator.policy.sourceRules.firstIndex(where: { $0.sourceID == id }) {
            change(&coordinator.policy.sourceRules[index])
        } else {
            var rule = SourceFailoverRule(sourceID: id, mode: coordinator.policy.defaultSourceMode)
            change(&rule); coordinator.policy.sourceRules.append(rule)
        }
    }
}
