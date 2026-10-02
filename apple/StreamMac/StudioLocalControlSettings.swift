import AppKit
import SwiftUI

struct StudioLocalControlSettings: View {
    @ObservedObject var server: StudioLocalControlServer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable paired local controllers", isOn: Binding(get: { server.enabled }, set: { server.setEnabled($0) }))
            Text(server.status).font(.caption)
            Text("\(server.connectedClients) connected clients · Local IPC v1 · 127.0.0.1:\(StudioLocalControlServer.port)")
                .font(.caption).foregroundStyle(.secondary)
            StudioControlPairingSettings(server: server, store: server.pairingStore)
            Text("Pair each hardware plugin or automation client separately. Revoking it disconnects its session and cancels its running macro. Pairing credentials live in this Mac's Keychain and do not travel with projects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct StudioControlPairingSettings: View {
    let server: StudioLocalControlServer
    @ObservedObject var store: StudioControlPairingStore
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Client name", text: $name)
                Button("Pair Client") { store.pair(name: name); if store.pairing != nil { name = "" } }
            }
            ForEach(store.clients) { client in
                HStack {
                    Text(client.name)
                    Spacer()
                    Button("Revoke") { server.revoke(client.id) }
                        .accessibilityLabel("Revoke \(client.name)")
                }
            }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .sheet(item: $store.pairing) { pairing in
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair \(pairing.client.name)").font(.title2)
                Text("Copy these credentials into this trusted local controller. The token is shown only during this pairing.")
                LabeledContent("Client ID", value: pairing.client.id.uuidString).textSelection(.enabled)
                Text(pairing.token).font(.body.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Copy Credentials") {
                        let credentials = "{\"clientID\":\"\(pairing.client.id.uuidString)\",\"token\":\"\(pairing.token)\",\"host\":\"127.0.0.1\",\"port\":\(StudioLocalControlServer.port),\"version\":1}"
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(credentials, forType: .string)
                    }
                    Spacer()
                    Button("Done") { store.pairing = nil }
                }
            }.padding(20).frame(minWidth: 540)
        }
    }
}
