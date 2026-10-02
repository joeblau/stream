import Foundation

extension StudioControllerManager {
    /// Runtime owns this manager, binds it once, and shuts it down before
    /// replacing a project's graph. Captured scope prevents late input from
    /// crossing that boundary even during a listener/CoreMIDI callback.
    func bind(to dispatcher: StudioCommandDispatcher) {
        let directory = DesktopStorage.projectDirectory
        scopeIsCurrent = { DesktopStorage.projectDirectory == directory }
        targets = { [weak dispatcher] in dispatcher?.controllerTargets() ?? [] }
        currentRunID = { [weak dispatcher] in dispatcher?.macros.isRunning == true ? dispatcher?.macros.progress.runID : nil }
        cancelRun = { [weak dispatcher] id in if dispatcher?.macros.progress.runID == id { dispatcher?.macros.cancel() } }
        start()
    }
}
