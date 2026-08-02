import Foundation
import AVFoundation

/// Drives facecam permission and reports whether this device can keep the camera
/// active while the user switches away during full-display capture.
///
/// The facecam is composited into ScreenCaptureKit frames in the host app. iOS
/// only allows its camera session to continue in the background when
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
    private(set) var multitaskingSupported = false

    init() {
        syncPermission()
    }

    func refresh() {
        syncPermission()
        // Constructing an AVCaptureSession can synchronously consult media-server
        // state. Do it only when PiP is opened and never in the sheet's main-actor
        // presentation turn.
        Task {
            let supported = await Task.detached(priority: .utility) {
                AVCaptureSession().isMultitaskingCameraAccessSupported
            }.value
            multitaskingSupported = supported
        }
    }

    /// Requests camera permission when the user enables the facecam.
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
