import CoreMediaIO
import Foundation
import Security

/// Framework-managed IPC: one signed host producer, two queued buffers, and
/// at most one consume request. Source-camera clients have separate lifetime.
final class StreamCameraSink: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private let mailbox: VirtualCameraMailbox
    private let lock = NSRecursiveLock()
    private var client: CMIOExtensionClient?
    private var timer: DispatchSourceTimer?
    private var consuming = false
    private var generation: UInt64 = 0
    private var index = 0
    init(formats: [CMIOExtensionStreamFormat], mailbox: VirtualCameraMailbox) {
        self.formats = formats; self.mailbox = mailbox
        super.init()
        stream = CMIOExtensionStream(localizedName: "Stream Studio Program Input", streamID: VirtualCameraContract.sinkStreamID,
            direction: .sink, clockType: .hostTime, source: self)
    }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        lock.lock(); defer { lock.unlock() }
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        result.activeFormatIndex = index; result.frameDuration = CMTime(value: 1, timescale: 30)
        result.sinkBufferQueueSize = 2; result.sinkBuffersRequiredForStartup = 1
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        lock.lock(); defer { lock.unlock() }
        if let index = properties.activeFormatIndex {
            guard formats.indices.contains(index) else { throw NSError(domain: "StreamCamera", code: 1) }
            self.index = index
        }
        if let duration = properties.frameDuration, CMTimeCompare(duration, CMTime(value: 1, timescale: 30)) != 0 { throw NSError(domain: "StreamCamera", code: 2) }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.client == nil || self.client?.clientID == client.clientID,
              client.signingID == "com.joeblau.StreamMac",
              let team = Bundle.main.object(forInfoDictionaryKey: "StreamVirtualOutputTeam") as? String,
              !team.isEmpty, !team.contains("$("), Self.trustedProducer(pid: client.pid, team: team) else { return false }
        self.client = client
        return true
    }
    static func trustedProducer(pid: pid_t, team: String) -> Bool {
        guard team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), team.count == 10 else { return false }
        var code: SecCode?, requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"com.joeblau.StreamMac\" and certificate leaf[subject.OU] = \"\(team)\""
        return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess
            && SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
            && code != nil && requirement != nil && SecCodeCheckValidity(code!, [], requirement) == errSecSuccess
    }
    func startStream() throws {
        lock.lock(); defer { lock.unlock() }
        guard client != nil else { throw NSError(domain: "StreamCamera", code: 4) }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.joeblau.Stream.camera.sink"))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.consume() }
        self.timer = timer; timer.resume()
    }
    func stopStream() throws { stop() }
    func disconnect(clientID: UUID) {
        lock.lock(); defer { lock.unlock() }
        if client?.clientID == clientID { stop() }
    }
    private func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil; generation += 1; client = nil; consuming = false; mailbox.clear()
    }
    deinit { timer?.cancel() }
    private func consume() {
        lock.lock(); defer { lock.unlock() }
        guard !consuming, let client, timer != nil else { return }
        consuming = true; let generation = generation
        stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.generation == generation else { return }
            self.consuming = false
            if let sample { self.mailbox.submit(sample, sequence: sequence) }
            self.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: VirtualCameraContract.hostNanoseconds))
        }
    }
}
