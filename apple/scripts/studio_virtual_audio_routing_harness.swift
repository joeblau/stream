import AVFoundation
import CoreAudio
import Foundation
import StreamCore

private final class OwnedMonitorPlayback: MonitorPlaybackBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AudioDeviceID?] = []
    var failure: String?
    func configure(deviceID: AudioDeviceID?) -> String? {
        lock.withLock { values.append(deviceID) }
        return deviceID == nil ? nil : failure
    }
    func play(_ sample: CMSampleBuffer) {}
    func statistics() -> MonitorPlaybackStatistics { .init() }
    var calls: [AudioDeviceID?] { lock.withLock { values } }
}

@main struct VirtualAudioRoutingHarness {
    @MainActor static func main() {
        let owned = StudioAudioDeviceRouting.virtualMicrophonePrototypeUID
        precondition(!StudioAudioDeviceRouting.allowsCaptureOrMonitoring(deviceUID: owned))
        for uid in ["USB-interface", "BuiltInMicrophoneDevice", "other.vendor.virtual", owned + ".other", owned.uppercased()] {
            precondition(StudioAudioDeviceRouting.allowsCaptureOrMonitoring(deviceUID: uid))
        }

        var outputs = [MonitorOutputDevice(deviceID: 1, uid: owned, name: "Renamed output"),
                       MonitorOutputDevice(deviceID: 2, uid: "headphones", name: "Stream Studio Microphone Prototype")]
        var defaultID: AudioDeviceID? = 1
        var unknownUID = false
        var replacementUID: String?
        var defaultReads = 0
        let playback = OwnedMonitorPlayback()
        let monitor = MonitorOutput(availableOutputs: { outputs }, defaultOutputDeviceID: {
            defaultReads += 1; return defaultID
        }, deviceUID: { id in
            if unknownUID { return nil }
            if let replacementUID { return replacementUID }
            return outputs.first { $0.deviceID == id }?.uid
        }, observeHardware: false, playback: playback)
        precondition(monitor.devices.map(\.uid) == ["headphones"] && playback.calls.isEmpty)
        monitor.applyConfiguration(enabled: true, deviceUID: nil)
        precondition(playback.calls == [nil] && monitor.effectiveDeviceUID == nil)
        precondition(monitor.errorMessage == StudioAudioDeviceRouting.feedbackRepair && monitor.isEnabled)
        defaultID = 2; monitor.hardwareChanged()
        precondition(playback.calls.last! == 2 && monitor.effectiveDeviceUID == "headphones" && monitor.errorMessage == nil)
        let reads = defaultReads
        monitor.applyConfiguration(enabled: true, deviceUID: owned)
        precondition(playback.calls.last! == nil && defaultReads == reads && !monitor.isFallbackActive)
        precondition(monitor.selectedDeviceUID == owned && monitor.effectiveDeviceUID == nil)
        defaultID = 1
        monitor.applyConfiguration(enabled: true, deviceUID: "pinned-interface")
        precondition(!monitor.isFallbackActive && monitor.selectedDeviceUID == "pinned-interface")
        precondition(playback.calls.last! == nil && monitor.errorMessage == StudioAudioDeviceRouting.feedbackRepair)
        defaultID = 2; monitor.hardwareChanged()
        precondition(monitor.isFallbackActive && monitor.effectiveDeviceUID == "headphones")
        outputs.append(.init(deviceID: 3, uid: "pinned-interface", name: "Other virtual interface"))
        monitor.hardwareChanged()
        precondition(!monitor.isFallbackActive && monitor.effectiveDeviceUID == "pinned-interface" && playback.calls.last! == 3)
        let count = playback.calls.count
        defaultID = 1; monitor.hardwareChanged()
        precondition(playback.calls.count == count && monitor.effectiveDeviceUID == "pinned-interface")
        monitor.applyConfiguration(enabled: true, deviceUID: nil)
        precondition(playback.calls.last! == nil && monitor.effectiveDeviceUID == nil)
        unknownUID = true; defaultID = 2; monitor.hardwareChanged()
        precondition(playback.calls.last! == nil && monitor.effectiveDeviceUID == nil && monitor.errorMessage != nil)
        unknownUID = false; playback.failure = "Owned configuration refusal"; monitor.hardwareChanged()
        precondition(monitor.effectiveDeviceUID == nil && monitor.errorMessage == playback.failure)
        monitor.applyConfiguration(enabled: true, deviceUID: "ordinary-missing")
        precondition(!monitor.isFallbackActive && monitor.effectiveDeviceUID == nil && monitor.errorMessage == playback.failure)
        monitor.applyConfiguration(enabled: true, deviceUID: nil)
        playback.failure = nil; monitor.hardwareChanged()
        precondition(monitor.effectiveDeviceUID == "headphones" && monitor.errorMessage == nil)
        let prior = playback.calls.count
        replacementUID = "replacement-default"
        monitor.hardwareChanged()
        precondition(playback.calls.count == prior + 1 && playback.calls.last! == 2)
        precondition(monitor.effectiveDeviceUID == "replacement-default")
        monitor.applyConfiguration(enabled: true, deviceUID: "headphones")
        precondition(playback.calls.last! == nil && monitor.effectiveDeviceUID == nil && monitor.errorMessage != nil)
        precondition(!monitor.isFallbackActive, "A stale explicit device identity cannot silently open a different device")
        replacementUID = nil; monitor.hardwareChanged()
        precondition(monitor.effectiveDeviceUID == "headphones" && monitor.errorMessage == nil)
        monitor.applyConfiguration(enabled: false, deviceUID: nil)
        precondition(playback.calls.last! == nil && monitor.effectiveDeviceUID == nil && !monitor.isEnabled)
        precondition(!playback.calls.contains { $0 == 1 }, "Owned loopback must never reach the playback boundary")

        var resolutions: [String] = []
        var defaultInput = owned
        let input = MacAudioInput(discoverDevices: { [] }, defaultDeviceUID: { defaultInput }, resolveDevice: {
            resolutions.append($0); return nil
        })
        input.start()
        precondition(input.errorMessage == StudioAudioDeviceRouting.feedbackRepair && resolutions.isEmpty)
        input.start(preferredDeviceUID: owned)
        input.start(deviceUID: owned)
        precondition(input.errorMessage == StudioAudioDeviceRouting.feedbackRepair && resolutions.isEmpty)
        input.startAdditionalInputs([.init(deviceUID: owned, mapping: .mono(1)),
                                     .init(deviceUID: "ordinary-missing", mapping: .stereo(2, 3)),
                                     .init(deviceUID: "disabled-other", isEnabled: false)])
        precondition(input.additionalInputs.map(\.deviceUID) == [owned, "ordinary-missing"])
        precondition(input.additionalInputErrors[owned] == StudioAudioDeviceRouting.feedbackRepair)
        precondition(input.missingAdditionalDeviceUIDs == ["ordinary-missing"])
        precondition(input.additionalInputs[0].mapping == .mono(1) && input.additionalInputs[1].mapping == .stereo(2, 3))
        input.noteAudioDeviceConnected(); input.noteAudioDeviceDisconnected()
        precondition(resolutions.isEmpty && input.additionalInputErrors[owned] != nil)
        input.startAdditionalInputs([.init(deviceUID: "ordinary-missing", mapping: .stereo(2, 3))])
        precondition(input.additionalInputErrors[owned] == nil && input.additionalInputs[0].mapping == .stereo(2, 3))
        // The ordinary missing selection still follows the existing default
        // fallback, and the fallback receives the same admission check.
        input.start(preferredDeviceUID: "ordinary-missing")
        precondition(input.errorMessage == StudioAudioDeviceRouting.feedbackRepair && resolutions.isEmpty)
        defaultInput = "ordinary-default"; input.start(preferredDeviceUID: nil)
        precondition(resolutions == ["ordinary-default"] && input.errorMessage != nil)
        input.stop()
        precondition(!input.isCapturing(.microphone(deviceUID: nil)))
        print("PASS: production input/default/persisted/additional admission before resolution/permission; exact UID only; production monitor discovery, explicit/default/fallback/hotplug retirement/recovery, unknown identity refusal and ordinary device preservation. Owned read/playback boundaries only; no HAL install, audio playback/capture, permission request or default-device mutation.")
    }
}
