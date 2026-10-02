import SwiftUI

/// Recording controls stay attached to the main studio transport. Folder access
/// uses the standard macOS picker and persists a security-scoped bookmark.
struct RecordingOptionsView: View {
    @EnvironmentObject private var controller: StreamController
    @State private var audioSources: [RecordingAudioSource] = []
    @ObservedObject var recorder: RecordingController
    @State private var presented = false

    var body: some View {
        Button("Recording Options", systemImage: "slider.horizontal.3") { presented.toggle() }
            .labelStyle(.iconOnly)
            .help("Recording options and folder")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
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
                    Divider()
                    Text("Isolated audio (up to 8 tracks)").font(.subheadline.bold())
                    Text("Widget audio follows its System Mix route. Independent widget audio taps are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(audioSources) { source in
                                isolatedSource(source)
                            }
                            ForEach(recorder.preferences.isolatedTracks.filter { selection in !audioSources.contains(where: { $0.id == selection.targetID }) }) { selection in
                                HStack {
                                    Text("\(selection.name) — unavailable").foregroundStyle(.orange)
                                    Button("Remove") { recorder.preferences.isolatedTracks.removeAll { $0.targetID == selection.targetID } }
                                }
                            }
                        }
                    }.frame(maxHeight: 170).disabled(recorder.state.isActive)
                    ForEach(recorder.isolatedProgress) { track in
                        Text("\(track.name): \(track.status)\(track.missingSourceFrames > 0 ? " · source gaps" : "")\(track.error.map { " · " + $0 } ?? "")")
                            .font(.caption).foregroundStyle(track.error == nil ? Color.secondary : Color.orange)
                    }
                    Text("Recording uses its own encoder at the program canvas size and frame rate. High quality uses more disk space; HEVC may add encoder load. File changes and pause keep network streaming active.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Done") { presented = false }
                }
                .padding(16)
                .frame(width: 420)
                }.frame(maxHeight: 580)
                .task {
                    while !Task.isCancelled {
                        audioSources = await controller.recordingAudioSources()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
    }

    @ViewBuilder private func isolatedSource(_ source: RecordingAudioSource) -> some View {
        let index = recorder.preferences.isolatedTracks.firstIndex { $0.targetID == source.id }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(source.name + (source.isAvailable ? "" : " (no audio received)"), isOn: Binding(
                get: { recorder.preferences.isolatedTracks.contains { $0.targetID == source.id } },
                set: { selected in
                    if selected, recorder.preferences.isolatedTracks.count < 8 {
                        recorder.preferences.isolatedTracks.append(IsolatedRecordingSelection(targetID: source.id, name: source.name))
                    } else if !selected { recorder.preferences.isolatedTracks.removeAll { $0.targetID == source.id } }
                }))
            if let index {
                HStack {
                    Picker("Format", selection: $recorder.preferences.isolatedTracks[index].format) {
                        ForEach(IsolatedAudioFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if !source.isBus {
                        Picker("Processing", selection: $recorder.preferences.isolatedTracks[index].processing) {
                            ForEach(IsolatedAudioProcessing.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else { Text("Mixed bus").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
