import Foundation

/// Shipping Session with actual mixer construction/registry primitives only.
/// No mixer clock, devices, capture, helper, WebKit or IPC is started.
@main @MainActor private struct BrowserStopConfirmationSessionHarness {
    static func main() async throws {
        setbuf(stdout, nil)
        try await BrowserHelperLifecycleChecks.run()
    }
}
