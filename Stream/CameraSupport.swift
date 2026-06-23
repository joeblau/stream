import Foundation
import AVFoundation

/// Drives the facecam UI: requests camera permission (so the broadcast extension,
/// which cannot prompt, finds it already granted) and reports whether this device
/// can run the camera *during a system broadcast* at all.
///
/// The facecam is composited inside the broadcast upload extension, which runs
/// while another app is in the foreground. iOS only allows that when
/// `AVCaptureSession.isMultitaskingCameraAccessSupported` is true — historically
/// iPad Pro / iPad Air and other multitasking-camera devices; most iPhones report
/// false, in which case the facecam cannot run and the stream stays screen-only.
@MainActor
@Observable
final class CameraSupport {

    enum Permission {
        case undetermined
        case granted
        case denied
    }

    private(set) var permission: Permission = .undetermined

    /// Whether the camera can run during a system broadcast on this device.
    let multitaskingSupported: Bool

    init() {
        // Reading the capability off a non-running session reflects the hardware.
        multitaskingSupported = AVCaptureSession().isMultitaskingCameraAccessSupported
        syncPermission()
    }

    func refresh() {
        syncPermission()
    }

    /// Requests camera permission if needed. Must be called from the app (the
    /// extension can't), ideally when the user enables the facecam.
    func request() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .denied, .restricted:
            permission = .denied
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.permission = granted ? .granted : .denied
                }
            }
        @unknown default:
            permission = .undetermined
        }
    }

    private func syncPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = .granted
        case .denied, .restricted: permission = .denied
        case .notDetermined: permission = .undetermined
        @unknown default: permission = .undetermined
        }
    }
}
