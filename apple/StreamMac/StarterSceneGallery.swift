import SwiftUI

struct StarterSceneGallery: View {
    @EnvironmentObject private var workspace: StudioWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var selection: StudioStarter = .desktop
    var body: some View {
        HStack(spacing: 20) {
            List(StudioStarter.allCases) { starter in
                Button(starter.rawValue) { selection = starter }
                    .fontWeight(selection == starter ? .bold : .regular)
            }.frame(width: 190)
            VStack(alignment: .leading, spacing: 14) {
                Text(selection.rawValue).font(.title2)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.075, green: 0.13, blue: 0.24))
                    VStack(spacing: 16) {
                        Text(selection.rawValue).font(.title)
                        if selection == .starting || selection == .pause { Text(selection == .starting ? "05:00" : "10:00").font(.largeTitle.monospacedDigit()) }
                        else if selection == .interview {
                            HStack { Label("Host", systemImage: "video"); Spacer(); Label("Guest slot", systemImage: "person") }.padding(20)
                        } else if selection != .ending { Label(selection == .camera ? "Camera" : "Screen / slides + camera", systemImage: selection == .camera ? "video" : "display") }
                    }.foregroundStyle(.white).padding()
                }
                .aspectRatio(workspace.runtime.controller.activeProfile.canvasSize, contentMode: .fit)
                .frame(maxHeight: 230)
                .accessibilityLabel("Template preview: \(selection.rawValue)")
                Text(selection.guidance)
                Text("Ordinary editable layers use the active \(workspace.runtime.controller.activeProfile.aspectDescription.lowercased()) canvas. Optional audio is selected locally in Sound.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Add to Preview") {
                        let sources = workspace.runtime.sceneStore.sources
                        let scene = selection.scene(camera: sources.first { $0.payload.isCamera }?.id,
                            screen: sources.first { $0.payload.isScreen }?.id, profile: workspace.runtime.controller.activeProfile)
                        workspace.runtime.dispatcher.execute(.insertScene(scene))
                        dismiss()
                    }
                }
            }.frame(width: 380)
        }.padding(20).frame(height: 440)
    }
}
