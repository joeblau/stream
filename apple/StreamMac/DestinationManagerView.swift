import SwiftUI
import StreamCore

/// The same native editor appears in the inspector and embedded settings pane.
struct DestinationManagerView: View {
    @ObservedObject var session: DestinationSession
    var programProfile: OutputProfile
    @EnvironmentObject private var controller: StreamController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    ForEach(StreamProtocol.allCases, id: \.self) { transport in
                        Button("Add \(transport.displayName)") { session.create(transport) }
                    }
                } label: { Label("Add Destination", systemImage: "plus") }
                Spacer()
                Text("\(session.draft.filter(\.isEnabled).count) enabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.draft.isEmpty {
                Text("Add a streaming destination. Its endpoint and credentials stay in your Keychain.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Destination", selection: $session.selectedID) {
                    ForEach(session.draft) { destination in
                        Text(destination.name).tag(Optional(destination.id))
                    }
                }
                if let id = session.selectedID, let index = session.draft.firstIndex(where: { $0.id == id }) {
                    editor(index, id: id)
                }
            }
            DestinationStatusRows(outputs: controller.destinationOutputs,
                                  destinations: session.saved,
                                  onStart: controller.startDestination,
                                  onStop: controller.stopDestination,
                                  onRetry: controller.retryDestination)
            resourceEstimate
            if let error = session.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Revert Destinations") { session.revert() }.disabled(!session.isDirty)
                Spacer()
                Button("Apply Destinations") { session.apply() }
                    .disabled(!session.canApply)
                    .buttonStyle(.borderedProminent)
            }
            Text("Connection edits apply at the next destination start. Duplicate destinations start disabled. Credentials are saved by ID in this Mac's Keychain and excluded from projects.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    @ViewBuilder
    private func editor(_ index: Int, id: UUID) -> some View {
        TextField("Name", text: $session.draft[index].name)
        Toggle("Enabled for Go Live", isOn: $session.draft[index].isEnabled)
        Picker("Protocol", selection: $session.draft[index].transport) {
            ForEach(StreamProtocol.allCases, id: \.self) { transport in
                Text(transport.displayName).tag(transport)
            }
        }
        TextField("Endpoint URL", text: secret(id, \.endpoint),
                  prompt: Text(session.draft[index].transport.urlPlaceholder))
            .autocorrectionDisabled()
        if session.draft[index].transport.requiresKey {
            SecureField("Stream key", text: secret(id, \.streamKey)).autocorrectionDisabled()
        }
        if session.draft[index].transport == .srt {
            TextField("Stream ID (optional)", text: secret(id, \.srtStreamID)).autocorrectionDisabled()
            SecureField("Passphrase (optional)", text: secret(id, \.srtPassphrase)).autocorrectionDisabled()
            Text("SRT caller mode; provide a host and port. Passphrases require 10–79 bytes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Canvas: Program").font(.caption).foregroundStyle(.secondary)
        Toggle("Use program output profile", isOn: $session.draft[index].followsProgramProfile)
        if !session.draft[index].followsProgramProfile {
            Picker("Output canvas", selection: Binding(
                get: { CanvasPreset(matching: session.draft[index].outputProfile) },
                set: { if let size = $0.size {
                    session.draft[index].outputProfile = session.draft[index].outputProfile.with(canvasWidth: size.width, canvasHeight: size.height)
                } })) {
                    ForEach(CanvasPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            HStack {
                TextField("Width", value: profileValue(index, \.canvasWidth), format: .number)
                Text("×")
                TextField("Height", value: profileValue(index, \.canvasHeight), format: .number)
            }
            Picker("Frame rate", selection: profileValue(index, \.frameRate)) {
                ForEach(OutputCapabilities.supportedFrameRates, id: \.self) { fps in Text("\(fps) fps").tag(fps) }
            }
        }
        Picker("Video codec", selection: $session.draft[index].videoCodec) {
            ForEach(VideoCodec.allCases, id: \.self) { codec in
                Text(codec.displayName).tag(codec)
            }
        }
        TextField("Video bitrate (bps)", value: $session.draft[index].videoBitrate, format: .number)
        TextField("Audio bitrate (bps)", value: $session.draft[index].audioBitrate, format: .number)
        TextField("Keyframe interval (seconds)", value: Binding(
            get: { session.draft[index].keyframeSeconds ?? 2 },
            set: { session.draft[index].keyframeSeconds = $0 }), format: .number)
        Toggle("Override ingest limits", isOn: Binding(
            get: { session.draft[index].ingestLimits != nil },
            set: { enabled in session.draft[index].ingestLimits = enabled ? .init() : nil }))
        if session.draft[index].ingestLimits != nil {
            Picker("Evidence", selection: limitValue(index, \.source)) {
                Text("Custom override").tag(DestinationIngestLimits.Source.customOverride)
                Text("Validated against ingest").tag(DestinationIngestLimits.Source.validatedIngest)
            }
            TextField("Ingest maximum width", value: limitValue(index, \.maxWidth), format: .number)
            TextField("Ingest maximum height", value: limitValue(index, \.maxHeight), format: .number)
            TextField("Ingest maximum fps", value: limitValue(index, \.maxFrameRate), format: .number)
            TextField("Ingest maximum keyframe seconds", value: limitValue(index, \.maxKeyframeSeconds), format: .number)
            TextField("Ingest maximum audio bps", value: limitValue(index, \.maxAudioBitrate), format: .number)
            Toggle("Ingest accepts HEVC", isOn: Binding(
                get: { session.draft[index].ingestLimits?.codecs.contains(.hevc) ?? false },
                set: { enabled in session.draft[index].ingestLimits?.codecs = enabled ? [.h264, .hevc] : [.h264] }))
        } else {
            Text("Conservative limits: \(session.draft[index].transport == .whip ? "H.264/Opus, 1080p30" : "AAC, 2-second keyframes"). Validate custom overrides with your ingest.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let notice = session.draft[index].codecNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        ForEach(DestinationValidator.errors(session.draft[index], credentials: session.credentials[id] ?? .init()), id: \.self) { error in
            Text(error).font(.caption).foregroundStyle(.red)
        }
        ForEach(DestinationValidator.startErrors(session.draft[index],
                   credentials: session.credentials[id] ?? .init(), program: programProfile), id: \.self) { error in
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        HStack {
            Button("Duplicate") { session.duplicate(id) }
            Spacer()
            Button("Remove", role: .destructive) { session.remove(id) }
        }
    }

    private var resourceEstimate: some View {
        let plan = session.encodingPlan(program: programProfile)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Applied output estimate: \(plan.encoderSessions) encoder sessions, \(Double(plan.aggregateBitrate) / 1_000_000, specifier: "%.1f") Mbps payload; allow \(plan.requiredUplinkMbps, specifier: "%.1f") Mbps uplink.")
            Text("\(plan.compatibleGroups.count) compatible profile groups. This transport backend uses a separate encoder per destination; local recording needs its own session.")
            TextField("Measured uplink Mbps (0 = unknown)", value: $session.measuredUplinkMbps, format: .number)
            TextField("Tested publishing encoder budget (0 = unknown)", value: $session.measuredSessionLimit, format: .number)
            ForEach(plan.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func limitValue<Value>(_ index: Int, _ path: WritableKeyPath<DestinationIngestLimits, Value>) -> Binding<Value> {
        Binding(get: { (session.draft[index].ingestLimits ?? .init())[keyPath: path] }, set: { value in
            var limits = session.draft[index].ingestLimits ?? .init()
            limits[keyPath: path] = value
            session.draft[index].ingestLimits = limits
        })
    }

    private func secret(_ id: UUID, _ path: WritableKeyPath<DestinationCredentials, String>) -> Binding<String> {
        Binding(get: { (session.credentials[id] ?? .init())[keyPath: path] },
                set: { value in
                    var credentials = session.credentials[id] ?? .init()
                    credentials[keyPath: path] = value
                    session.credentials[id] = credentials
                })
    }

    private func profileValue(_ index: Int, _ path: KeyPath<OutputProfile, Int>) -> Binding<Int> {
        Binding(get: { session.draft[index].outputProfile[keyPath: path] }, set: { value in
            let profile = session.draft[index].outputProfile
            if path == \OutputProfile.canvasWidth { session.draft[index].outputProfile = profile.with(canvasWidth: value) }
            else if path == \OutputProfile.canvasHeight { session.draft[index].outputProfile = profile.with(canvasHeight: value) }
            else { session.draft[index].outputProfile = profile.with(frameRate: value) }
        })
    }
}

private struct DestinationStatusRows: View {
    @ObservedObject var outputs: DestinationOutputController
    var destinations: [StreamDestination]
    var onStart: (UUID) -> Void
    var onStop: (UUID) -> Void
    var onRetry: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(outputs.liveCount) live / \(outputs.activeCount) active\(outputs.partialSuccess ? " · Partial success" : "")")
                .font(.caption.weight(.semibold))
            ForEach(destinations) { destination in
                let state = outputs.states[destination.id] ?? .idle
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(destination.name).lineLimit(1)
                        Spacer()
                        Text(label(state)).font(.caption).foregroundStyle(state.isLive ? .green : .secondary)
                    }
                    HStack {
                        if state.canStart {
                            Button(state == .idle ? "Start" : "Retry") {
                                if state == .idle { onStart(destination.id) } else { onRetry(destination.id) }
                            }
                        } else {
                            Button("Stop") { onStop(destination.id) }.disabled(state == .stopping)
                        }
                        if case .failed(let reason) = state { Text(reason).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        }
    }
    private func label(_ state: StreamSessionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }
}
