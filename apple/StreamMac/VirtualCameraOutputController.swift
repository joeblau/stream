import AppKit
import Combine
import CoreMediaIO
import Foundation
import StreamCore
import SystemExtensions

/// A bank is admitted synchronously before any native CMIO construction.
/// Installation returns only after the engine has accepted the private-frame
/// delivery. Cancellation revokes that delivery and retires its exact bank.
struct VirtualCameraFrameAdmission: Sendable {
    let bank: RawVideoResourceBank
    let cadence: FrameDeliveryCameraCadence
    let install: @MainActor @Sendable (@escaping @Sendable (CMSampleBuffer) -> Void) async throws -> Void
    let cancel: @MainActor @Sendable () -> Void
}

@MainActor final class VirtualCameraFrameInstallState {
    let cancellation = FrameDeliveryCancellation()
    var lease: FrameDeliveryLease?
    var cancelled = false
}

@MainActor
final class VirtualCameraOutputController: NSObject, ObservableObject, @preconcurrency OSSystemExtensionRequestDelegate {
    typealias Cancel = @MainActor () -> Void
    typealias Prepare = @MainActor (VirtualCameraFormat, CGSize?) throws -> VirtualCameraFrameAdmission
    enum Activation: Equatable {
        case unknown, requesting, approvalRequired, approved, removed, rebootRequired, failed(String)
        var description: String {
            switch self {
            case .unknown: return "Camera extension activation has not been requested."
            case .requesting: return "Waiting for macOS extension activation."
            case .approvalRequired: return "Approve Stream Studio Camera in System Settings, then refresh."
            case .approved: return "macOS completed the activation request."
            case .removed: return "macOS completed the removal request."
            case .rebootRequired: return "macOS requires a restart to complete this extension change."
            case .failed(let text): return text
            }
        }
    }
    @Published private(set) var activation: Activation = .unknown
    @Published private(set) var deviceAvailable = false
    @Published private(set) var isActive = false
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    @Published private(set) var sentFrames: UInt64 = 0
    @Published private(set) var droppedFrames: UInt64 = 0
    @Published var format: VirtualCameraFormat = .hd720
    @Published var feed: ExternalDisplayFeed = .program
    @Published var selectedDestinationID: UUID?
    private let prepare: Prepare
    private let producerFactory: @MainActor (VirtualCameraFormat, FrameDeliveryCameraCadence) throws -> VirtualCameraProducer
    private let deviceProbe: @MainActor () -> Bool
    private var producer: VirtualCameraProducer?
    private var cancelSubscription: Cancel?
    private var request: OSSystemExtensionRequest?
    private var removing = false
    private var intent = UUID()
    private var startTask: Task<Void, Never>?
    private var preparingProducer: VirtualCameraProducer?
    private var preparingAdmission: VirtualCameraFrameAdmission?
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    init(observeSystem: Bool = true,
         deviceProbe: @escaping @MainActor () -> Bool = { VirtualCameraProducer.discover() != nil },
         producerFactory: @escaping @MainActor (VirtualCameraFormat, FrameDeliveryCameraCadence) throws -> VirtualCameraProducer = { try VirtualCameraProducer(format: $0, cadence: $1) },
         prepare: @escaping Prepare) {
        self.prepare = prepare; self.deviceProbe = deviceProbe; self.producerFactory = producerFactory
        super.init()
        guard observeSystem else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(); self?.error = "Virtual camera stopped for sleep or user switching. Restart it manually." }
            })
        }
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        producer?.stop()
        preparingProducer?.stop(); startTask?.cancel()
        let cancel = cancelSubscription; Task { @MainActor in cancel?() }
        let pending = preparingAdmission; Task { @MainActor in pending?.cancel() }
    }
    func refresh() {
        deviceAvailable = deviceProbe()
        if isActive || isPreparing, !deviceAvailable { stop(); error = "The virtual camera disconnected. Activate or refresh it before restarting." }
        if let producer { let stats = producer.statistics; sentFrames = stats.sent; droppedFrames = stats.dropped }
    }
    func activateExtension() { submit(removing: false) }
    func removeExtension() { stop(); submit(removing: true) }
    private func submit(removing: Bool) {
        guard request == nil else { return }
        guard Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/") else {
            activation = .failed("Activate the signed app from /Applications. A development tool or build-folder app cannot activate a camera extension."); return
        }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(VirtualCameraContract.extensionID).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { activation = .failed("This app does not contain the camera extension."); return }
        self.removing = removing
        let request = removing
            ? OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VirtualCameraContract.extensionID, queue: .main)
            : OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VirtualCameraContract.extensionID, queue: .main)
        request.delegate = self; self.request = request; activation = .requesting
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        if self.request === request { activation = .approvalRequired }
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard self.request === request else { return }
        self.request = nil
        activation = result == .completed ? (removing ? .removed : .approved) : .rebootRequired
        refresh()
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard self.request === request else { return }
        self.request = nil; activation = .failed("Camera extension request failed: \(error.localizedDescription)")
        refresh()
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard self.request === request, !removing else { return .cancel }
        // An operator-requested Activate may update this same bundled camera;
        // never downgrade an installed newer extension silently.
        return replacement.bundleVersion.compare(existing.bundleVersion, options: .numeric) == .orderedAscending ? .cancel : .replace
    }
    func start(programAvailable: Bool, selectedProfile: OutputProfile? = nil) {
        guard !isActive, !isPreparing else { return }
        guard programAvailable else { error = "Start the studio preview or another production output before starting the virtual camera."; return }
        guard feed == .program || selectedProfile != nil else { error = "Choose an available destination canvas or Take a secondary layout to Program."; return }
        do {
            let selectedFormat = format, selectedFeed = feed, selectedDestination = selectedDestinationID
            let canvas = feed == .selectedCanvas ? selectedProfile?.canvasSize : nil
            let admission = try prepare(format, canvas)
            guard admission.bank.descriptor == RawVideoBankDescriptor(width: format.width, height: format.height, capacity: 4) else {
                admission.cancel()
                throw VirtualCameraProducer.Failure(message: "The virtual camera's private video resources no longer match its format.")
            }
            let producer: VirtualCameraProducer
            do { producer = try producerFactory(format, admission.cadence) }
            catch { admission.cancel(); throw error }
            let attempt = UUID(); intent = attempt
            preparingProducer = producer; preparingAdmission = admission
            isPreparing = true; error = nil
            startTask = Task { @MainActor [weak self] in
                do {
                    try Task.checkCancellation()
                    try await admission.install { producer.appendPrepared($0) }
                    try Task.checkCancellation()
                    guard let self, self.intent == attempt, self.preparingProducer === producer,
                          self.format == selectedFormat, self.feed == selectedFeed,
                          self.selectedDestinationID == selectedDestination else { throw CancellationError() }
                    self.producer = producer; self.cancelSubscription = admission.cancel
                    self.preparingProducer = nil; self.preparingAdmission = nil; self.startTask = nil
                    self.isPreparing = false; self.isActive = true
                    self.error = nil; self.sentFrames = 0; self.droppedFrames = 0
                } catch {
                    admission.cancel(); producer.stop()
                    guard let self, self.intent == attempt else { return }
                    self.preparingProducer = nil; self.preparingAdmission = nil; self.startTask = nil
                    self.isPreparing = false; self.isActive = false
                    if !(error is CancellationError) {
                        self.error = (error as? VirtualCameraProducer.Failure)?.message ?? error.localizedDescription
                    }
                }
            }
        } catch { self.error = (error as? VirtualCameraProducer.Failure)?.message ?? error.localizedDescription }
    }
    func stop() {
        intent = UUID(); startTask?.cancel(); startTask = nil
        preparingAdmission?.cancel(); preparingAdmission = nil
        preparingProducer?.stop(); preparingProducer = nil; isPreparing = false
        cancelSubscription?(); cancelSubscription = nil
        producer?.stop(); producer = nil; isActive = false
    }
    func shutdown() { stop(); timer?.invalidate(); timer = nil }
}
