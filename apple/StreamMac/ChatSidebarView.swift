import SwiftUI

struct ChatSidebarView: View {
    @ObservedObject var coordinator: StudioChatCoordinator
    @Environment(\.studioReduceMotion) private var reduceMotion
    @State private var followMessages = true
    @State private var search = ""
    @State private var platform = "All"
    @State private var author = "All"
    @State private var connection = "All"
    @State private var scrollAnchor: String?
    @State private var kind = "All"
    @State private var favoritesOnly = false
    private var chat: RestreamChat { coordinator.restream }
    private var messages: [StudioChatMessage] {
        coordinator.queue.filtered(search: search, platform: platform == "All" ? nil : platform,
            connectionID: connection == "All" ? nil : connection, author: author == "All" ? nil : author,
            kind: kind == "All" ? nil : kind, favoritesOnly: favoritesOnly)
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(status).font(.callout.weight(.semibold))
                Spacer()
                if chat.status == .connected { Button("Sign Out") { chat.signOut() } }
                else { Button("Connect") { chat.connect() }.disabled(!chat.hasCredentials || chat.status == .connecting) }
            }
            if let manager = coordinator.directChat {
                DisclosureGroup("Direct YouTube / Twitch") { DirectChatControls(manager: manager) }
            }
            TextField("Search messages and authors", text: $search)
            HStack {
                Picker("Platform", selection: $platform) {
                    Text("All platforms").tag("All")
                    ForEach(Array(Set(coordinator.queue.messages.map(\.platform))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Type", selection: $kind) {
                    Text("All types").tag("All")
                    ForEach(Array(Set(coordinator.queue.messages.map(\.kind))).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Picker("Destination", selection: $connection) {
                    Text("All destinations").tag("All")
                    ForEach(Array(Set(coordinator.queue.messages.map(\.connectionID))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Author", selection: $author) {
                    Text("All authors").tag("All")
                    ForEach(Array(Set(coordinator.queue.messages.map(\.author))).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach(coordinator.connections.keys.sorted(), id: \.self) { id in
                if let item = coordinator.connections[id] {
                    Text("\(item.platform) · \(id) · \(item.state)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("Favorites", isOn: $favoritesOnly).toggleStyle(.checkbox)
                Toggle("Follow", isOn: $followMessages).toggleStyle(.checkbox)
                    .help("Disable to keep your scroll position while messages arrive")
            }
            queueControls
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in row(message).id(message.id) }
                    }.scrollTargetLayout().padding(.horizontal, 4)
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition(id: $scrollAnchor)
                .onChange(of: scrollAnchor) { _, id in coordinator.retainReadingPosition(followMessages ? nil : id) }
                .onChange(of: followMessages) { _, follow in
                    coordinator.retainReadingPosition(follow ? nil : scrollAnchor)
                    if follow, let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .overlay {
                    if messages.isEmpty { Text("Connect Restream or an authorized direct provider to read public messages.").font(.caption).foregroundStyle(.secondary) }
                }
                .onChange(of: coordinator.queue.messages.last?.id) {
                    guard followMessages, let last = messages.last else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let error = coordinator.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Public Restream and supported direct chats share this queue. Plain text includes documented emote text; image emotes and chat alert styling remain unavailable.")

                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(minWidth: 260, idealWidth: 330)
        .onAppear { chat.autoConnect() }
    }
    private var status: String {
        switch chat.status {
        case .connected: "Restream chat connected"
        case .connecting: "Restream connecting…"
        case .needsCredentials, .signedOut: "Restream chat offline"
        case .failed: "Restream chat connection failed"
        }
    }
    private var queueControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comment Queue · \(coordinator.queue.queue.count)").font(.caption.weight(.semibold))
            Text("Current: \(coordinator.queue.current?.author ?? "None") · Next: \(coordinator.queue.next?.author ?? "None")")
                .font(.caption).lineLimit(2)
            HStack {
                Button("Previous") { coordinator.advance(-1) }
                Button("Next") { coordinator.advance(1) }
                Button("Show") { if let current = coordinator.queue.current { coordinator.show(current.id) } }
                    .disabled(coordinator.queue.current == nil)
                Button("Hide") { coordinator.hide() }
            }.controlSize(.small)
            Picker("Staged comment slot", selection: $coordinator.selectedSlot) {
                Text("Choose a slot").tag(Optional<LayerID>.none)
                ForEach(coordinator.availableSlots) { Text($0.name).tag(Optional($0.id)) }
            }
            .dropDestination(for: String.self) { values, _ in
                guard values.count == 1, let id = values.first else { return false }
                return coordinator.dropMessage(id)
            }
            Button("Create Comment Slot") { coordinator.createSlot() }
            if let layout = coordinator.selectedCommentPresentation {
                if layout.needsLargerBox { Text("Enlarge this slot to show the comment.").font(.caption).foregroundStyle(.orange) }
                else if layout.pages.count > 1 {
                    HStack {
                        Button("Previous Page") { coordinator.advanceCommentPage(-1) }
                        Button("Next Page") { coordinator.advanceCommentPage(1) }
                        Text("\(coordinator.selectedCommentPage + 1) / \(layout.pages.count)").font(.caption)
                    }.controlSize(.small)
                    Text("Each page is staged. Take publishes it; the original message stays intact.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("Author", isOn: $coordinator.includeAuthor).toggleStyle(.checkbox)
                Toggle("Platform", isOn: $coordinator.includePlatform).toggleStyle(.checkbox)
                Toggle("Avatar", isOn: $coordinator.includeAvatar).toggleStyle(.checkbox)
                    .help("Load a public avatar from supported provider image servers when showing a comment; Take publishes the loaded image.")
            }
            Text("Show/replace/hide edit the staged scene; Take publishes them. Direct Live Editing applies them immediately. Style and resize the slot in the layer inspector.")
                .font(.caption2).foregroundStyle(.secondary)
            if !coordinator.queue.queue.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(coordinator.queue.queue, id: \.self) { id in
                            if let message = coordinator.queue.message(id) {
                                Button(message.author) { coordinator.select(id) }
                                    .buttonStyle(.bordered)
                                    .tint(coordinator.queue.selectedID == id ? Color.accentColor : Color.secondary)
                                    .contextMenu { Button("Remove from Queue") { coordinator.dequeue(id) } }
                            }
                        }
                    }
                }
            }
        }
    }
    private func row(_ message: StudioChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.author).fontWeight(.semibold)
                Spacer()
                Text(message.platform).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(message.timestamp, style: .time)
                if message.timestampIsReceiptTime { Text("received") }
                Text(message.roles.joined(separator: ", "))
            }.font(.caption2).foregroundStyle(.secondary)
            Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(coordinator.queue.favorites.contains(message.id) ? "Unfavorite" : "Favorite") { coordinator.favorite(message.id) }
                Button("Queue") { coordinator.enqueue(message.id) }
                Button("Show") { coordinator.show(message.id) }
            }.controlSize(.small)
            if let manager = coordinator.directChat { DirectChatMessageActions(manager: manager, message: message) }
        }
        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .draggable(message.id)
        .accessibilityElement(children: .contain)
    }
}
