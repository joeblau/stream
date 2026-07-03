import Foundation
import Photos

/// Drives Photos add-only permission for the Local Backup feature: the prompt is
/// requested when the user enables "Record Local Backup" (opting in to keeping a
/// local copy implies wanting to save it), so that — like the facecam camera
/// prompt — access is already granted by the time a backup is ready to save.
///
/// `@MainActor @Observable`: mirrors the existing `CameraSupport` helper so
/// `SettingsView` can own it as `@State` and reflect the permission state.
@MainActor
@Observable
final class PhotosSupport {

    enum Permission {
        case undetermined
        case authorized
        case denied
    }

    private(set) var permission: Permission = .undetermined

    init() {
        refresh()
    }

    /// Mirrors the current add-only authorization status into `permission`.
    func refresh() {
        permission = Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    /// Requests add-only Photos access. Called when the user toggles Local Backup
    /// on; a no-op prompt if access was already decided.
    func request() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            permission = Self.map(status)
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> Permission {
        switch status {
        case .authorized, .limited: return .authorized
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
    }
}
