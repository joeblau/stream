import SwiftUI

private enum StudioControllerPanelLookup {
    nonisolated static func hasEndpoint(_ endpoints: [StudioMIDITransport.Endpoint], id: Int32) -> Bool {
        for endpoint in endpoints { if endpoint.id == id { return true } }
        return false
    }
    nonisolated static func target(_ targets: [StudioControllerTarget], id: String) -> StudioControllerTarget? {
        for target in targets { if target.id == id { return target } }
        return nil
    }
}

struct StudioControllerPanel: View {
    @ObservedObject var manager: StudioControllerManager
    @State private var sourceID: Int32 = 0
    @State private var destinationID: Int32 = 0
    @State private var channel: UInt8 = 15
    @State private var listenPort = "32146"
    @State private var feedbackPort = "0"
    @State private var targetID = ""
    @State private var address = "/studio/take"
    @State private var inverted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable MIDI controller input", isOn: Binding(get: { manager.midiEnabled }, set: { manager.setMIDIEnabled($0) }))
            Text(manager.midiStatus).font(.caption)
            HStack {
                Picker("MIDI source", selection: $sourceID) {
                    Text("Choose source").tag(Int32(0))
                    ForEach(manager.sources) { Text($0.name).tag($0.id) }
                    if sourceID != 0 && !StudioControllerPanelLookup.hasEndpoint(manager.sources, id: sourceID) { Text("Disconnected source \(sourceID)").tag(sourceID) }
                }
                Picker("Feedback destination", selection: $destinationID) {
                    Text("Off").tag(Int32(0))
                    ForEach(manager.destinations) { Text($0.name).tag($0.id) }
                    if destinationID != 0 && !StudioControllerPanelLookup.hasEndpoint(manager.destinations, id: destinationID) { Text("Disconnected destination \(destinationID)").tag(destinationID) }
                }
                Picker("Feedback channel", selection: $channel) { ForEach(0..<16) { Text("\($0 + 1)").tag(UInt8($0)) } }.frame(width: 180)
                Button("Apply MIDI") { manager.configureMIDI(source: sourceID, destination: destinationID, feedbackChannel: channel) }
            }
            Text("Only the selected MIDI source can control this project. Feedback requires a separate destination and an unmapped channel supported by your controller.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Enable local OSC input", isOn: Binding(get: { manager.oscEnabled }, set: { manager.setOSCEnabled($0) }))
            Text(manager.oscStatus).font(.caption)
            HStack {
                TextField("Input UDP port", text: $listenPort)
                TextField("Feedback UDP port (0 = off)", text: $feedbackPort)
                Button("Apply OSC") {
                    if let port = UInt16(listenPort), let feedback = UInt16(feedbackPort) { manager.configureOSC(port: port, feedbackPort: feedback) }
                    else { manager.message = "Enter UDP ports from 1 to 65535; use 0 to disable feedback." }
                }
            }
            Text("OSC binds only to 127.0.0.1 on this Mac. Local software on the configured port can run mapped commands. Values use one i/f/T/F argument from 0 to 1; bundles must be immediate.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Stable target", selection: $targetID) {
                Text("Choose command or value").tag("")
                ForEach(manager.targets()) { Text("\($0.kind == .value ? "Value: " : "")\($0.title)").tag($0.id) }
            }
            if let target = StudioControllerPanelLookup.target(manager.targets(), id: targetID) {
                if target.kind == .value { Toggle("Invert numeric input", isOn: $inverted) }
                HStack {
                    if manager.learningTarget != nil { Button("Cancel MIDI Learn") { manager.cancelLearning() } }
                    else { Button("MIDI Learn") { manager.learn(targetID: target.id, kind: target.kind, inverted: inverted) } }
                    TextField("Literal OSC address", text: $address)
                    Button("Map OSC") { _ = manager.add(.init(input: .osc(address), targetID: target.id, kind: target.kind, inverted: target.kind == .value && inverted)) }
                }
                if let error = target.unavailableReason { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(manager.document.mappings) { mapping in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mapping.label)
                        Text(StudioControllerPanelLookup.target(manager.targets(), id: mapping.targetID)?.title ?? "Missing stable target: \(mapping.targetID)").font(.caption)
                        if case .osc = mapping.input { Text("Feedback: \(mapping.feedbackAddress)").font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    Spacer()
                    Button("Remove") { manager.remove(mapping.id) }.accessibilityLabel("Remove \(mapping.label) mapping")
                }
            }
            if let message = manager.message { Text(message).font(.caption).foregroundStyle(.orange).accessibilityAddTraits(.updatesFrequently) }
            Text("Mappings travel with the project; ports, device selection, and enable switches stay on this Mac. Command inputs trigger on press and require a zero/release before pressing again. Numeric input is coalesced at 20 Hz; feedback reports current state rather than predicting an action's success.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(manager.persistenceBlocked)
        .onAppear {
            manager.refreshEndpoints(); sourceID = manager.sourceID; destinationID = manager.destinationID; channel = manager.feedbackChannel
            listenPort = String(manager.oscPort); feedbackPort = String(manager.oscFeedbackPort)
        }
    }
}
