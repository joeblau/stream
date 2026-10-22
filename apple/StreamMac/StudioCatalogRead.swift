import Foundation
import StreamCore

/// A failed read is not a fresh installation. Callers may auto-save a new
/// catalog only when the original read AND a separate path check confirm
/// absence; unreadable/invalid existing bytes stay under explicit recovery.
enum StudioCatalogRead {
    struct Snapshot {
        let catalog: StudioProjectCatalog
        let recoveryFile: URL?
    }

    static func load(at url: URL) -> Snapshot {
        do {
            let data = try Data(contentsOf: url)
            if let catalog = try? JSONDecoder().decode(StudioProjectCatalog.self, from: data),
               catalog.validationError == nil {
                return Snapshot(catalog: catalog, recoveryFile: nil)
            }
        } catch {
            if isMissing(error) {
                do {
                    // attributesOfItem observes a dangling symlink itself;
                    // fileExists would follow it and report a false absence.
                    _ = try FileManager.default.attributesOfItem(atPath: url.path)
                } catch {
                    if isMissing(error) {
                        return Snapshot(catalog: StudioProjectCatalog(), recoveryFile: nil)
                    }
                }
            }
        }
        let backups = (try? ProjectDocumentHistory.validBackups(for: url)) ?? []
        let recovered = backups.compactMap { backup -> StudioProjectCatalog? in
            guard let bytes = try? Data(contentsOf: backup),
                  let catalog = try? JSONDecoder().decode(StudioProjectCatalog.self, from: bytes),
                  catalog.validationError == nil else { return nil }
            return catalog
        }.first ?? StudioProjectCatalog()
        return Snapshot(catalog: recovered, recoveryFile: url)
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }
}
