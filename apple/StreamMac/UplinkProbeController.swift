import Foundation
import StreamCore

@MainActor
final class UplinkProbeController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var uploadedBytes = 0
    @Published private(set) var result: UplinkProbeResult?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var session: URLSession?
    private var generation = UUID()

    func start(onMeasurement: @escaping (Double) -> Void) {
        guard !isRunning else { return }
        let generation = UUID()
        self.generation = generation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = UplinkProbe.durationSeconds
        configuration.timeoutIntervalForResource = UplinkProbe.durationSeconds
        let session = URLSession(configuration: configuration)
        self.session = session
        isRunning = true
        uploadedBytes = 0
        error = nil
        result = nil
        task = Task { [weak self] in
            let deadline = Task {
                try? await Task.sleep(for: .seconds(UplinkProbe.durationSeconds))
                if !Task.isCancelled { session.invalidateAndCancel() }
            }
            defer { deadline.cancel(); session.invalidateAndCancel() }
            do {
                let measured = try await UplinkProbe(session: session).run { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.uploadedBytes = bytes
                    }
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.result = measured
                self.isRunning = false
                onMeasurement(measured.megabitsPerSecond)
            } catch {
                guard let self, self.generation == generation else { return }
                self.isRunning = false
                self.error = Task.isCancelled ? "Uplink test canceled." :
                    "The short uplink test did not complete. Check connectivity and try again. No new measurement was saved."
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        isRunning = false
        error = "Uplink test canceled."
    }
}
