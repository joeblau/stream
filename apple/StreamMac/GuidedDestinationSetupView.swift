import SwiftUI
import StreamCore

struct GuidedDestinationSetupView: View {
    var template: DestinationProviderTemplate
    var create: (StreamProtocol) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var transport: StreamProtocol
    @State private var grantedIngest = false
    init(template: DestinationProviderTemplate, create: @escaping (StreamProtocol) -> Void) {
        self.template = template; self.create = create
        _transport = State(initialValue: template.transports[0])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up \(template.name)").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DestinationProviderGuidance(template: template, transport: transport)
                    Picker("Match the issued URL", selection: $transport) {
                        ForEach(template.transports, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    let destination = template.makeDestination(transport: transport)
                    Text("Starting profile: \(destination.outputProfile.canvasWidth)×\(destination.outputProfile.canvasHeight) at \(destination.outputProfile.frameRate) fps, H.264, \(destination.videoBitrate / 1000) kbps video, \(destination.audioBitrate / 1000) kbps audio, \(destination.keyframeSeconds ?? 2, specifier: "%.0f")-second keyframes.")
                        .font(.caption)
                    Text("This creates a disabled draft with empty credentials. Paste the account-issued details, review its canvas and test the event, then apply and enable it when ready.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("My account has granted external ingest credentials", isOn: $grantedIngest)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create Disabled Draft") { create(transport); dismiss() }
                    .disabled(!grantedIngest).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 590, height: 660)
    }
}

struct DestinationProviderGuidance: View {
    var template: DestinationProviderTemplate
    var transport: StreamProtocol
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Guidance reviewed \(DestinationProviderTemplate.reviewedOn); verify current account requirements before each event.")
                .foregroundStyle(.secondary)
            requirement("Account / access", template.accountRequirement)
            requirement("Key lifecycle", template.keyLifecycle)
            requirement("Orientation", template.orientationRequirement)
            requirement("Provider event controls", template.eventControl)
            Text(template.protocolSetup(transport)).foregroundStyle(transport == .whip ? .orange : .secondary)
            Text(template.encoderCaveat).foregroundStyle(.orange)
            Text(template.capabilityDisclosure).foregroundStyle(.secondary)
            Text(template.evidenceNotice).foregroundStyle(.secondary)
            ForEach(template.sources, id: \.url) { Link($0.title, destination: $0.url) }
        }.font(.caption).textSelection(.enabled)
    }
    private func requirement(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(value)
        }
    }
}
