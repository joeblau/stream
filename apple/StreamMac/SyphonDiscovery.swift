import Foundation

#if canImport(Syphon)
import Syphon
#endif

/// C09 (issue #163): one running Syphon server, distilled to a pure-Swift
/// value so the rest of the app (and the Swift 6 concurrency checker) never
/// touches Syphon's Objective-C dictionaries. The instance `uuid` identifies
/// the live server for exact matching while it runs; it is never persisted —
/// `SyphonSourcePayload` identity is name + app, which a relaunch restores.
struct DiscoveredSyphonServer: Hashable, Sendable, Identifiable {
    var name: String
    var appName: String
    var uuid: String

    var id: String { uuid }

    /// The payload identity this server satisfies right now.
    var payload: SyphonSourcePayload {
        SyphonSourcePayload(serverName: name, appName: appName)
    }

    /// The row title: server name with the owning app, e.g. "MadMapper — Output 1".
    var displayTitle: String { payload.displayTitle }

    /// True when this live server answers to `payload`'s persisted identity
    /// (server name + app name; the volatile UUID deliberately ignored).
    func matches(_ payload: SyphonSourcePayload) -> Bool {
        name == payload.serverName && appName == payload.appName
    }
}

/// C09 (issue #163): the live list of Syphon servers on this Mac, wrapping
/// `SyphonServerDirectory`'s announce/update/retire notifications. The
/// capture pool owns one instance (main actor, like the pool) and both
/// reconciles missing-source state off it and exposes it to the Sources UI.
///
/// ObjC bridge isolation: every Syphon API touch happens here and in
/// `SyphonSourceCapture`, always on the main actor; the rest of the app sees
/// only `DiscoveredSyphonServer` values. When the Syphon package is absent
/// (`canImport` fails) the directory compiles to an always-empty stub with
/// `isSupported == false`, so the UI can show the honest unavailable state
/// instead of a dead list.
@MainActor
final class SyphonServerDiscovery: ObservableObject {
    /// False in builds without the Syphon package (the UI shows guidance).
    static let isSupported: Bool = {
        #if canImport(Syphon)
        return true
        #else
        return false
        #endif
    }()

    /// Every server currently publishing, in directory order.
    @Published private(set) var servers: [DiscoveredSyphonServer] = []

    #if canImport(Syphon)
    private var observers: [NSObjectProtocol] = []
    #endif

    init() {
        #if canImport(Syphon)
        reload()
        let center = NotificationCenter.default
        let directory = SyphonServerDirectory.shared()
        for name in [NSNotification.Name.SyphonServerAnnounce,
                     NSNotification.Name.SyphonServerUpdate,
                     NSNotification.Name.SyphonServerRetire] {
            let observer = center.addObserver(
                forName: name, object: directory, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reload()
                }
            }
            observers.append(observer)
        }
        #endif
    }

    // No deinit cleanup: the block-based observer tokens are non-Sendable
    // (unreachable from a nonisolated deinit under Swift 6), and the
    // discovery is a process-lifetime singleton owned by the capture pool —
    // the tokens' blocks capture it weakly, so there is nothing to reclaim.

    /// The first live server answering to `payload`'s identity, if any.
    func server(matching payload: SyphonSourcePayload) -> DiscoveredSyphonServer? {
        servers.first { $0.matches(payload) }
    }

    #if canImport(Syphon)
    private func reload() {
        servers = SyphonServerDirectory.shared().servers.map { description in
            DiscoveredSyphonServer(
                name: description[SyphonServerDescriptionNameKey] as? String ?? "",
                appName: description[SyphonServerDescriptionAppNameKey] as? String ?? "",
                uuid: description[SyphonServerDescriptionUUIDKey] as? String ?? UUID().uuidString)
        }
    }
    #endif
}
