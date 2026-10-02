import AppKit
import ImageIO
import StreamCore
import SwiftUI
import UniformTypeIdentifiers

private struct ProviderAccountsKey: EnvironmentKey {
    static let defaultValue: ProviderAccountSession? = nil
}
extension EnvironmentValues {
    var providerAccounts: ProviderAccountSession? {
        get { self[ProviderAccountsKey.self] }
        set { self[ProviderAccountsKey.self] = newValue }
    }
}

struct ProviderAccountsView: View {
    @ObservedObject var accounts: ProviderAccountSession
    @ObservedObject var destinations: DestinationSession
    @State private var provider = ManagedProvider.youtube
    @State private var clientID = ""
    @State private var channelID = ""
    @State private var eventID = ""
    @State private var twitchEndpoint = ""
    @State private var twitchTitle = ""
    @State private var edit: EventEditorSelection?
    @State private var deleteEvent: ProviderEvent?
    @State private var importJob: Task<Void, Never>?
    @State private var importError: String?
    @State private var importing = false
    @State private var thumbnail: ThumbnailSelection?
    @State private var readChat = false
    @State private var writeChat = false
    @State private var moderateChat = false
    private var snapshot: ProviderAccountSnapshot { accounts.snapshot(provider) }
    private var channel: ProviderChannel? { snapshot.channels.first { $0.id == channelID } }
    private var event: ProviderEvent? { snapshot.events.first { $0.id == eventID } }
    private var canManageYouTube: Bool { snapshot.scopes.contains("https://www.googleapis.com/auth/youtube") || snapshot.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl") }
    private var selectedEvents: [ProviderEvent] { snapshot.events.filter { $0.channelID == nil || $0.channelID == channelID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider account", selection: $provider) { ForEach(ManagedProvider.allCases) { Text($0.name).tag($0) } }
            Text(provider.accountGate).font(.caption).foregroundStyle(.secondary)
            Link("Account / access repair", destination: provider.repairURL)
            if [.facebookPages, .linkedinLive].contains(provider) {
                Text("Native account, scheduling, chat and remote-event controls require an approved connector. Add a Custom RTMPS destination using credentials issued by your eligible account.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Add Manual RTMPS Draft") { destinations.createManual(provider) }
            } else {
                authorization
                if snapshot.isWorking {
                    HStack { ProgressView().controlSize(.small); Text(snapshot.action).font(.caption); Button("Cancel") { accounts.cancel(provider) } }
                }
                if let prompt = snapshot.devicePrompt {
                    Text("Twitch device code: \(prompt.userCode)").font(.headline).textSelection(.enabled)
                    Link("Open Twitch authorization", destination: prompt.verificationURL)
                    Text("Code expires \(prompt.expiresAt.formatted(date: .omitted, time: .shortened)).").font(.caption)
                }
                if let failure = snapshot.failure { Text(failure.localizedDescription).font(.caption).foregroundStyle(.orange) }
                if let until = snapshot.retryUntil { Text("API cooldown until \(until.formatted(date: .omitted, time: .standard)).").font(.caption) }
                if let date = snapshot.verifiedAt { Text("Metadata verified \(date.formatted(date: .omitted, time: .standard)). Remote state can change; refresh before acting.").font(.caption).foregroundStyle(.secondary) }
                if !snapshot.channels.isEmpty {
                    Picker("Authorized channel", selection: $channelID) {
                        Text("Choose a channel…").tag("")
                        ForEach(snapshot.channels) { Text($0.title).tag($0.id) }
                    }
                    if provider == .youtube || provider == .restream {
                        Picker("Provider event", selection: $eventID) {
                            Text("Choose an event…").tag("")
                            ForEach(selectedEvents) { Text("\($0.title) · \(snapshot.verifiedAt == nil ? "cached / unverified" : $0.state.rawValue)").tag($0.id) }
                        }
                        if let event {
                            Text("Event ID: \(event.id)").font(.caption).textSelection(.enabled)
                            if let date = event.scheduledAt { Text("Scheduled \(date.formatted()) · \(TimeZone.current.identifier)").font(.caption) }
                            if let url = event.publicURL { Link("Open broadcast", destination: url) }
                        }
                    }
                    if provider == .youtube { youtubeControls }
                    if provider == .twitch { twitchControls }
                    if provider == .restream {
                        Text("Authorized channels and upcoming encoder events are available. Create/edit/attach/delete/end events in Restream; Stream cannot infer downstream broadcast state or guarantee every platform accepts scheduling.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
            }
            Text("Cancelling a provider request stops waiting locally; it cannot undo a remote mutation. Refresh before retrying after an uncertain reply.").font(.caption).foregroundStyle(.secondary)
            if let manager = accounts.directChat {
                DisclosureGroup("Shared direct public chat session") { DirectChatControls(manager: manager) }
            }
            Text("One reusable account per provider on this Mac. Reauthorizing can select a different YouTube channel. Projects save routing IDs; all app credentials, refresh tokens and ingest credentials stay in Keychain. Direct chat starts only when you select Read Public Chat.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { clientID = snapshot.clientID }
        .onChange(of: snapshot.clientID) { _, value in if clientID.isEmpty { clientID = value } }
        .onChange(of: provider) { _, _ in thumbnail = nil; clientID = snapshot.clientID; channelID = ""; eventID = ""; importError = nil }
        .onChange(of: channelID) { _, _ in eventID = ""; thumbnail = nil }
        .onChange(of: eventID) { _, _ in thumbnail = nil }
        .onDisappear { importJob?.cancel(); importJob = nil }
        .sheet(item: $edit) { selection in
            YouTubeEventEditor(selection: selection) { draft in
                if let event = selection.event { accounts.editYouTube(eventID: event.id, draft: draft) }
                else { accounts.createYouTube(draft) }
            }
        }
        .confirmationDialog("Upload thumbnail to YouTube?", isPresented: Binding(get: { thumbnail != nil }, set: { if !$0 { thumbnail = nil } }), titleVisibility: .visible) {
            if let thumbnail {
                Button("Upload to \(thumbnail.title)") {
                    accounts.uploadYouTubeThumbnail(eventID: thumbnail.eventID, channelID: thumbnail.channelID, image: thumbnail.image, mimeType: thumbnail.mimeType)
                    self.thumbnail = nil
                }
            }
        } message: { Text("This sends the selected image to the remote event. Other event settings and local outputs continue.") }
        .confirmationDialog("Delete this upcoming YouTube event?", isPresented: Binding(get: { deleteEvent != nil }, set: { if !$0 { deleteEvent = nil } }), titleVisibility: .visible) {
            if let event = deleteEvent { Button("Delete \(event.title)", role: .destructive) { accounts.deleteYouTube(eventID: event.id); eventID = ""; deleteEvent = nil } }
        } message: { Text("This deletes the selected remote event. Local recording and other destinations continue.") }
    }
    @ViewBuilder private var authorization: some View {
        if provider == .restream {
            Text("Connect your own Restream app in Settings → Chat, then refresh here. No Restream application secret is bundled with Stream.").font(.caption)
        } else {
            TextField(provider == .youtube ? "Google Desktop client ID" : "Twitch public application client ID", text: $clientID)
                .autocorrectionDisabled()
            if provider == .twitch {
                Toggle("Request public chat reading", isOn: $readChat)
                Toggle("Request public chat posting", isOn: $writeChat)
                Toggle("Request targeted chat deletion", isOn: $moderateChat)
                Text("Optional scopes apply only after Twitch grants reauthorization; existing grants are shown below.").font(.caption)
            }
            Button(snapshot.hasCredential ? "Reauthorize Account…" : "Connect Account…") {
                let scopes = provider == .twitch ? [(readChat, "user:read:chat"), (writeChat, "user:write:chat"), (moderateChat, "moderator:manage:chat_messages")].compactMap { $0.0 ? $0.1 : nil } : []
                accounts.authorize(provider, clientID: clientID, additionalScopes: scopes)
            }
                .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snapshot.isWorking)
        }
        HStack {
            Button("Refresh Channels / Events") { accounts.refresh(provider) }.disabled(snapshot.isWorking || !accounts.canRequest(provider))
            Button("Forget Authorization", role: .destructive) { accounts.forget(provider) }.disabled(snapshot.isWorking)
        }
        if snapshot.hasCredential && provider != .restream {
            Text(snapshot.scopes.isEmpty ? "Granted scopes unavailable; write controls remain gated." : "Granted: " + snapshot.scopes.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        if snapshot.hasCredential && snapshot.verifiedAt == nil { Text("Authorization stored · access has not been verified by this panel.").font(.caption).foregroundStyle(.secondary) }
    }
    private var youtubeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Create YouTube Event…") { edit = .init(event: nil) }
                if let event, event.state == .upcoming {
                    Button("Edit…") { edit = .init(event: event) }
                    Button("Choose Thumbnail…") { chooseThumbnail(event) }
                    Button("Delete…", role: .destructive) { deleteEvent = event }
                }
            }.disabled(snapshot.isWorking || snapshot.verifiedAt == nil || channel == nil || !canManageYouTube)
            if let event, let channel {
                Button("Verify Selected Event") { accounts.refreshLive(.init(provider: .youtube, channelID: channel.id, eventID: event.id)) }
                    .disabled(snapshot.isWorking || !accounts.canRequest(.youtube))
            }
            if let receipt = accounts.lastThumbnailReceipt, receipt.eventID == eventID {
                Text("YouTube acknowledged thumbnail upload \(receipt.time.formatted(date: .omitted, time: .standard)).").font(.caption)
            }
            Button(importing ? "Importing…" : "Add Bound Event Ingest Draft") { importDestination() }
                .disabled(importing || snapshot.isWorking || snapshot.verifiedAt == nil || channel == nil || event == nil || event?.state == .ended)
            Text("New events start private with automatic start/stop disabled. Configure/bind their stream in YouTube Studio, refresh, then import. Edit upcoming privacy or deliberately upload a JPEG/PNG thumbnail up to 2 MiB here. Early start uses YouTube Studio. Starting ingest can publish if an existing event has automatic start enabled; review its provider settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var twitchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Twitch ingest endpoint from your broadcaster settings", text: $twitchEndpoint)
            Button(importing ? "Importing…" : "Add Twitch Ingest Draft") { importDestination() }
                .disabled(importing || snapshot.isWorking || snapshot.verifiedAt == nil || channel == nil || twitchEndpoint.isEmpty || !snapshot.scopes.contains("channel:read:stream_key"))
            TextField("Twitch channel title", text: $twitchTitle)
            Button("Update Channel Title") {
                if let channel { accounts.setTwitchTitle(channelID: channel.id, title: twitchTitle) }
            }.disabled(snapshot.isWorking || channel == nil || twitchTitle.isEmpty || !snapshot.scopes.contains("channel:manage:broadcast"))
            Text("Twitch channel schedules are not live-event grants. Scheduling and remote event completion are unavailable; disconnecting ingest stops local delivery. No direct Twitch chat connection is granted by these scopes.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func chooseThumbnail(_ event: ProviderEvent) {
        guard let channel else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 2_097_152 else { throw ProviderFailure(.invalidRequest) }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let image = try file.read(upToCount: 2_097_153) ?? Data()
            guard image.count <= 2_097_152,
                  let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...4_096).contains(width), (1...4_096).contains(height),
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else { throw ProviderFailure(.invalidRequest) }
            let mime: String
            if image.starts(with: [137,80,78,71,13,10,26,10]) { mime = "image/png" }
            else if image.starts(with: [255,216,255]) { mime = "image/jpeg" }
            else { throw ProviderFailure(.invalidRequest) }
            thumbnail = .init(eventID: event.id, channelID: channel.id, title: event.title, image: image, mimeType: mime)
            importError = nil
        } catch { importError = "Choose a valid JPEG or PNG thumbnail no larger than 2 MiB or 4096 pixels per side." }
    }
    private func importDestination() {
        guard let channel else { return }
        let provider = provider, event = event, endpoint = twitchEndpoint
        importing = true; importError = nil
        importJob?.cancel()
        importJob = Task {
            defer { importing = false }
            do {
                let connection = try await accounts.importConnection(provider: provider, channel: channel, event: event, endpoint: endpoint)
                guard !Task.isCancelled else { return }
                destinations.createManaged(provider: provider, channel: channel, event: event, connection: connection)
            } catch {
                if !Task.isCancelled { importError = (error as? ProviderFailure ?? ProviderFailure(.unavailable)).localizedDescription }
            }
        }
    }
}

private struct ThumbnailSelection {
    let eventID: String, channelID: String, title: String
    let image: Data
    let mimeType: String
}

private struct EventEditorSelection: Identifiable {
    let id = UUID()
    let event: ProviderEvent?
}
private struct YouTubeEventEditor: View {
    let selection: EventEditorSelection
    var save: (YouTubeEventDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = YouTubeEventDraft()
    @State private var timezone = TimeZone.current.identifier
    private var zone: TimeZone { TimeZone(identifier: timezone) ?? .current }
    var body: some View {
        Form {
            Text(selection.event == nil ? "Create YouTube Event" : "Edit Upcoming YouTube Event").font(.title2)
            TextField("Title (1–100 characters)", text: $draft.title)
            TextEditor(text: $draft.description).frame(minHeight: 100).overlay(alignment: .topLeading) {
                if draft.description.isEmpty { Text("Description (up to 5,000 characters)").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            Picker("Timezone", selection: $timezone) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
            DatePicker("Scheduled start", selection: $draft.scheduledAt, in: Date()...).environment(\.timeZone, zone)
            Text("\(draft.scheduledAt.formatted(.iso8601)) · provider receives an absolute instant.").font(.caption).foregroundStyle(.secondary)
            Picker("Privacy", selection: $draft.privacy) { ForEach(YouTubeEventDraft.Privacy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Text("Saving applies this privacy selection. Automatic start/stop and other content settings are preserved.").font(.caption)
            Text("A scheduled time does not authorize Stream to publish automatically. Stream sends one request; after an uncertain error, refresh before creating again.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save to YouTube") { save(draft); dismiss() }.disabled((try? draft.validate()) == nil)
            }
        }.padding(20).frame(width: 540)
        .onAppear {
            if let event = selection.event {
                draft = .init(title: event.title, description: event.description,
                    privacy: .init(rawValue: event.privacy ?? "private") ?? .private,
                    scheduledAt: event.scheduledAt ?? Date().addingTimeInterval(3_600))
            }
        }
    }
}

/// API values stay labeled independently of the local publisher acknowledgment.
struct ProviderBroadcastStatus: View {
    @ObservedObject var accounts: ProviderAccountSession
    let binding: ProviderDestinationBinding
    private var snapshot: ProviderAccountSnapshot { accounts.snapshot(binding.provider) }
    private var event: ProviderEvent? { snapshot.verifiedAt == nil ? nil : accounts.event(binding) }
    private var publicURL: URL? {
        if let url = event?.publicURL { return url }
        if binding.provider == .twitch { return snapshot.channels.first { $0.id == binding.channelID }?.publicURL }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Remote event: \(event?.state.rawValue ?? "unknown") · Viewers: \(accounts.viewerCount(binding).map(String.init) ?? "unavailable")")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Refresh Remote State") { accounts.refreshLive(binding) }.disabled(snapshot.isWorking || !accounts.canRequest(binding.provider))
                if let url = publicURL {
                    Link(binding.provider == .twitch ? "Open Channel" : "Open Broadcast", destination: url)
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
            }.font(.caption)
            if let event { Text("Remote state read \(event.verifiedAt.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary) }
            if let failure = snapshot.failure { Text(failure.localizedDescription).font(.caption2).foregroundStyle(.orange) }
        }
    }
}
