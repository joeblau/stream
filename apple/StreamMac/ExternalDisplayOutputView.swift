import SwiftUI
import StreamCore

struct ExternalDisplayOutputView: View {
    @ObservedObject var output: ExternalDisplayOutputController
    @EnvironmentObject private var controller: StreamController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("External display", selection: $output.selectedDisplayID) {
                Text("Choose display").tag(Optional<UInt32>.none)
                ForEach(output.displays.filter(\.canShowCleanOutput)) {
                    Text($0.name).tag(Optional($0.id))
                }
            }.disabled(output.isActive || output.isStarting)
            if output.displays.filter(\.canShowCleanOutput).isEmpty {
                Text("Connect another display or enable AirPlay as a display in macOS. Move the studio to a separate display before starting its clean output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Feed", selection: $output.feed) {
                Text("Program (with overlays)").tag(ExternalDisplayFeed.program)
                Text("Clean Program (no overlays or annotations)").tag(ExternalDisplayFeed.clean)
                Text("Destination canvas").tag(ExternalDisplayFeed.selectedCanvas)
                Text("Secondary layout").tag(ExternalDisplayFeed.secondaryCanvas)
            }.disabled(output.isActive || output.isStarting)
            if output.feed == .selectedCanvas {
                Picker("Canvas", selection: $output.selectedDestinationID) {
                    Text("Choose destination canvas").tag(Optional<UUID>.none)
                    ForEach(controller.destinations.saved) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(output.isActive || output.isStarting)
            }
            Picker("Display framing", selection: $output.scaling) {
                Text("Fit (letterbox)").tag(ExternalDisplayScaling.fit)
                Text("Fill (crop)").tag(ExternalDisplayScaling.fill)
            }
            switch output.state {
            case .idle:
                Text(output.isStarting ? "Preparing bounded external output…" : "External output off")
                    .font(.caption).foregroundStyle(.secondary)
            case .active: Label("External output active", systemImage: "display").foregroundStyle(.green)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Refresh Displays") { output.refreshDisplays() }
                Spacer()
                Button(output.isStarting ? "Cancel External Output" : output.isActive ? "Stop External Output" : "Start External Output") {
                    if output.isActive || output.isStarting { output.stop() }
                    else {
                        let selected = controller.destinations.saved.first { $0.id == output.selectedDestinationID }
                        output.start(programProfile: controller.activeProfile,
                                     selectedProfile: output.feed == .secondaryCanvas
                                        ? (controller.secondaryCanvasAvailable ? controller.activeSecondaryProfile : nil)
                                        : controller.profileForOutputDestination(selected))
                    }
                }.disabled(!output.isActive && !output.isStarting && output.selectedDisplayID == nil)
            }
            Text("Video only; production controls stay in the studio. Program includes its composed overlays; Clean Program omits global overlays and annotations while retaining the taken scene. Destination canvas fits program into that canvas without starting publishing. Display disconnect, sleep or studio relocation stops this optional output; restart it manually.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
