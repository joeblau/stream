import AVFAudio
import StreamCore
import os

private let audioLog = Logger(subsystem: "com.joeblau.Stream",
                              category: "audio-session")

/// Configures the shared `AVAudioSession` so that ReplayKit `.audioMic` buffers
/// originate from the user-selected (possibly Bluetooth/DJI) input route.
///
/// Notes on real-world caveats:
/// - A Bluetooth HFP mic only appears in `availableInputs` once a record-capable
///   category is set with the Bluetooth HFP option AND the session is active.
/// - `allowBluetooth` was deprecated in iOS 26 / Xcode 26 in favor of
///   `allowBluetoothHFP` (same raw value); we gate on the compiler so the source
///   still builds on older toolchains.
/// - HFP forces telephony-grade sample rates; that is an inherent platform cost,
///   not something this configurator can avoid.
enum AudioSessionConfigurator {
    /// Bluetooth-capable record options, richest first. `.allowBluetoothHFP` is the
    /// iOS 26 replacement for the deprecated `.allowBluetooth`.
    static func bluetoothOptionLadder() -> [AVAudioSession.CategoryOptions] {
        // .mixWithOthers is in EVERY rung so it is never dropped by ladder
        // degradation: without it, opening another app that plays audio is more
        // likely to hard-interrupt the extension's record session (killing the
        // mic route mid-broadcast). It governs how WE coexist with others; combine
        // with the interruption recovery below for full resilience.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return [
                [.allowBluetoothHFP, .bluetoothHighQualityRecording, .mixWithOthers],
                [.allowBluetoothHFP, .mixWithOthers],
                [.mixWithOthers]
            ]
        }
        return [[.allowBluetoothHFP, .mixWithOthers], [.mixWithOthers]]
        #else
        return [[.allowBluetooth, .mixWithOthers], [.mixWithOthers]]
        #endif
    }

    /// Activates a `.playAndRecord` session and re-applies the persisted preferred
    /// input UID (the Bluetooth mic the user chose in the app).
    ///
    /// Uses mode `.default` — NOT `.videoRecording`, which forces the built-in mic
    /// and prevents Bluetooth HFP routing. Tries the richest option set first and
    /// degrades so one unsupported option never aborts configuration.
    static func configure(with settings: StreamSettings) throws {
        let session = AVAudioSession.sharedInstance()
        var lastError: Error?
        var activated = false
        for options in bluetoothOptionLadder() {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
                activated = true
                break
            } catch {
                lastError = error
                continue
            }
        }
        if !activated, let lastError { throw lastError }

        if let uid = settings.preferredAudioInputUID {
            if let port = session.availableInputs?.first(where: { $0.uid == uid }) {
                // Re-apply the saved device whenever it returns after a route loss.
                try? session.setPreferredInput(port)
            } else {
                // Do not leave a vanished Bluetooth port pinned. This allows the
                // system to fall back until it becomes available again.
                try? session.setPreferredInput(nil)
            }
        }
    }
}

/// Owns AVAudioSession recovery for the lifetime of a ReplayKit broadcast.
/// Notification callbacks are reduced to Sendable events and serialized on one
/// queue, avoiding observer duplication and late reactivation after stop.
final class AudioSessionController: @unchecked Sendable {
    private enum Event: Sendable {
        case interruptionBegan(isRouteDisconnected: Bool)
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: UInt)
        case availableInputsChanged
        case mediaServicesReset
    }

    private let queue = DispatchQueue(label: "com.joeblau.Stream.Broadcast.audio-session")
    private var settings: StreamSettings?
    private var observerTokens: [NSObjectProtocol] = []
    private var isStopped = true
    private var isInterrupted = false
    private var recoveryGeneration = 0

    /// Process-wide session ownership. iOS reuses the extension process across
    /// broadcasts and AVAudioSession is process-global, so broadcast N's stale
    /// teardown must never deactivate broadcast N+1's session.
    private static let processEpoch = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var epoch: UInt64 = 0
    /// Lock-free stop marker read by the recovery ladder so a synchronous
    /// `stop()` (which runs under ReplayKit's tight teardown watchdog) never
    /// waits behind queued multi-second AVAudioSession recovery attempts.
    private let stopping = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Non-throwing: an initial configure failure (e.g. a broadcast started mid
    /// phone call) keeps the observers and settings installed and retries, so
    /// the mic arrives as soon as the interruption ends instead of never.
    func start(with settings: StreamSettings) {
        queue.sync {
            guard isStopped else { return }
            epoch = Self.processEpoch.withLock { value in
                value += 1
                return value
            }
            self.settings = settings
            isStopped = false
            isInterrupted = false
            stopping.withLock { $0 = false }
            installObservers()
            do {
                try AudioSessionConfigurator.configure(with: settings)
                logCurrentRoute(prefix: "Audio session active")
            } catch {
                audioLog.error("Initial audio-session setup failed; retrying: \(String(describing: error), privacy: .public)")
                recoverWithRetry()
            }
        }
    }

    func stop() {
        // Flip the lock-free marker FIRST so any queued recovery-ladder step
        // no-ops immediately; the sync barrier below then waits on at most one
        // already-started AVAudioSession call.
        stopping.withLock { $0 = true }
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            recoveryGeneration += 1
            removeObservers()
            settings = nil
            isInterrupted = false
            // Only the current owner may deactivate: a newer broadcast in this
            // reused extension process may already have claimed the session.
            guard Self.processEpoch.withLock({ $0 == epoch }) else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                // .routeDisconnected (BT mic unplugged/powered off, iOS 17+) is
                // .began-only — it never delivers a matching .ended, so it must
                // not latch the interrupted state. NOTE: the reason key is
                // deprecated in the iOS 27 SDK in favor of
                // AVAudioSessionDeactivationContext.interruptionDetails.reason;
                // migrate when the deployment target moves past 26.
                let reasonRaw = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let isRouteDisconnected = reasonRaw
                    .flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) == .routeDisconnected
                self?.enqueue(.interruptionBegan(isRouteDisconnected: isRouteDisconnected))
            } else if type == .ended {
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
                self?.enqueue(.interruptionEnded(shouldResume: shouldResume))
            }
        })

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self?.enqueue(.routeChanged(reason: reason))
        })

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.availableInputsChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.enqueue(.availableInputsChanged)
        })

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.enqueue(.mediaServicesReset)
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
    }

    private func enqueue(_ event: Event) {
        queue.async { [weak self] in self?.handle(event) }
    }

    private func handle(_ event: Event) {
        guard !isStopped else { return }
        switch event {
        case .interruptionBegan(let isRouteDisconnected):
            if isRouteDisconnected {
                // Never latches isInterrupted; configure() falls back to the
                // built-in mic (setPreferredInput(nil)) until the BT mic returns.
                audioLog.info("Recording route disconnected; reconfiguring immediately")
                recoverWithRetry()
                return
            }
            isInterrupted = true
            recoveryGeneration += 1
            audioLog.info("Audio session interrupted")
            scheduleInterruptionDeadman()

        case .interruptionEnded(let shouldResume):
            isInterrupted = false
            // ALWAYS recover — a live broadcast has no user gesture to defer
            // to, so `shouldResume` is advisory only here.
            audioLog.info("Interruption ended (shouldResume=\(shouldResume)); recovering")
            recoverWithRetry()

        case .routeChanged(let rawReason):
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            if reason == .categoryChange,
               AVAudioSession.sharedInstance().category == .playAndRecord {
                return
            }
            recoverWithRetry()

        case .availableInputsChanged, .mediaServicesReset:
            recoverWithRetry()
        }
    }

    /// No interruption state may permanently disable recovery: some
    /// interruptions never deliver .ended (races with Siri/calls,
    /// route-disconnect variants), which used to leave the mic dead for the
    /// rest of the broadcast.
    private func scheduleInterruptionDeadman() {
        let generation = recoveryGeneration
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.isStopped, self.isInterrupted,
                  self.recoveryGeneration == generation else { return }
            audioLog.warning("Interruption never ended after 10s; forcing recovery")
            self.isInterrupted = false
            self.recoverWithRetry()
        }
    }

    /// Bluetooth HFP re-establishment routinely takes 2-5 s, so the ladder is
    /// long and "configured" is verified against the actual ROUTE in recover().
    private func recoverWithRetry() {
        guard !isStopped, !isInterrupted, let settings else { return }
        recoveryGeneration += 1
        let generation = recoveryGeneration
        if recover(with: settings) { return }
        for delay in [0.5, 1.0, 2.0, 4.0, 8.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped, !self.isInterrupted,
                      self.recoveryGeneration == generation,
                      let settings = self.settings else { return }
                _ = self.recover(with: settings)
            }
        }
    }

    @discardableResult
    private func recover(with settings: StreamSettings) -> Bool {
        // Checked lock-free so an end-of-broadcast stop() never waits behind
        // queued recovery attempts (AVAudioSession calls can block for seconds
        // while a Bluetooth route is dying).
        guard !stopping.withLock({ $0 }) else { return true }
        do {
            try AudioSessionConfigurator.configure(with: settings)
        } catch {
            audioLog.error("Audio-session recovery failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // Success requires the ROUTE, not just an active session: if the
        // preferred device is advertised but not yet routed, keep the ladder
        // running until Bluetooth actually finishes re-establishing.
        let session = AVAudioSession.sharedInstance()
        if let uid = settings.preferredAudioInputUID,
           session.availableInputs?.contains(where: { $0.uid == uid }) == true,
           !session.currentRoute.inputs.contains(where: { $0.uid == uid }) {
            audioLog.info("Preferred input available but not routed yet; retrying")
            return false
        }
        logCurrentRoute(prefix: "Audio session recovered")
        return true
    }

    private func logCurrentRoute(prefix: String) {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
            .map(\.portName)
            .joined(separator: ", ")
        audioLog.info("\(prefix, privacy: .public): \(inputs, privacy: .public)")
    }
}
