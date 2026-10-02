import SwiftUI
import StreamCore

struct ProjectBrowserView: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    @State private var name = ""
    @State private var includeArchived = false
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Shows and Profiles", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button("Close") { workspace.showProjects = false }
            }
            HStack {
                TextField("Project or profile name", text: $name)
                Button("New Show") { workspace.create(named: name); name = "" }
                Button("Duplicate Show") { workspace.create(named: name, duplicate: true); name = "" }
                Button("New Profile") { workspace.addProfile(named: name, duplicate: false); name = "" }
                Button("Duplicate Profile") { workspace.addProfile(named: name, duplicate: true); name = "" }
            }
            .disabled(!StudioProjectCatalog.validName(name))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.catalog.projects.filter { includeArchived || !$0.isArchived }) { project in
                        HStack {
                            Text(project.name).fontWeight(project.id == workspace.currentProject.id ? .bold : .regular)
                            if project.isArchived { Text("Archived").foregroundStyle(.secondary) }
                            ForEach(project.profiles) { profile in
                                Button {
                                    workspace.stage(project: project.id, profile: profile.id)
                                } label: {
                                    Label(profile.name, systemImage: profile.id == workspace.currentProfile.id ? "checkmark.circle.fill" : "circle")
                                }
                                .accessibilityLabel("Stage \(project.name), \(profile.name)")
                            }
                            Spacer()
                            Button("Rename") { workspace.rename(project.id, to: name); name = "" }
                                .disabled(!StudioProjectCatalog.validName(name))
                            Button(project.isArchived ? "Unarchive" : "Archive") {
                                workspace.archive(project.id, archived: !project.isArchived)
                            }.disabled(project.id == workspace.currentProject.id)
                        }
                    }
                }
            }.frame(maxHeight: 140)
            Toggle("Show archived projects", isOn: $includeArchived)
            Button("Backup History…") { showHistory = true }
            if workspace.pending != nil {
                HStack {
                    Text(workspace.canSwitch ? "Apply opens the staged show and stops local preview." : "Stop streaming and recording before applying the staged show.")
                        .font(.caption)
                    Spacer()
                    Button("Cancel") { workspace.pending = nil }
                    Button("Apply Show / Profile") { Task { await workspace.applyPending() } }
                        .disabled(!workspace.canSwitch)
                }
            }
            if workspace.recoveryFile != nil {
                Label("The catalog was unreadable. Review the recovered shows before saving; the original will be preserved.", systemImage: "exclamationmark.triangle")
                Button("Use Recovered Catalog") { workspace.acceptRecoveredCatalog() }
            }
            if let error = workspace.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(12)
        .background(.regularMaterial)
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scene Backup History").font(.headline)
                Text("Restoring replaces scenes and styles after stopping local preview. Stop streaming and recording first. Assets stay in the project.")
                List(workspace.sceneBackups) { backup in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(backup.label)
                            Text(backup.document.scenes.map(\.name).joined(separator: ", ")).font(.caption)
                        }
                        Spacer()
                        Button("Restore") { Task { await workspace.restore(backup); showHistory = false } }
                            .disabled(!workspace.canSwitch)
                    }
                }
                Button("Close") { showHistory = false }
            }.padding(20).frame(width: 620, height: 380)
        }
    }
}
