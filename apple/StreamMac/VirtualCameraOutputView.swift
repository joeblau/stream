import SwiftUI

/// Embed this view in the main-window output section with a runtime-owned
/// controller. Activation only occurs from its explicit operator button.
struct VirtualCameraOutputView: View {
    @ObservedObject var output: VirtualCameraOutputController
    @EnvironmentObject private var controller: StreamController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Virtual Camera").font(.headline)
            Text(output.activation.description).font(.caption).foregroundStyle(.secondary)
            Label(output.deviceAvailable ? "Camera device available" : "Camera device unavailable", systemImage: "video")
            HStack {
                Button("Activate Camera Extension") { output.activateExtension() }
                Button("Remove Camera Extension") { output.removeExtension() }
                Button("Refresh") { output.refresh() }
            }.disabled(output.activation == .requesting)
            Picker("Camera input format", selection: $output.format) {
                ForEach(VirtualCameraFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }.disabled(output.isActive)
            Picker("Feed", selection: $output.feed) {
                Text("Composed Program").tag(ExternalDisplayFeed.program)
                Text("Destination canvas").tag(ExternalDisplayFeed.selectedCanvas)
                Text("Secondary layout").tag(ExternalDisplayFeed.secondaryCanvas)
            }.disabled(output.isActive)
            if output.feed == .selectedCanvas {
                Picker("Canvas", selection: $output.selectedDestinationID) {
                    Text("Choose destination").tag(Optional<UUID>.none)
                    ForEach(controller.destinations.saved) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(output.isActive)
            }
            Button(output.isActive ? "Stop Virtual Camera" : "Start Virtual Camera") {
                if output.isActive { output.stop() }
                else {
                    let selected = controller.destinations.saved.first { $0.id == output.selectedDestinationID }
                    output.start(programAvailable: true,
                        selectedProfile: output.feed == .secondaryCanvas
                            ? (controller.secondaryCanvasAvailable ? controller.activeSecondaryProfile : nil)
                            : controller.profileForOutputDestination(selected))
                }
            }.disabled(!output.isActive && !output.deviceAvailable)
            if let error = output.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if output.isActive { Text("Frames sent: \(output.sentFrames) · dropped: \(output.droppedFrames)").font(.caption.monospacedDigit()) }
            Text("Choose Stream Studio Camera in the receiving app. Camera clients negotiate 720p or 1080p at 30 fps. This is video only. Stop, studio exit, sleep or a stalled feed gives clients black video; start again manually after returning.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
