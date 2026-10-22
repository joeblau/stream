import AppKit
import Combine
import CoreGraphics
import Foundation
import StreamCore

struct ExternalDisplayDescriptor: Identifiable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var frame: CGRect
    var maximumFPS: Int
    var isBuiltIn: Bool
    var hostsStudio: Bool
    var canShowCleanOutput: Bool { !isBuiltIn && !hostsStudio }
}
enum ExternalDisplayScaling: String, CaseIterable, Sendable { case fit, fill }
enum ExternalDisplayFeed: String, CaseIterable, Sendable { case program, clean, selectedCanvas, secondaryCanvas }
struct ExternalDisplayFeedRequest: Sendable {
    let feed: ExternalDisplayFeed
    let selectedDestinationID: UUID?
    let profile: OutputProfile?
}

@MainActor protocol ExternalDisplaySurface: AnyObject, Sendable {
    func move(to display: ExternalDisplayDescriptor)
    func present(_ image: CGImage, scaling: ExternalDisplayScaling)
    func close()
}

/// One pending image, independent of the compositor's capacity-one subscription.
/// A stalled AppKit loop overwrites old images instead of accumulating UI tasks.
final class ExternalDisplayMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CGImage?
    private var accepting = true
    private var overwritten: UInt64 = 0
    func enqueue(_ image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if pending != nil { overwritten += 1 }
        pending = image
    }
    func take() -> CGImage? { lock.lock(); defer { lock.unlock() }; let image = pending; pending = nil; return image }
    func finish() { lock.lock(); accepting = false; pending = nil; lock.unlock() }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }
    var droppedImages: UInt64 { lock.lock(); defer { lock.unlock() }; return overwritten }
}

@MainActor
final class ExternalDisplayOutputController: ObservableObject {
    typealias Cancel = @MainActor () -> Void
    typealias Subscribe = @MainActor (ExternalDisplayFeedRequest, @escaping @Sendable (CGImage) -> Void) async throws -> Cancel?
    enum State: Equatable { case idle, active(display: UInt32), failed(String) }
    @Published private(set) var displays: [ExternalDisplayDescriptor] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isStarting = false
    @Published var selectedDisplayID: UInt32?
    @Published var scaling: ExternalDisplayScaling = .fit
    @Published var feed: ExternalDisplayFeed = .program
    @Published var selectedDestinationID: UUID?
    @Published private(set) var presentedImages: UInt64 = 0
    private let screensProvider: @MainActor () -> [ExternalDisplayDescriptor]
    private let surfaceFactory: @MainActor (ExternalDisplayDescriptor) -> (any ExternalDisplaySurface)?
    private let subscribe: Subscribe
    private let startError: @MainActor (ExternalDisplayFeed) -> String?
    private var surface: (any ExternalDisplaySurface)?
    private var cancelSubscription: Cancel?
    private var mailbox: ExternalDisplayMailbox?
    private var outputProfile: OutputProfile?
    private var activeDisplay: ExternalDisplayDescriptor?
    private var presentationFPS: Int?
    private var startTask: Task<Void, Never>?
    private var startGeneration = UUID()
    private var pendingDisplayID: UInt32?
    private var displayRefresh: Task<Void, Never>?
    private static weak var studioWindow: NSWindow?
    private static let studioWindowChanged = Notification.Name("StreamExternalDisplayStudioWindowChanged")

    /// The studio shell supplies its actual window. Settings, sheets and clean
    /// video surfaces must never change which display contains the controls.
    static func attachStudioWindow(_ window: NSWindow?) {
        guard let window, !window.isSheet, studioWindow !== window else { return }
        studioWindow = window
        NotificationCenter.default.post(name: studioWindowChanged, object: window)
    }

    static func hostsStudio(_ frame: CGRect) -> Bool {
        // Before the shell attaches, fail closed instead of guessing from the
        // key window. Protect every intersected display when the shell spans two.
        guard let studioWindow else { return true }
        return studioWindow.frame.intersects(frame)
    }
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    init(screensProvider: @escaping @MainActor () -> [ExternalDisplayDescriptor] = ExternalDisplayOutputController.systemDisplays,
         surfaceFactory: @escaping @MainActor (ExternalDisplayDescriptor) -> (any ExternalDisplaySurface)? = { NativeExternalDisplaySurface(display: $0) },
         observeSystem: Bool = true, startError: @escaping @MainActor (ExternalDisplayFeed) -> String? = { _ in nil }, subscribe: @escaping Subscribe) {
        self.screensProvider = screensProvider; self.surfaceFactory = surfaceFactory; self.subscribe = subscribe; self.startError = startError
        refreshDisplays()
        if observeSystem {
            for name in [NSApplication.didChangeScreenParametersNotification, Self.studioWindowChanged,
                         NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleDisplayRefresh() }
                })
            }
        }
    }
    deinit {
        timer?.invalidate(); displayRefresh?.cancel(); startTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        mailbox?.finish()
        let cancel = cancelSubscription, surface = surface
        Task { @MainActor in cancel?(); surface?.close() }
    }
    private func scheduleDisplayRefresh() {
        guard displayRefresh == nil else { return }
        displayRefresh = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.displayRefresh = nil
            self.refreshDisplays()
        }
    }
    var isActive: Bool { if case .active = state { return true }; return false }
    var droppedImages: UInt64 { mailbox?.droppedImages ?? 0 }
    func refreshDisplays() {
        displays = screensProvider()
        if isStarting, let id = pendingDisplayID,
           !displays.contains(where: { $0.id == id && $0.canShowCleanOutput }) {
            stop(reason: "The output display disconnected or now hosts the studio. Choose a separate display and restart manually.")
            return
        }
        if case .active(let id) = state {
            guard let display = displays.first(where: { $0.id == id }), display.canShowCleanOutput else {
                stop(reason: "The output display disconnected or now hosts the studio. Choose a separate display and restart manually.")
                return
            }
            if activeDisplay?.frame != display.frame { surface?.move(to: display) }
            activeDisplay = display
            startTimer(fps: min(display.maximumFPS, outputProfile?.frameRate ?? 60))
        }
    }
    func start(programProfile: OutputProfile, selectedProfile: OutputProfile? = nil) {
        guard !isActive, !isStarting else { return }
        refreshDisplays()
        guard let id = selectedDisplayID, let display = displays.first(where: { $0.id == id }), display.canShowCleanOutput else {
            state = .failed("Select a connected external display that does not host the studio."); return
        }
        let usesProgramGeometry = feed == .program || feed == .clean
        let profile = usesProgramGeometry ? programProfile : selectedProfile
        guard let profile, profile.canvasWidth > 0, profile.canvasHeight > 0, profile.frameRate > 0,
              profile.canvasWidth <= 4096, profile.canvasHeight <= 4096, profile.frameRate <= 60 else {
            state = .failed("Choose an available canvas up to 4096 pixels per dimension and 60 fps."); return
        }
        if let error = startError(feed) { state = .failed(error); return }
        let request = ExternalDisplayFeedRequest(feed: feed, selectedDestinationID: selectedDestinationID,
                                                profile: profile)
        let generation = UUID(), mailbox = ExternalDisplayMailbox()
        startGeneration = generation; pendingDisplayID = id; isStarting = true
        self.mailbox = mailbox
        state = .idle
        startTask = Task { @MainActor [weak self] in
            guard let self else { mailbox.finish(); return }
            var preparedCancel: Cancel?
            do {
                guard let cancel = try await self.subscribe(request, { mailbox.enqueue($0) }) else {
                    throw ExternalDisplayStartFailure.unavailable
                }
                preparedCancel = cancel
                try Task.checkCancellation()
                guard self.startGeneration == generation, self.isStarting,
                      self.mailbox === mailbox, self.selectedDisplayID == id,
                      self.feed == request.feed, self.selectedDestinationID == request.selectedDestinationID else {
                    throw CancellationError()
                }
                self.refreshDisplays()
                try Task.checkCancellation()
                guard self.startGeneration == generation,
                      let currentDisplay = self.displays.first(where: { $0.id == id }), currentDisplay.canShowCleanOutput else {
                    throw CancellationError()
                }
                // The exact subscription has acknowledged admission/installation
                // before AppKit is allowed to construct any native video surface.
                guard let surface = self.surfaceFactory(currentDisplay) else {
                    throw ExternalDisplayStartFailure.surface
                }
                do {
                    try Task.checkCancellation()
                    guard self.startGeneration == generation else { throw CancellationError() }
                } catch { surface.close(); throw error }
                self.surface = surface; self.cancelSubscription = cancel
                preparedCancel = nil
                self.outputProfile = profile; self.activeDisplay = currentDisplay; self.presentedImages = 0
                self.pendingDisplayID = nil; self.isStarting = false; self.startTask = nil
                self.state = .active(display: id)
                self.startTimer(fps: min(currentDisplay.maximumFPS, profile.frameRate))
            } catch {
                mailbox.finish(); preparedCancel?()
                guard self.startGeneration == generation else { return }
                self.mailbox = nil; self.pendingDisplayID = nil; self.isStarting = false; self.startTask = nil
                if error is CancellationError || Task.isCancelled { self.state = .idle }
                else { self.state = .failed(error.localizedDescription) }
            }
        }
    }
    func stop(reason: String? = nil) {
        startGeneration = UUID(); startTask?.cancel(); startTask = nil
        isStarting = false; pendingDisplayID = nil
        timer?.invalidate(); timer = nil; presentationFPS = nil
        mailbox?.finish(); mailbox = nil
        cancelSubscription?(); cancelSubscription = nil
        surface?.close(); surface = nil; outputProfile = nil; activeDisplay = nil
        state = reason.map(State.failed) ?? .idle
    }
    /// Public for deterministic native display injection; shipping cadence is a
    /// main run-loop timer that skips missed ticks and consumes the newest image.
    func presentLatest() {
        guard isActive, let image = mailbox?.take() else { return }
        surface?.present(image, scaling: scaling); presentedImages += 1
    }
    private func startTimer(fps: Int) {
        let fps = max(1, min(60, fps))
        guard timer == nil || presentationFPS != fps else { return }
        timer?.invalidate(); presentationFPS = fps
        let timer = Timer(timeInterval: 1 / Double(fps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentLatest() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    static func systemDisplays() -> [ExternalDisplayDescriptor] {
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return ExternalDisplayDescriptor(id: id, name: screen.localizedName, frame: screen.frame,
                maximumFPS: screen.maximumFramesPerSecond, isBuiltIn: CGDisplayIsBuiltin(id) != 0, hostsStudio: hostsStudio(screen.frame))
        }
    }
}

private enum ExternalDisplayStartFailure: LocalizedError {
    case unavailable, surface
    var errorDescription: String? {
        switch self {
        case .unavailable: "The program feed is unavailable."
        case .surface: "The video surface could not be allocated."
        }
    }
}

@MainActor private final class CleanDisplayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class NativeExternalDisplaySurface: ExternalDisplaySurface {
    let window: NSWindow
    private let video = NSView()
    init?(display: ExternalDisplayDescriptor) {
        guard display.frame.width > 0, display.frame.height > 0 else { return nil }
        window = CleanDisplayWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.backgroundColor = .black; window.colorSpace = .sRGB; window.level = .floating
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        video.wantsLayer = true; video.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = video
        window.orderFrontRegardless()
    }
    func move(to display: ExternalDisplayDescriptor) { window.setFrame(display.frame, display: true) }
    func present(_ image: CGImage, scaling: ExternalDisplayScaling) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.layer?.contentsGravity = scaling == .fit ? .resizeAspect : .resizeAspectFill
        video.layer?.contents = image
        video.layer?.contentsScale = window.backingScaleFactor
        video.layer?.masksToBounds = true
        CATransaction.commit()
    }
    func close() { video.layer?.contents = nil; window.orderOut(nil); window.close() }
}
