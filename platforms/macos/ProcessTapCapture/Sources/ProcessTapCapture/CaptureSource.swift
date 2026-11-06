import Foundation
import CaptureRing
import CoreAudio

@MainActor protocol CaptureBackend: AnyObject {
    func createTap(configuration: CaptureConfiguration) throws -> CaptureFormat
    func createAggregate() throws
    func installIO(ring: OpaquePointer) throws
    func startDevice() throws
    func stopDevice() throws
    func destroyIO() throws
    func destroyAggregate() throws
    func destroyTap() throws
    var callbackDetached: Bool { get }
    var exclusionReport: ProcessExclusionReport { get }
}
extension CaptureBackend {
    var exclusionReport: ProcessExclusionReport { .unavailable }
}

@MainActor public final class CaptureSource {
    public enum State: Equatable { case idle, running, failed(String), cleanupUnconfirmed }
    public private(set) var state: State = .idle
    public private(set) var format: CaptureFormat?
    public private(set) var sessionID: UUID?
    public var exclusionReport: ProcessExclusionReport { backend.exclusionReport }
    public var droppedBlocks: UInt64 { ring.map(capture_ring_dropped) ?? finalDropped }
    private let backend: any CaptureBackend
    private var ring: OpaquePointer?
    private var maximumBytes = 0
    private var finalDropped: UInt64 = 0
    private var timebase = CaptureTimebase.current()
    private struct Timing {
        let host: UInt64?
        let sample: Double?
        let frames: UInt32
        let drops: UInt64
    }
    private var previousTiming: Timing?

    public convenience init() { self.init(backend: HALCaptureBackend()) }
    init(backend: any CaptureBackend) { self.backend = backend }

    public func start(configuration: CaptureConfiguration) throws {
        guard state == .idle, ring == nil else { throw CaptureError.invalidState }
        try configuration.validate()
        do {
            let actualFormat = try backend.createTap(configuration: configuration)
            format = actualFormat
            guard let storage = capture_ring_create(UInt32(configuration.queueBlocks),
                UInt32(configuration.maximumFramesPerCallback), UInt32(actualFormat.bufferCount),
                UInt32(actualFormat.channelsPerBuffer), actualFormat.asbd.mBytesPerFrame) else {
                throw CaptureError.allocationFailed
            }
            ring = storage; finalDropped = 0
            maximumBytes = configuration.maximumFramesPerCallback * Int(actualFormat.asbd.mBytesPerFrame) * actualFormat.bufferCount
            try backend.createAggregate()
            try backend.installIO(ring: storage)
            try backend.startDevice()
            sessionID = UUID()
            previousTiming = nil
            timebase = .current()
            state = .running
        } catch {
            let original = error
            do { try stop() }
            catch { throw CaptureError.cleanupFailed([original.localizedDescription, error.localizedDescription]) }
            throw original
        }
    }

    /// Poll from a non-real-time consumer. Empty means temporarily no block,
    /// never EOF. The producer drops newest blocks when this bounded queue fills.
    public func readBlock() throws -> CapturedPCMBlock? {
        guard state == .running, let ring, let format, let sessionID else { throw CaptureError.invalidState }
        try validateHealth()
        var data = Data(count: maximumBytes)
        var metadata = CaptureRingMetadata()
        var lengths = [UInt32](repeating: 0, count: 32)
        var channels = [UInt32](repeating: 0, count: 32)
        let result = data.withUnsafeMutableBytes { bytes in
            capture_ring_pop(ring, bytes.baseAddress, bytes.count, &metadata, &lengths, &channels)
        }
        if result == 0 { return nil }
        guard result == 1 else { throw CaptureError.unsupportedFormat }
        let validHost = metadata.timestamp_flags & AudioTimeStampFlags.hostTimeValid.rawValue != 0
        let validSample = metadata.timestamp_flags & AudioTimeStampFlags.sampleTimeValid.rawValue != 0
            && metadata.sample_time.isFinite
        var timingFailure: String?
        if let previous = previousTiming {
            if validHost, let host = previous.host, metadata.host_time < host {
                timingFailure = "host ticks moved backwards"
            }
            if validSample, let sample = previous.sample {
                let expected = sample + Double(previous.frames)
                let difference = metadata.sample_time - expected
                // Explicit overflow gaps stay observable, not continuous audio.
                if difference < -0.5 || (metadata.dropped_before == previous.drops && abs(difference) > 0.5) {
                    timingFailure = "sampleTime expected \(expected), received \(metadata.sample_time)"
                }
            }
        }
        if let timingFailure {
            do { try stop() }
            catch { throw CaptureError.cleanupFailed([timingFailure, error.localizedDescription]) }
            state = .failed(timingFailure)
            throw CaptureError.timestampDiscontinuity(timingFailure)
        }
        previousTiming = .init(host: validHost ? metadata.host_time : nil,
            sample: validSample ? metadata.sample_time : nil, frames: metadata.frames, drops: metadata.dropped_before)
        var offset = 0
        var buffers: [Data] = []
        for length in lengths.prefix(Int(metadata.buffer_count)) {
            let count = Int(length)
            buffers.append(data.subdata(in: offset..<(offset + count)))
            offset += count
        }
        return CapturedPCMBlock(sessionID: sessionID, format: format, frames: Int(metadata.frames), buffers: buffers,
            bufferChannels: Array(channels.prefix(Int(metadata.buffer_count))),
            hostTime: metadata.host_time, sampleTime: metadata.sample_time, timestampFlags: metadata.timestamp_flags,
            callbackSequence: metadata.callback_sequence, droppedBlocksBefore: metadata.dropped_before,
            nowTimestamp: .init(hostTime: metadata.now_host_time, sampleTime: metadata.now_sample_time,
                                flags: metadata.now_timestamp_flags), timebase: timebase)
    }

    /// Non-RT recheck used after asynchronous conversion and before IPC enqueue.
    public func validateHealth() throws {
        guard state == .running, let ring else { throw CaptureError.invalidState }
        let fault = capture_ring_fault(ring)
        guard fault == 0 else {
            do { try stop() }
            catch { throw CaptureError.cleanupFailed(["callback fault \(fault)", error.localizedDescription]) }
            state = .failed("callback fault \(fault)")
            throw CaptureError.callbackFault(fault)
        }
    }

    /// Reverse order cleanup, retaining callback storage if detachment failed.
    /// Callers must explicitly stop even after a read failure. No automatic retry.
    public func stop() throws {
        var errors: [String] = []
        for operation in [backend.stopDevice, backend.destroyIO, backend.destroyAggregate, backend.destroyTap] {
            do { try operation() } catch { errors.append(error.localizedDescription) }
        }
        if backend.callbackDetached, let storage = ring {
            finalDropped = capture_ring_dropped(storage)
            capture_ring_destroy(storage)
            ring = nil
        }
        if !errors.isEmpty || !backend.callbackDetached {
            state = .cleanupUnconfirmed
            throw CaptureError.cleanupFailed(errors.isEmpty ? ["IOProc still attached; storage intentionally retained"] : errors)
        }
        state = .idle; format = nil; sessionID = nil; previousTiming = nil
    }

    /// Preferred ownership scope: cleanup runs on success, failure and task
    /// cancellation. Do not abandon an active instance or rely on deinit.
    public func withCapture<T>(configuration: CaptureConfiguration,
        operation: @MainActor (CaptureSource) async throws -> T) async throws -> T {
        try start(configuration: configuration)
        let result: Result<T, any Error>
        do { result = .success(try await operation(self)) }
        catch { result = .failure(error) }
        do { try stop() }
        catch {
            if case .failure(let original) = result {
                throw CaptureError.cleanupFailed([original.localizedDescription, error.localizedDescription])
            }
            throw error
        }
        return try result.get()
    }
}
