import CoreAudio
import Foundation

/// A07 (issue #119): one CoreAudio device with at least one OUTPUT stream — a
/// candidate monitor destination. Identity is the stable HAL device UID: the
/// same string `AVCaptureDevice.uniqueID` reports for audio devices, which is
/// what lets the feedback-risk check compare monitor outputs against enabled
/// A05 inputs directly.
struct MonitorOutputDevice: Hashable, Sendable, Identifiable {
    /// The HAL `AudioDeviceID` (valid only while the device is connected).
    let deviceID: AudioDeviceID
    /// The stable `kAudioDevicePropertyDeviceUID` — persisted in settings.
    let uid: String
    /// The user-facing device name.
    let name: String

    var id: String { uid }
}

/// CoreAudio HAL reads for the monitor-output surface. macOS 14 API reality
/// (documented for the issue): an app CAN enumerate output devices and aim an
/// `AVAudioEngine` at one of them (via `kAudioOutputUnitProperty_CurrentDevice`
/// on the output node's AudioUnit — there is no public `AVAudioEngine`
/// device-setter, and `AVAudioSession` output routing is iOS-only). What an
/// app canNOT do is build a multi-output aggregate or split one mix across
/// devices — that requires an OS-level Aggregate/Multi-Output Device built by
/// the user in Audio MIDI Setup; the picker below lists such devices once the
/// user creates them, so OS-level routing composes with in-app selection
/// instead of fighting it.
enum MonitorOutputDevices {
    /// Every connected device that has at least one output stream, in HAL
    /// order (built-ins first, then USB/Bluetooth/virtual devices).
    static func availableOutputs() -> [MonitorOutputDevice] {
        deviceIDs().compactMap { id in
            guard hasOutputStreams(id), let uid = deviceUID(id) else { return nil }
            return MonitorOutputDevice(deviceID: id,
                                       uid: uid,
                                       name: deviceName(id) ?? uid)
        }
    }

    /// The system default OUTPUT device's HAL id (nil when none exists).
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }

    /// The stable UID of a connected device (nil on read failure).
    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - HAL reads

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address,
                                             0, nil, &size) == noErr
        else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func stringProperty(_ deviceID: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address,
                                         0, nil, &size, &value) == noErr
        else { return nil }
        return value as String
    }
}

/// Watches the two hardware properties the monitor output reacts to: the
/// device LIST (hot-plug: the selected output leaving/returning) and the
/// system DEFAULT output (the user re-routing in System Settings while "System
/// Default" is selected). Blocks are registered on the main queue; delivery
/// hops to the main actor before touching `MonitorOutput` state.
final class AudioHardwareListener {
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    /// Retained so `deinit` removes exactly the blocks that were added.
    private let devicesBlock: AudioObjectPropertyListenerBlock
    private let defaultOutputBlock: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @Sendable () -> Void) {
        devicesBlock = { _, _ in onChange() }
        defaultOutputBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                            DispatchQueue.main, devicesBlock)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                            DispatchQueue.main, defaultOutputBlock)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                               DispatchQueue.main, devicesBlock)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                               DispatchQueue.main, defaultOutputBlock)
    }
}
