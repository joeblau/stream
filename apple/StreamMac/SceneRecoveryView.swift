import SwiftUI

struct SceneRecoveryView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    let backup: StudioWorkspace.Backup
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recover Scenes", systemImage: "arrow.counterclockwise")
                .font(.title2)
            Text("The saved scene document could not be read. Its original bytes were preserved alongside the project. Review this last valid backup before restoring it.")
            Text(backup.label).font(.headline)
            List(backup.document.scenes) { scene in
                Text(scene.name)
            }
            HStack {
                Button("Continue with Current Scenes") { workspace.sceneRecovery = nil }
                Spacer()
                Button("Restore Backup") { Task { await workspace.restore(backup) } }
                    .disabled(!workspace.canSwitch)
            }
            if let error = workspace.error { Text(error).foregroundStyle(.orange) }
        }
        .padding(20).frame(width: 620, height: 420)
        .interactiveDismissDisabled()
    }
}
