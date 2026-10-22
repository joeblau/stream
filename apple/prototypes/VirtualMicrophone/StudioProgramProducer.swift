import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import StreamCore

// O07 evaluation source only, outside every application target. There is no
// shipping UI, demand, persistence, automatic device selection or activation.
enum StudioProgramProducerError: Error { case evaluationRequired, unavailable, busy, transport(OSStatus), invalidFormat }

final class StudioProgramRenderOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = StreamProgramRenderCreate() else { throw StudioProgramProducerError.unavailable }
        self.pointer = pointer
    }
    func retire() { StreamProgramRenderRetire(pointer) }
    deinit { StreamProgramRenderDestroy(pointer) }

    func receive(_ sample: CMSampleBuffer) {
        guard StreamProgramRenderSnapshot(pointer).active,
              CMSampleBufferDataIsReady(sample), (1...Int(STREAM_PROGRAM_MAX_CALLBACK)).contains(sample.numSamples),
              sample.presentationTimeStamp.isNumeric, sample.presentationTimeStamp >= .zero,
              let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate == 48_000, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags == kAudioFormatFlagsNativeFloatPacked,
              asbd.mChannelsPerFrame == 2, asbd.mBitsPerChannel == 32, asbd.mBytesPerFrame == 8,
              asbd.mFramesPerPacket == 1, asbd.mBytesPerPacket == 8,
              let pcm = CanonicalAudioConverter.makePCMBuffer(from: sample),
              let floats = CanonicalAudioConverter.interleavedFloats(pcm), floats.count == sample.numSamples * 2 else { return }
        // Preserve the mixer host-clock position. This rounds only to the
        // canonical sample grid; it never anchors media to callback arrival.
        let frame = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 48_000, method: .roundHalfAwayFromZero)
        guard frame.isNumeric else { return }
        floats.withUnsafeBufferPointer { buffer in
            _ = StreamProgramRenderSubmit(pointer, frame.value, UInt32(sample.numSamples), buffer.baseAddress)
        }
    }
}

/// Only the public HAL syscall boundary is replaced by the owned fixture.
/// Producer registration, listener/cleanup ownership and render code stay real.
protocol StudioProgramHALSyscalls: Sendable {
    func find() -> AudioDeviceID
    func preflight(_ device: AudioDeviceID) -> Bool
    func createIO(_ device: AudioDeviceID, render: StudioProgramRenderOwner) throws -> UUID
    func start(_ handle: UUID) throws
    func stop(_ handle: UUID) throws
    func destroy(_ handle: UUID) throws
    func watch(_ device: AudioDeviceID, address: AudioObjectPropertyAddress,
               changed: @escaping @Sendable () -> Void) throws -> UUID
    func removeWatch(_ token: UUID) throws
}

final class StudioProgramRealHAL: StudioProgramHALSyscalls, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.joeblau.Stream.evaluation-program-device")
    private var handles: [UUID: (AudioDeviceID, AudioDeviceIOProcID)] = [:]
    private var listeners: [UUID: (AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [:]
    private func checked(_ status: OSStatus) throws { if status != noErr { throw StudioProgramProducerError.transport(status) } }
    func find() -> AudioDeviceID { StreamProgramHALFindDevice() }
    func preflight(_ device: AudioDeviceID) -> Bool { StreamProgramHALPreflight(device) }
    func createIO(_ device: AudioDeviceID, render: StudioProgramRenderOwner) throws -> UUID {
        try lock.withLock {
            var io: AudioDeviceIOProcID?
            try checked(StreamProgramHALCreateIOProc(device, render.pointer, &io))
            guard let io else { throw StudioProgramProducerError.unavailable }
            let token = UUID(); handles[token] = (device, io); return token
        }
    }
    func start(_ handle: UUID) throws { try lock.withLock { guard let (device, io) = handles[handle] else { throw StudioProgramProducerError.unavailable }; try checked(AudioDeviceStart(device, io)) } }
    func stop(_ handle: UUID) throws { try lock.withLock { guard let (device, io) = handles[handle] else { throw StudioProgramProducerError.unavailable }; try checked(AudioDeviceStop(device, io)) } }
    func destroy(_ handle: UUID) throws {
        try lock.withLock {
            guard let (device, io) = handles[handle] else { throw StudioProgramProducerError.unavailable }
            try checked(AudioDeviceDestroyIOProcID(device, io)); handles[handle] = nil
        }
    }
    func watch(_ device: AudioDeviceID, address: AudioObjectPropertyAddress,
               changed: @escaping @Sendable () -> Void) throws -> UUID {
        try lock.withLock {
            var address = address
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            try checked(AudioObjectAddPropertyListenerBlock(device, &address, queue, block))
            let token = UUID(); listeners[token] = (device, address, block); return token
        }
    }
    func removeWatch(_ token: UUID) throws {
        try lock.withLock {
            guard let (device, stored, block) = listeners[token] else { return }
            var address = stored
            try checked(AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)); listeners[token] = nil
        }
    }
}

/// One real HAL evaluation session per process. If OS cleanup fails, retain its
/// context and refuse another session rather than free a live IOProc pointer or
/// grow a list of abandoned audio devices. Explicit stop may retry cleanup.
private final class StudioProgramHALRegistry: @unchecked Sendable {
    static let shared = StudioProgramHALRegistry()
    private let lock = NSLock()
    private var live: StudioProgramHALSession?
    func claim(_ create: () throws -> StudioProgramHALSession) throws -> StudioProgramHALSession {
        try lock.withLock {
            guard live == nil else { throw StudioProgramProducerError.busy }
            let value = try create(); live = value; return value
        }
    }
    func release(_ session: StudioProgramHALSession) { lock.withLock { if live === session { live = nil } } }
}

private final class StudioProgramHALSession: @unchecked Sendable {
    private let lock = NSLock()
    private let device: AudioDeviceID
    private let render: StudioProgramRenderOwner
    private let calls: any StudioProgramHALSyscalls
    private var io: UUID?
    private var started = false
    private var watched: [UUID] = []

    init(device: AudioDeviceID, render: StudioProgramRenderOwner, calls: any StudioProgramHALSyscalls,
         invalidated: @escaping @Sendable () -> Void) throws {
        self.device = device; self.render = render; self.calls = calls
        guard calls.preflight(device) else { throw StudioProgramProducerError.invalidFormat }
        io = try calls.createIO(device, render: render)
        // Watch device identity, life and rate. The prototype changes both
        // stream formats with its nominal rate; no property is ever written.
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)]
        for (selector, scope) in properties {
            let address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            do { watched.append(try calls.watch(device, address: address) { render.retire(); invalidated() }) }
            catch {
                // Keep the context alive if destroying the just-created IOProc
                // fails too; the registry must own that failed session.
                render.retire()
                break
            }
        }
    }
    func start() throws {
        try lock.withLock {
            guard let io, StreamProgramRenderSnapshot(render.pointer).active,
                  watched.count == 6, calls.preflight(device) else { throw StudioProgramProducerError.invalidFormat }
            try calls.start(io)
            started = true
        }
    }
    func close() throws {
        render.retire()
        try lock.withLock {
            if let io {
                if started { try calls.stop(io); started = false }
                try calls.destroy(io)
                self.io = nil
            }
            while let token = watched.first { try calls.removeWatch(token); watched.removeFirst() }
            StudioProgramHALRegistry.shared.release(self)
        }
    }
}

@MainActor final class StudioProgramProducer {
    enum State { case idle, preparing, running, failed }
    private(set) var state = State.idle
    private(set) var render: StudioProgramRenderOwner?
    private let mixer: AudioMixEngine
    private let calls: any StudioProgramHALSyscalls
    private var session: StudioProgramHALSession?
    private var tap: UUID?
    private var intent = UUID()
    private var starting = false
    private var stopping: Task<Void, Error>?

    init(mixer: AudioMixEngine, calls: any StudioProgramHALSyscalls = StudioProgramRealHAL()) {
        self.mixer = mixer; self.calls = calls
    }
    /// The caller owns mixer/capture demand. Starting this never starts a mic,
    /// mixer, publisher, recorder, OS approval, or any system default route.
    func start(acknowledgeUnqualifiedHALRoute: Bool) async throws {
        guard acknowledgeUnqualifiedHALRoute else { throw StudioProgramProducerError.evaluationRequired }
        guard session == nil, !starting, stopping == nil else { throw StudioProgramProducerError.busy }
        try Task.checkCancellation()
        starting = true; defer { starting = false }
        intent = UUID(); let generation = intent
        state = .preparing
        do {
            let device = calls.find()
            guard device != kAudioObjectUnknown else { throw StudioProgramProducerError.unavailable }
            let core = try StudioProgramRenderOwner(); render = core
            let connection = try StudioProgramHALRegistry.shared.claim {
                try StudioProgramHALSession(device: device, render: core, calls: calls) { [weak self] in
                    core.retire()
                    Task { @MainActor [weak self] in
                        guard let self, self.intent == generation else { return }
                        try? await self.stop()
                    }
                }
            }
            session = connection
            let token = UUID(); tap = token
            await mixer.addTap(bus: .program, token: token, capacity: 2) { core.receive($0) }
            guard intent == generation, !Task.isCancelled else { throw CancellationError() }
            try connection.start()
            try Task.checkCancellation()
            guard intent == generation, StreamProgramRenderSnapshot(core.pointer).active else { throw CancellationError() }
            state = .running
        } catch {
            if intent == generation { try? await stop(); state = .failed }
            throw error
        }
    }
    /// Retirement precedes actor hops: a queued old Program tap cannot refill
    /// the render mailbox while removal/IO destruction awaits completion.
    func stop() async throws {
        intent = UUID(); render?.retire()
        if let stopping { return try await stopping.value }
        let connection = session, token = tap
        let barrier = Task { @MainActor in
            defer { self.stopping = nil }
            if let token {
                await self.mixer.removeTap(token)
                if self.tap == token { self.tap = nil }
            }
            do {
                try connection?.close()
                if self.session === connection { self.session = nil; self.state = .idle }
            } catch {
                if self.session === connection { self.state = .failed }
                throw error
            }
        }
        stopping = barrier
        try await barrier.value
    }
    deinit {
        render?.retire()
        try? session?.close()
        if let tap { let mixer = mixer; Task { await mixer.removeTap(tap) } }
    }
}
