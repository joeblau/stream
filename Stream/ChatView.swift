import SwiftUI

/// The Chat tab: Restream unified chat over OAuth2. Aggregates chat from every
/// platform connected to the user's Restream account.
struct ChatView: View {
    @State private var chat = RestreamChat()
    @State private var clientIDField = ""
    @State private var clientSecretField = ""

    var body: some View {
        NavigationStack {
            Group {
                switch chat.status {
                case .needsCredentials: credentialsForm
                case .signedOut:        connectPrompt
                case .connecting:       ProgressView("Connecting to Restream…")
                case .connected:        messageList
                case .failed(let message): failure(message)
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                if chat.status == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right",
                                   role: .destructive) { chat.signOut() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .task { chat.autoConnect() }
        }
    }

    private var credentialsForm: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientIDField)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Client Secret", text: $clientSecretField)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save & Connect") {
                    chat.saveCredentials(clientID: clientIDField, clientSecret: clientSecretField)
                    chat.connect()
                }
                .disabled(clientIDField.isEmpty || clientSecretField.isEmpty)
            } header: {
                Text("Restream Application")
            } footer: {
                Text("Register an app at dashboard.restream.io, set its redirect URI to \(RestreamAPI.redirectURI), then paste the Client ID + Secret here and sign in with Restream.")
            }
        }
    }

    private var connectPrompt: some View {
        ContentUnavailableView {
            Label("Restream Chat", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Sign in with Restream to see chat from all your connected platforms in one place.")
        } actions: {
            Button("Connect with Restream") { chat.connect() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(message.author).font(.caption.bold())
                                if let platform = message.platform {
                                    Text(platform).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(message.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(message.id)
                    }
                }
                .padding()
            }
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView("Waiting for chat…",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Messages from your connected platforms will appear here."))
                }
            }
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Chat Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { chat.connect() }.buttonStyle(.borderedProminent)
        }
    }
}
