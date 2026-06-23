import AVFAudio
import StreamCore

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
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return [
                [.allowBluetoothHFP, .bluetoothHighQualityRecording, .mixWithOthers],
                [.allowBluetoothHFP, .mixWithOthers],
                [.allowBluetoothHFP],
                []
            ]
        }
        return [[.allowBluetoothHFP, .mixWithOthers], [.allowBluetoothHFP], []]
        #else
        return [[.allowBluetooth, .mixWithOthers], [.allowBluetooth], []]
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

        if let uid = settings.preferredAudioInputUID,
           let port = session.availableInputs?.first(where: { $0.uid == uid }) {
            // setPreferredInput can return success yet not switch when multiple
            // BT devices are connected; we best-effort it and ignore failures.
            try? session.setPreferredInput(port)
        }
    }
}
