import AppKit
import CoreGraphics
import Foundation

@main @MainActor enum ResilienceObservationHarness {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        validateSessionBootstrap()
        validateDisplayEnumeration()
    }

    static func validateSessionBootstrap() {
        let completed: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
        var locked = completed
        locked["CGSSessionScreenIsLocked"] = true
        check(DesktopResilienceCoordinator.sessionState(from: completed) == .unlocked,
              "A valid unlocked session with the normally absent optional marker was blocked")
        check(DesktopResilienceCoordinator.sessionState(from: locked) == .locked,
              "The initial current screen-lock marker was ignored")
        locked["CGSSessionScreenIsLocked"] = false
        check(DesktopResilienceCoordinator.sessionState(from: locked) == .unlocked,
              "An explicit unlocked marker was rejected")
        locked["CGSSessionScreenIsLocked"] = "invalid"
        check(DesktopResilienceCoordinator.sessionState(from: locked) == .unavailable,
              "A malformed lock marker authorized public output")
        for dictionary in [nil, [:], [kCGSessionOnConsoleKey as String: true]] as [[String: Any]?] {
            check(DesktopResilienceCoordinator.sessionState(from: dictionary) == .unavailable,
                  "An unavailable/incomplete GUI session authorized public output")
        }
        for dictionary in [[kCGSessionOnConsoleKey as String: false, kCGSessionLoginDoneKey as String: true],
                           [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: false]] {
            check(DesktopResilienceCoordinator.sessionState(from: dictionary) == .locked,
                  "An inactive or incomplete login session authorized public output")
        }
        for initialState in [DesktopResilienceCoordinator.SessionState.locked, .unavailable] {
            let coordinator = DesktopResilienceCoordinator(observeSystem: false, initialSessionState: initialState)
            // These are the same synchronously readable gates used by native
            // Go Live, destination starts and managed-start authority checks.
            check(coordinator.isLocked && coordinator.requiresManualRestart,
                  "Already-locked/unknown construction assumed an unlocked session")
            check(coordinator.notice != nil, "Conservative startup needs a visible resume policy")
            var stops = 0, previews = 0, refreshes = 0
            coordinator.stopOutputs = { stops += 1 }
            coordinator.startPreview = { previews += 1 }
            coordinator.refreshSources = { refreshes += 1 }
            coordinator.policy.previewAfterWake = true
            coordinator.handle(.locked)
            check(stops == 0, "A duplicate initial lock repeated teardown")
            coordinator.handle(.sleep)
            coordinator.handle(.wake)
            check(coordinator.isLocked && stops == 1 && previews == 0 && refreshes == 0,
                  "Initially locked wake refreshed or restarted capture")
            coordinator.handle(.unlocked)
            coordinator.handle(.unlocked)
            check(!coordinator.isLocked && coordinator.requiresManualRestart
                    && stops == 1 && previews == 1 && refreshes == 1,
                  "Unlock must permit only opted-in preview, once, while retaining manual output restart")
        }
        let unlocked = DesktopResilienceCoordinator(observeSystem: false, initialSessionState: .unlocked)
        check(!unlocked.isLocked && !unlocked.requiresManualRestart,
              "Ordinary unlocked initialization was blocked")

        // Read the real host, without changing lock/session state or invoking
        // outputs/capture. This also exercises the production adapter directly.
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        let hostState = DesktopResilienceCoordinator.currentSessionState()
        let actual = DesktopResilienceCoordinator(observeSystem: true)
        check(actual.isLocked == (hostState != .unlocked), "Production initialization did not sample the actual host session")
        if dictionary?["CGSSessionScreenIsLocked"] as? Bool == true {
            check(hostState == .locked && actual.isLocked, "Actual locked-host observation was lost at initialization")
        }
        print("PASS: production session bootstrap, already-locked/unknown wake-unlock ordering, normal absent-marker unlock; current host \(hostState), isLocked=\(actual.isLocked)")
    }

    static func validateDisplayEnumeration() {
        // Inject only CGGetActiveDisplayList's read boundary; both enumeration
        // calls, the successful-zero branch and real DeviceMonitor health fold
        // execute unchanged. Camera/audio discovery and OS observers are off.
        var displays: [CGDirectDisplayID] = [41]
        var error: CGError = .success
        var calls = 0
        let monitor = DeviceMonitor(observeSystem: false) { capacity, storage, count in
            calls += 1
            guard error == .success else { return error }
            count?.pointee = UInt32(displays.count)
            if let storage {
                for (index, id) in displays.prefix(Int(capacity)).enumerated() { storage[index] = id }
            }
            return .success
        }
        check(monitor.connectedDisplayIDs == [41], "Initial pinned display was not enumerated")
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onDisplaysChanged = { changes.append($0) }
        displays = []
        let beforeEmpty = calls
        monitor.refreshDisplays(notify: true)
        check(monitor.connectedDisplayIDs.isEmpty && changes == [[]] && calls == beforeEmpty + 1,
              "Successful zero displays failed to retire the last display or queried invalid empty storage")
        error = .failure
        monitor.refreshDisplays(notify: true)
        check(changes == [[]] && monitor.connectedDisplayIDs.isEmpty, "Failed enumeration invented a topology change")
        error = .success; displays = [41]
        monitor.refreshDisplays(notify: true)
        check(changes == [[], [41]] && monitor.connectedDisplayIDs == [41],
              "Returning the same last display failed to deliver capture recovery")
        monitor.refreshDisplays(notify: true)
        check(changes.count == 2, "Equal display sets repeated source recovery")
        displays = [41, 99]; monitor.refreshDisplays(notify: true)
        displays = [99]; monitor.refreshDisplays(notify: true)
        check(changes == [[], [41], [41, 99], [99]], "Ordinary independent-display changes regressed")
        error = .failure; monitor.refreshDisplays(notify: true)
        check(monitor.connectedDisplayIDs == [99] && changes.count == 4,
              "A probe error falsely removed a healthy remaining display")
        print("PASS: actual DeviceMonitor enumeration/callbacks [A] -> [] -> [A], empty versus failed discovery, unchanged and independently healthy display identity")
    }
}
