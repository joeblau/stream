import SwiftUI
import StreamCore

/// The same native editor appears in the inspector and embedded settings pane.
struct DestinationManagerView: View {
    @ObservedObject var session: DestinationSession
    var programProfile: OutputProfile

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
        if let notice = session.draft[index].codecNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        ForEach(DestinationValidator.errors(session.draft[index], credentials: session.credentials[id] ?? .init()), id: \.self) { error in
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if let reason = OutputCapabilities.current.gateReason(
            for: session.draft[index].effectiveProfile(program: programProfile), destination: session.draft[index].transport) {
            Text(reason).font(.caption).foregroundStyle(.orange)
        }
        HStack {
            Button("Duplicate") { session.duplicate(id) }
            Spacer()
            Button("Remove", role: .destructive) { session.remove(id) }
        }
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
