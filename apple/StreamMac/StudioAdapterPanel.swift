import SwiftUI
import UniformTypeIdentifiers

struct StudioAdapterPanel: View {
    @ObservedObject var manager: StudioAdapterManager
    @ObservedObject var server: StudioLocalControlServer
    @ObservedObject private var pairingStore: StudioControlPairingStore
    @State private var importing = false
    @State private var manifest: StudioAdapterManifest?
    @State private var clientID: UUID?
    @State private var error: String?
    init(manager: StudioAdapterManager, server: StudioLocalControlServer) {
        self.manager = manager; self.server = server; pairingStore = server.pairingStore
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Optional Adapters", systemImage: "puzzlepiece.extension").font(.headline)
            Text("External control processes connect through paired Local Control. Source/output media transports are not available in this version.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = manager.persistenceError { Text(error).foregroundStyle(.orange).font(.caption) }
            ForEach(manager.document.adapters) { adapter in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(adapter.manifest.name)
                            Text("\(adapter.manifest.vendor) · \(adapter.manifest.adapterVersion) · \(manager.status(adapter, server: server))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(get: { adapter.enabled }, set: { enabled in perform { try manager.setEnabled(adapter.id, enabled) } }))
                            .labelsHidden().accessibilityLabel("Enable \(adapter.manifest.name)")
                        Button("Remove and Revoke") { perform { try manager.remove(adapter.id) } }
                    }
                    Text("Approved commands: \(adapter.manifest.control?.allowedCommandIDs.joined(separator: ", ") ?? "None")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if manager.document.adapters.isEmpty { Text("No optional adapters registered.").foregroundStyle(.secondary) }
            Button("Register Adapter Manifest…") { importing = true }
            if let manifest {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Register \(manifest.name)").font(.headline)
                    Text("This manifest requests \(manifest.control?.allowedCommandIDs.count ?? 0) explicit commands. Pair a dedicated client first, then select it. New registrations start disabled.")
                        .font(.caption)
                    Text(manifest.control?.allowedCommandIDs.joined(separator: ", ") ?? "State inspection only")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Picker("Dedicated paired client", selection: $clientID) {
                        Text("Select a paired client").tag(Optional<UUID>.none)
                        ForEach(pairingStore.clients) { client in Text(client.name).tag(Optional(client.id)) }
                    }
                    HStack {
                        Button("Register Disabled") {
                            if let clientID { perform { try manager.register(manifest, clientID: clientID); self.manifest = nil; self.clientID = nil } }
                        }.disabled(clientID == nil)
                        Button("Cancel") { self.manifest = nil; clientID = nil }
                    }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption).accessibilityLabel("Adapter error: \(error)") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 262145) ?? Data()
                guard data.count <= 262144 else { throw StudioAdapterManagerError(message: "Adapter manifests must be at most 256 KB.") }
                let value = try JSONDecoder().decode(StudioAdapterManifest.self, from: data)
                if let reason = value.hostCompatibilityError { throw StudioAdapterManagerError(message: reason) }
                manifest = value; clientID = nil
            }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
