import AppKit
import Foundation
import StreamCore
import SwiftUI

private final class ViewerFixtureCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for item: KeychainStore.Item) -> String? { lock.withLock { values[String(reflecting: item)] } }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.withLock { values[String(reflecting: item)] = value }; return true }
    func remove(_ item: KeychainStore.Item) { _ = lock.withLock { values.removeValue(forKey: String(reflecting: item)) } }
}
@MainActor private final class ViewerFixtureRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.unavailable) }
}
private actor ViewerFixtureHTTP {
    private(set) var calls = 0
    var twitchAvailable = true
    func setUnavailable() { twitchAvailable = false }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        precondition((request.httpMethod ?? "GET") == "GET", "Viewer fixture must never mutate provider state")
        let body: String
        switch request.url!.path {
        case "/oauth2/validate": body = #"{"client_id":"viewer-fixture","user_id":"42","scopes":[],"expires_in":3600}"#
        case "/helix/streams":
            let channel = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "user_id" }?.value
            body = twitchAvailable ? "{\"data\":[{\"user_id\":\"\(channel ?? "")\",\"viewer_count\":\(channel == "43" ? 11 : 7)}]}" : #"{"data":[]}"#
        case "/youtube/v3/liveBroadcasts": body = #"{"items":[{"id":"viewer-event","snippet":{"channelId":"viewer-owner","title":"Viewer fixture"},"status":{"lifeCycleStatus":"live"}}]}"#
        case "/youtube/v3/videos": body = #"{"items":[{"id":"viewer-event","liveStreamingDetails":{"concurrentViewers":"0"}}]}"#
        default: throw ProviderFailure(.invalidRequest)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private enum ViewerFixtureClock { static var now = Date() } // Deliberately not observable.
@MainActor enum ProviderViewerUIFixture {
    private struct Node: Decodable, Sendable { let label: String, value: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ViewerUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func until(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<300 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try require(false, message)
    }
    private static func labels() async throws -> [String] {
        let parent = String(getpid())
        guard let client = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_CLIENT"] else {
            throw NSError(domain: "ViewerUI", code: 77, userInfo: [NSLocalizedDescriptionKey: "Owned public AX client unavailable"])
        }
        return try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: client); process.arguments = [parent]
            var environment = ProcessInfo.processInfo.environment
            environment["STREAM_ACCESSIBILITY_WINDOW_TITLE"] = "Owned viewer freshness proof"
            process.environment = environment
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ViewerUI", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
            }
            return try JSONDecoder().decode([Node].self, from: data).flatMap { [$0.label, $0.value].filter { !$0.isEmpty } }
        }.value
    }
    static func run() async throws {
        let http = ViewerFixtureHTTP()
        let vault = ProviderTokenVault(keychain: ViewerFixtureCredentials(), transport: { try await http.send($0) })
        for provider in [ManagedProvider.youtube, .twitch] {
            let generation = try await vault.configure(provider, clientID: "viewer-fixture")
            try await vault.accept(.init(access: "owned-fixture-token", expiresAt: Date().addingTimeInterval(3_600), scopes: provider.scopes), provider: provider, generation: generation)
        }
        let accounts = ProviderAccountSession(restream: ViewerFixtureRestream(), vault: vault,
            pendingDirectory: WorkspaceFixtureStorage.machineDirectory.appendingPathComponent("ViewerFixture"))
        defer { accounts.shutdown() }
        try await until("Fixture credentials did not load") { accounts.snapshot(.youtube).hasCredential && accounts.snapshot(.twitch).hasCredential }
        let youtube = ProviderDestinationBinding(provider: .youtube, channelID: "viewer-owner", eventID: "viewer-event")
        let twitch = ProviderDestinationBinding(provider: .twitch, channelID: "42", eventID: "stray-shared-id")
        let secondTwitch = ProviderDestinationBinding(provider: .twitch, channelID: "43", eventID: "stray-shared-id")
        let manual = ProviderDestinationBinding(provider: .restream, channelID: "unsupported")
        accounts.refreshLive(youtube)
        try await until("YouTube fixture did not finish") { !accounts.snapshot(.youtube).isWorking }
        accounts.refreshLive(twitch)
        try await until("Twitch fixture did not finish") { !accounts.snapshot(.twitch).isWorking }
        accounts.refreshLive(secondTwitch)
        try await until("Second public Twitch channel did not finish") { !accounts.snapshot(.twitch).isWorking }
        try require(accounts.viewerReading(twitch).count == 7 && accounts.viewerReading(secondTwitch).count == 11,
                    "Stray Twitch event IDs aliased independent public channel metrics")
        try require(accounts.viewerReading(.init(provider: .twitch, channelID: "42")).count == 7,
                    "Stray Twitch event ID split the same channel's actual reading")
        guard let youtubeAt = accounts.viewerReading(youtube).readAt, let twitchAt = accounts.viewerReading(twitch).readAt else {
            throw NSError(domain: "ViewerUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Real provider reads did not return timestamps"])
        }
        ViewerFixtureClock.now = max(youtubeAt, twitchAt).addingTimeInterval(0.1)
        try require(accounts.viewerReading(youtube, now: ViewerFixtureClock.now).count == 0, "Valid zero became unavailable")
        try require(accounts.viewerReading(.init(provider: .youtube, channelID: "different-owner", eventID: "viewer-event"), now: ViewerFixtureClock.now).count == nil,
                    "Wrong YouTube channel borrowed a cached event reading without owner verification")
        try require(accounts.viewerReading(.init(provider: .youtube, channelID: "viewer-event"), now: ViewerFixtureClock.now).count == nil,
                    "YouTube binding without an event borrowed a cached event reading")
        try require(accounts.viewerReading(twitch, now: twitchAt.addingTimeInterval(60)).count == 7, "Exact 60-second fresh bound changed")
        try require(accounts.viewerReading(twitch, now: twitchAt.addingTimeInterval(-1)).count == nil, "Future/clock-rollback reading was admitted")
        try require(accounts.viewerReading(twitch, now: Date(timeIntervalSinceReferenceDate: .infinity)).count == nil,
                    "Nonfinite clock age admitted a current count")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Owned viewer freshness proof"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            ProviderBroadcastStatus(accounts: accounts, binding: youtube, now: { ViewerFixtureClock.now })
            Divider()
            ProviderBroadcastStatus(accounts: accounts, binding: twitch, now: { ViewerFixtureClock.now })
            Divider()
            ProviderBroadcastStatus(accounts: accounts, binding: manual, now: { ViewerFixtureClock.now })
        }.padding(20).frame(width: 640, height: 300))
        let previousForeground = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.title = "Owned viewer freshness proof"
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            window.close()
            if let previousForeground, previousForeground.processIdentifier != getpid(), !previousForeground.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                previousForeground.activate(options: [])
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        print("Viewer owned window: title=\(window.title), visible=\(window.isVisible), occluded=\(!window.occlusionState.contains(.visible))")
        var tree = try await labels()
        for _ in 0..<20 {
            if tree.contains(where: { $0.contains("Viewers: 0") }) && tree.contains(where: { $0.contains("Viewers: 7") }) { break }
            try await Task.sleep(for: .milliseconds(100))
            tree = try await labels()
        }
        if !tree.contains(where: { $0.contains("Viewers: 0") }) || !tree.contains(where: { $0.contains("Viewers: 7") }) {
            print("Viewer actual initial tree: \(tree)")
        }
        try require(tree.contains { $0.contains("Viewers: 0") } && tree.contains { $0.contains("Viewers: 7") }, "Actual child UI lost zero or Twitch count")
        try require(tree.filter { $0.hasPrefix("Viewer reading:") && $0.hasSuffix("current") }.count == 2,
                    "Both providers must expose their actual reading timestamp/freshness")
        let requests = await http.calls
        // Change only a plain clock value: no account publication, provider GET,
        // parent state mutation or reconstruction may refresh this actual child.
        ViewerFixtureClock.now = max(youtubeAt, twitchAt).addingTimeInterval(61)
        try await Task.sleep(for: .milliseconds(1300))
        tree = try await labels()
        try require(!tree.contains { $0.contains("Viewers: 0") || $0.contains("Viewers: 7") }
            && tree.filter { $0.hasPrefix("Viewer reading:") && $0.hasSuffix("expired") }.count == 2,
            "Idle actual status child retained stale viewer counts without account publication")
        ViewerFixtureClock.now = min(youtubeAt, twitchAt).addingTimeInterval(-1)
        try await Task.sleep(for: .milliseconds(1300))
        tree = try await labels()
        try require(tree.filter { $0.hasPrefix("Viewer reading:") && $0.hasSuffix("clock changed") }.count == 2,
                    "Actual child displayed future readings as fresh after clock rollback")
        try require(await http.calls == requests, "Mounted timeline issued background provider requests")
        ViewerFixtureClock.now = max(youtubeAt, twitchAt).addingTimeInterval(0.2)
        try await Task.sleep(for: .milliseconds(1300))
        tree = try await labels()
        try require(tree.contains { $0.contains("Viewers: 0") } && tree.contains { $0.contains("Viewers: 7") }, "Current readings did not render after valid clock restoration")
        await http.setUnavailable(); accounts.refreshLive(twitch)
        try await until("Unavailable Twitch read did not complete") { !accounts.snapshot(.twitch).isWorking }
        ViewerFixtureClock.now = Date().addingTimeInterval(0.1)
        try await Task.sleep(for: .milliseconds(1300))
        tree = try await labels()
        try require(!tree.contains { $0.contains("Viewers: 7") } && tree.contains { $0.contains("Viewers: 0") }, "Unavailable Twitch became fabricated zero or erased independent YouTube zero")
        // Forget/reauthorization intent invalidates cached metrics before actor work.
        accounts.forget(.youtube)
        try require(accounts.viewerReading(youtube, now: ViewerFixtureClock.now).count == nil, "Forget retained current audience reading before vault returned")
        try await until("Forget did not complete") { !accounts.snapshot(.youtube).isWorking }
        accounts.authorize(.twitch, clientID: "another-viewer-fixture")
        try require(accounts.viewerReading(secondTwitch, now: ViewerFixtureClock.now).count == nil,
                    "Authorization replacement retained an old provider reading before vault work")
        accounts.cancel(.twitch)
        try require(accounts.viewerReading(secondTwitch, now: ViewerFixtureClock.now).count == nil,
                    "Canceled reauthorization revived old provider readings")
        accounts.shutdown()
        try require(accounts.viewerCount(twitch) == nil && accounts.viewerCount(youtube) == nil, "Closed account retained fresh audience counts")
        window.contentView = nil // Retire the mounted timelines, with no background reader to stop.
        let finalRequests = await http.calls
        try await Task.sleep(for: .milliseconds(1100))
        try require(await http.calls == finalRequests, "Unmounted status child retained a provider poller")
        print("PASS: actual ProviderBroadcastStatus child/public AX expires both YouTube zero and Twitch7 with an unobserved clock and no account publication; visible read timestamps/current/expired/rollback, unknown remains distinct from zero, independent provider readings, exact60s bound, immediate forget/shutdown invalidation and no mounted/unmounted background provider requests")
    }
}
