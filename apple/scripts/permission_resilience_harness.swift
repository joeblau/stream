import Foundation
import CoreMedia
import ScreenCaptureKit

final class OwnedPermissionAudioSample: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}
enum OwnedPermissionAudioQueue {
    static let value = DispatchQueue(label: "com.joeblau.fixture.permission-microphone")
}

final class OwnedPermissionResetBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let drain = DispatchSemaphore(value: 0)
    private var armed = true, entered = false, timedOut = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func reset() {
        lock.lock()
        guard armed else { lock.unlock(); return }
        armed = false; entered = true; lock.unlock()
        if drain.wait(timeout: .now() + 5) != .success {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
    func release() { drain.signal() }
}

@MainActor enum OwnedCaptureDiscovery {
    static var hold = false
    static var pending: [CheckedContinuation<SCShareableContent, any Error>] = []
    static func current() async throws -> SCShareableContent {
        if hold { return try await withCheckedThrowingContinuation { pending.append($0) } }
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)
    }
}

@MainActor enum OwnedPermissionProbe {
    enum Outcome { case success, error(NSError), held }
    static var preflight = true
    static var outcome = Outcome.success
    static var held: CheckedContinuation<Void, any Error>?
    static func discover() async throws {
        switch outcome {
        case .success: return
        case .error(let error): throw error
        case .held: try await withCheckedThrowingContinuation { held = $0 }
        }
    }
}

@MainActor enum PermissionResilienceHarness {
    static func probePolicy() async throws {
        let manager = PermissionsProbeValidationManager()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .granted, "Owned preflight baseline not granted")
        OwnedPermissionProbe.outcome = .error(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        await manager.probeScreenAccess()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .denied, "Explicit SCK denial was hidden behind stale granted preflight")
        manager.refresh()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .denied, "Refresh silently overwrote confirmed denial with stale preflight")
        await Task.yield()
        for error in [NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue),
                      NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue),
                      NSError(domain: "owned.transient", code: SCStreamError.Code.userDeclined.rawValue)] {
            OwnedPermissionProbe.outcome = .error(error)
            await manager.probeScreenAccess()
            try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .unavailable
                && manager.repairAction(for: .screenCapture)?.title.contains("temporarily unavailable") == true,
                "A transient/locked/mismatched-domain failure was mislabeled as TCC denial")
        }
        OwnedPermissionProbe.outcome = .success
        await manager.probeScreenAccess()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .granted, "Successful discovery did not recover availability")
        OwnedPermissionProbe.outcome = .held
        let old = Task { await manager.probeScreenAccess() }
        try await SharedEncoderHarness.settle { OwnedPermissionProbe.held != nil }
        OwnedPermissionProbe.outcome = .success
        await manager.probeScreenAccess()
        let held = OwnedPermissionProbe.held; OwnedPermissionProbe.held = nil
        held?.resume(throwing: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        await old.value
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .granted, "Stale probe completion overwrote newer success")
        OwnedPermissionProbe.preflight = false
        await manager.probeScreenAccess()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .needsRequest, "Never-requested access became a false denial")
        GuestFixtureDefaults.value.set(true, forKey: "permissions.screenCaptureRequested")
        await manager.probeScreenAccess()
        try SharedEncoderHarness.check(manager.status(for: .screenCapture) == .denied, "Known requested/preflight-denied state not retained")
        print("PASS: shipping permission probe distinguishes affirmative SCK denial from stale preflight, locked/empty-display/transient unknown, successful retry and stale asynchronous completions; no OS permission queries")
        let screen = ScreenSourceCapture(), application = AppAudioCapture()
        OwnedCaptureDiscovery.hold = true
        let screenStart = Task { await screen.start(matching: .init(target: .display, targetIdentifier: "owned-missing-display")) }
        let appStart = Task { await application.start(with: .init(mode: .system)) }
        try await SharedEncoderHarness.settle { OwnedCaptureDiscovery.pending.count == 2 }
        screen.setPermissionAvailable(false); application.setPermissionAvailable(false)
        screen.setPermissionAvailable(true); application.setPermissionAvailable(true)
        let pending = OwnedCaptureDiscovery.pending; OwnedCaptureDiscovery.pending = []
        for probe in pending { probe.resume(throwing: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)) }
        await screenStart.value; await appStart.value
        try SharedEncoderHarness.check(!screen.isCapturing && !application.isCapturing && screen.errorMessage == nil && application.errorMessage == nil,
                                       "A retired pre-denial discovery request mutated its replacement permission epoch")
        OwnedCaptureDiscovery.hold = false
        await screen.start(matching: .init(target: .display, targetIdentifier: "owned-missing-display"))
        await application.start(with: .init(mode: .system))
        try SharedEncoderHarness.check(screen.errorMessage?.contains("temporarily unavailable") == true
            && application.errorMessage?.contains("temporarily unavailable") == true,
            "Generic unavailable display discovery was mislabeled as permission denial")
        await screen.stop(); await application.stop()
        print("PASS: actual screen/app-audio request callbacks cannot resurrect or overwrite state after deny/regrant; transient discovery stays unavailable; no capture/device/TCC activation")
    }
}
