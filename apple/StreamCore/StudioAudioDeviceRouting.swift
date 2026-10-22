import Foundation

/// The owned loopback input is an output of this studio, never a microphone
/// or confidence-monitor destination. Match identity, not a device's label:
/// unrelated virtual/aggregate devices remain operator-selectable.
public enum StudioAudioDeviceRouting {
    public static let virtualMicrophonePrototypeUID = "com.joeblau.Stream.VirtualMicrophonePrototype.device"
    public static let feedbackRepair = "Stream Studio Microphone is a studio output. Choose a different microphone or monitor device to prevent feedback."

    public static func allowsCaptureOrMonitoring(deviceUID: String) -> Bool {
        deviceUID != virtualMicrophonePrototypeUID
    }
}
