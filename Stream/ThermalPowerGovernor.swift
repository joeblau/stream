import Foundation

/// A throttle ceiling derived from the device's thermal and power state.
///
/// The broadcast has no environmental awareness on its own: a healthy-network
/// stream encodes at full rate until iOS hard-throttles or terminates it. This
/// ceiling is fed into the *existing* adaptive path — the network ABR still owns
/// the final rate by taking the `min()` of the network and thermal ceilings — so
/// a hot or battery-constrained device sheds encoder, network, and camera load
/// before the OS does it for us.
struct ThermalPowerCeiling: Equatable {
    /// Fraction of the configured maximum video bitrate to allow (0...1).
    var bitRateScale: Double
    /// Hard frame-rate ceiling. `.max` means "no thermal cap".
    var frameRateCap: Int
    /// When false, the facecam is stopped to shed camera + compositor cost.
    var allowPiP: Bool
    /// User-facing reason, or nil when the device is unrestricted.
    var notice: String?

    static let unrestricted = ThermalPowerCeiling(
        bitRateScale: 1.0, frameRateCap: .max, allowPiP: true, notice: nil
    )
}

/// Maps `ProcessInfo` thermal + Low Power state to a `ThermalPowerCeiling`.
enum ThermalPowerGovernor {
    /// Pure policy: state in, ceiling out. Side-effect free so the mapping reads
    /// clearly and can be reasoned about (and exercised) in isolation.
    static func ceiling(thermalState: ProcessInfo.ThermalState,
                        lowPowerMode: Bool) -> ThermalPowerCeiling {
        switch thermalState {
        case .critical:
            // Shed aggressively — the OS is about to throttle or kill us anyway.
            return ThermalPowerCeiling(bitRateScale: 0.35, frameRateCap: 10,
                                       allowPiP: false,
                                       notice: "Cooling down — quality reduced")
        case .serious:
            return ThermalPowerCeiling(bitRateScale: 0.6, frameRateCap: 24,
                                       allowPiP: true,
                                       notice: "Device warm — quality reduced")
        case .fair, .nominal:
            // Low Power Mode pulls encoder/network cost back, but must not silently
            // remove the user's facecam. Camera shedding remains reserved for a
            // critical thermal emergency, where keeping it alive risks an
            // OS-level capture interruption or termination.
            return lowPowerMode
                ? ThermalPowerCeiling(bitRateScale: 0.75, frameRateCap: 30,
                                      allowPiP: true,
                                      notice: "Low Power Mode — quality reduced")
                : .unrestricted
        @unknown default:
            return .unrestricted
        }
    }

    /// The ceiling for the device's current thermal + power state.
    static func current() -> ThermalPowerCeiling {
        ceiling(thermalState: ProcessInfo.processInfo.thermalState,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
