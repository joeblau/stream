import Foundation
import AVFAudio
import StreamCore

/// Observable helper that configures `AVAudioSession` so Bluetooth/DJI mic
/// inputs surface, enumerates `availableInputs`, exposes name/uid pairs, and
/// writes the chosen uid into `StreamSettings.preferredAudioInputUID`.
///
/// MUST compile and behave gracefully on the Simulator, where there are no
/// Bluetooth routes (the inputs list will simply be sparse/empty).
@MainActor
@Observable
final class AudioInputProvider {

    /// A selectable audio input surfaced from the audio session.
    struct Input: Identifiable, Hashable {
        let uid: String
        let displayName: String
        let isBluetooth: Bool
        var id: String { uid }
    }

    /// Microphone permission state, mirrored for the UI.
    enum Permission {
        case undetermined
        case granted
        case denied
    }

    /// The list of available inputs, Bluetooth/DJI ones flagged.
    private(set) var inputs: [Input] = []

    /// Current microphone permission state.
    private(set) var permission: Permission = .undetermined

    init() {
        syncPermissionState()
    }

    /// Requests mic permission if needed, configures a record-capable session
    /// with Bluetooth options so BT inputs appear, then enumerates inputs.
    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
            configureAndEnumerate()
        case .denied:
            permission = .denied
            inputs = []
        case .undetermined:
            permission = .undetermined
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permission = granted ? .granted : .denied
                    if granted { self.configureAndEnumerate() }
                }
            }
        @unknown default:
            permission = .undetermined
        }
    }

    /// Writes the chosen uid into the settings and, when granted, applies it as
    /// the preferred input on the session so the route is correct in-app.
    func select(uid: String?, into settings: inout StreamSettings) {
        settings.preferredAudioInputUID = uid
        guard permission == .granted, let uid else { return }
        let session = AVAudioSession.sharedInstance()
        if let port = session.availableInputs?.first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(port)
        }
    }

    // MARK: - Private

    private func syncPermissionState() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = .granted
        case .denied: permission = .denied
        case .undetermined: permission = .undetermined
        @unknown default: permission = .undetermined
        }
    }

    private func configureAndEnumerate() {
        let session = AVAudioSession.sharedInstance()
        Self.activateBluetoothRecording(session)
        enumerate(from: session)
    }

    private func enumerate(from session: AVAudioSession) {
        let available = session.availableInputs ?? []
        inputs = available.map { port in
            let isBT = port.portType == .bluetoothHFP || port.portType == .bluetoothLE
            return Input(
                uid: port.uid,
                displayName: port.portName,
                isBluetooth: isBT
            )
        }
    }

    /// Activates a record-capable session that surfaces Bluetooth inputs.
    ///
    /// Critically uses mode `.default` — NOT `.videoRecording`, which makes iOS
    /// prefer the built-in mic and hides Bluetooth HFP inputs (the reason DJI/BT
    /// mics weren't selectable). Tries the richest Bluetooth option set first and
    /// degrades, so one unsupported option never blocks enumeration.
    @discardableResult
    static func activateBluetoothRecording(_ session: AVAudioSession) -> Bool {
        for options in bluetoothOptionLadder() {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
                return true
            } catch {
                continue
            }
        }
        return false
    }

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
}
