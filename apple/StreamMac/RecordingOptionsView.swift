import SwiftUI

/// Recording controls stay attached to the main studio transport. Folder access
/// uses the standard macOS picker and persists a security-scoped bookmark.
struct RecordingOptionsView: View {
    @ObservedObject var recorder: RecordingController
    @State private var presented = false

    var body: some View {
        Button("Recording Options", systemImage: "slider.horizontal.3") { presented.toggle() }
            .labelStyle(.iconOnly)
            .help("Recording options and folder")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording").font(.headline)
                    Group {
                        Picker("Container", selection: $recorder.preferences.container) {
                            ForEach(RecordingContainer.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Codec", selection: $recorder.preferences.codec) {
                            ForEach(RecordingCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Quality", selection: $recorder.preferences.quality) {
                            ForEach(RecordingQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("File prefix", text: $recorder.preferences.filenamePrefix)
                        Stepper("Record-only countdown: \(recorder.preferences.countdownSeconds)s", value: $recorder.preferences.countdownSeconds, in: 0...60)
                        Stepper("Split duration: \(recorder.preferences.splitAfterMinutes == 0 ? "Off" : "\(recorder.preferences.splitAfterMinutes) minutes")", value: $recorder.preferences.splitAfterMinutes, in: 0...240)
                        Stepper("Split size: \(recorder.preferences.splitAfterMegabytes == 0 ? "Off" : "\(recorder.preferences.splitAfterMegabytes) MB")", value: $recorder.preferences.splitAfterMegabytes, in: 0...20_000, step: 100)
                        Text(recorder.folderLabel).font(.caption).lineLimit(2).textSelection(.enabled)
                        HStack {
                            Button("Choose Folder…") { recorder.chooseFolder() }
                            Button("Default Folder") { recorder.useDefaultFolder() }
                        }
                    }
                    .disabled(recorder.state.isActive)
                    Toggle("Auto-record on Go Live", isOn: $recorder.preferences.autoRecordOnGoLive)
                    Text("Recording uses its own encoder at the program canvas size and frame rate. High quality uses more disk space; HEVC may add encoder load. File changes and pause keep network streaming active.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Done") { presented = false }
                }
                .padding(16)
                .frame(width: 380)
            }
    }
}
