import CoreMediaIO
import Foundation

do {
    let camera = try StreamCameraProvider()
    CMIOExtensionProvider.startService(provider: camera.provider)
    withExtendedLifetime(camera) { CFRunLoopRun() }
} catch {
    NSLog("Stream Studio camera initialization failed: %@", error.localizedDescription)
    exit(EXIT_FAILURE)
}
