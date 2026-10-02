import StreamCore
import SwiftUI

struct YouTubeStreamControls: View {
    @ObservedObject var accounts: ProviderAccountSession
    @ObservedObject var pending: ProviderPendingCatalog
    let channelID: String
    let event: ProviderEvent?
    @State private var streamID = ""
    @State private var creating = false
    private var streams: [YouTubeLiveStream] { accounts.youtubeStreams.filter { $0.channelID == channelID } }
    private var snapshot: ProviderAccountSnapshot { accounts.snapshot(.youtube) }
    private var writable: Bool {
        snapshot.scopes.contains("https://www.googleapis.com/auth/youtube") || snapshot.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl")
    }
    var body: some View {
        DisclosureGroup("YouTube stream and event binding") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Refresh Owned Streams") { accounts.refreshYouTubeStreams() }
                        .disabled(snapshot.isWorking || !accounts.canRequest(.youtube))
                    Button("Create Stream…") { creating = true }
                        .disabled(snapshot.isWorking || !writable || !pending.canCreate || !accounts.canRequest(.youtube))
                }
                Picker("Stream", selection: $streamID) {
                    Text("Choose a stream…").tag("")
                    ForEach(streams) { stream in
                        Text("\(stream.title) · \(stream.state.rawValue)").tag(stream.id)
                    }
                }
                if let stream = streams.first(where: { $0.id == streamID }) {
                    Text("Stream ID: \(stream.id)").font(.caption).textSelection(.enabled)
                    Text("Ingest profile: \(stream.ingestionType ?? "unverified") · \(stream.resolution ?? "unverified") · \(stream.frameRate ?? "unverified")").font(.caption)
                }
                if let event {
                    Text("Event binding: \(event.boundStreamID ?? "none / unverified")").font(.caption).textSelection(.enabled)
                    Button("Review Binding…") {
                        accounts.reviewYouTubeBinding(eventID: event.id, streamID: streamID, channelID: channelID)
                    }.disabled(snapshot.isWorking || !writable || streamID.isEmpty || !accounts.canRequest(.youtube))
                }
                Text("A fresh owned upcoming event and inactive/ready RTMP stream are required. Binding sends no media and preserves automatic start/stop. Creating a stream and binding it are separate deliberate actions, so a failed bind keeps the created stream for repair.").font(.caption2).foregroundStyle(.secondary)
                Link("Open YouTube Studio for early start or repair", destination: URL(string: "https://studio.youtube.com")!)
            }
        }
        .sheet(isPresented: $creating) {
            YouTubeStreamEditor { draft in accounts.createYouTubeStream(draft, channelID: channelID) }
        }
        .sheet(isPresented: Binding(get: { accounts.bindingReview != nil }, set: { if !$0 { accounts.clearBindingReview() } })) {
            if let review = accounts.bindingReview {
                YouTubeBindingConfirmation(review: review, canRetain: pending.canRetain([.init(review.event), .init(review.stream)])) { replacing in
                    accounts.bindYouTube(review, replacingExisting: replacing)
                } cancel: { accounts.clearBindingReview() }
            }
        }
        .onChange(of: channelID) { _, _ in streamID = ""; accounts.clearBindingReview() }
        .onChange(of: event?.id) { _, _ in accounts.clearBindingReview() }
    }
}

private struct YouTubeStreamEditor: View {
    let save: (YouTubeStreamDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = YouTubeStreamDraft()
    var body: some View {
        Form {
            Text("Create YouTube Stream").font(.title2)
            TextField("Stream title (1–128 characters)", text: $draft.title)
            Picker("Resolution", selection: $draft.resolution) {
                ForEach(YouTubeStreamDraft.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Frame rate", selection: $draft.frameRate) {
                ForEach(YouTubeStreamDraft.FrameRate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Allow stream reuse across broadcasts", isOn: $draft.reusable)
            Text("RTMP ingest. Choose variable for both resolution and frame rate, or an explicit pair matching your destination. This configures the provider; it does not start a broadcast or change local encoder settings.").font(.caption)
            Text("YouTube receives one create request. An acknowledged ID is retained in this project before binding. An unknown outcome must be checked in YouTube Studio before creating again.").font(.caption)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Create on YouTube") { save(draft); dismiss() }.disabled((try? draft.validate()) == nil)
            }
        }.padding(20).frame(width: 480)
    }
}

private struct YouTubeBindingConfirmation: View {
    let review: YouTubeBindingReview
    let canRetain: Bool
    let save: (Bool) -> Void
    let cancel: () -> Void
    @State private var replace = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review YouTube Binding").font(.title2)
            Text("Channel: \(review.event.channelID ?? "unverified")\nEvent: \(review.event.title) · \(review.event.id)\nStream: \(review.stream.title) · \(review.stream.id)").textSelection(.enabled)
            Text("Current binding: \(review.event.boundStreamID ?? "none")")
            Text("Automatic start: \(review.event.enableAutoStart.map { $0 ? "enabled" : "disabled" } ?? "unknown") · automatic stop: \(review.event.enableAutoStop.map { $0 ? "enabled" : "disabled" } ?? "unknown")").font(.caption)
            if review.replacesExisting {
                Toggle("Replace the displayed existing stream binding", isOn: $replace)
                Text("This disconnects the event from its previous stream. No unbind request is sent separately.").font(.caption).foregroundStyle(.orange)
            }
            if review.event.enableAutoStart == true {
                Text("Automatic start is enabled at YouTube. Starting ingest later may publish this broadcast. Binding preserves that setting.").font(.caption).foregroundStyle(.orange)
            }
            if !canRetain { Text("The local repair catalog is full or unavailable. No binding request will be sent.").foregroundStyle(.orange) }
            Text("Stream rechecks owner, lifecycle, stream readiness, the existing binding and automatic settings before one request. Changes invalidate this review.").font(.caption)
            HStack {
                Button("Cancel") { cancel() }; Spacer()
                Button(review.event.boundStreamID == review.stream.id ? "Verify Existing Binding" : "Bind Reviewed Event") { save(replace) }
                    .disabled(!canRetain || (review.replacesExisting && !replace))
            }
        }.padding(20).frame(width: 520)
    }
}

struct ProviderPendingControls: View {
    @ObservedObject var accounts: ProviderAccountSession
    @ObservedObject var pending: ProviderPendingCatalog
    @State private var forgetting: ProviderPendingRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let receipt = accounts.lastSchedulingReceipt {
                Text("\(receipt.action): \(label(receipt.state))\(receipt.resourceID.isEmpty ? "" : " · " + receipt.resourceID)").font(.caption).textSelection(.enabled)
                if let failure = receipt.failure { Text(failure.localizedDescription).font(.caption).foregroundStyle(.orange) }
            }
            if let error = pending.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !pending.document.records.isEmpty {
                DisclosureGroup("Project repair IDs · \(pending.document.records.count)/128") {
                    ForEach(pending.document.records) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(record.kind.rawValue.capitalized) · \(record.title)").font(.caption)
                                Text("\(record.channelID) · \(record.providerID)").font(.caption2).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Forget Local ID…") { forgetting = record }.disabled(!pending.writable)
                        }
                    }
                    Text("Stored IDs are cached public metadata; remote state is unknown until a fresh provider read. Restore never creates, binds, retries or starts an output. Forgetting a local ID leaves the remote resource untouched.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.confirmationDialog("Forget this local repair ID?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let record = forgetting { Button("Forget \(record.providerID)", role: .destructive) { pending.remove(record.id); forgetting = nil } }
        } message: { Text("The remote event or stream remains. Copy its ID first if you still need it for repair.") }
    }
    private func label(_ state: ProviderSchedulingReceipt.State) -> String {
        switch state {
        case .acknowledged: "Provider acknowledged"
        case .observed: "Fresh provider observation"
        case .blocked: "Not completed"
        case .unconfirmed: "Provider outcome unknown · never replayed"
        }
    }
}
