import Foundation
import CoreFoundation
import ProcessTapCapture

@MainActor public protocol HostCaptureProvider: AnyObject {
    var format: CaptureFormat? { get }
    var sessionID: UUID? { get }
    var droppedBlocks: UInt64 { get }
    var cleanupComplete: Bool { get }
    var exclusionReport: ProcessExclusionReport { get }
    func start(configuration: CaptureConfiguration) throws
    func readBlock() throws -> CapturedPCMBlock?
    func stop() throws
    func validateHealth() throws
}
extension HostCaptureProvider {
    public var exclusionReport: ProcessExclusionReport { .unavailable }
    public func validateHealth() throws { }
}
extension CaptureSource: HostCaptureProvider {
    public var cleanupComplete: Bool { state == .idle }
}

@MainActor public final class CaptureHostController {
    private let writer: BoundedPipeWriter
    private let factory: @MainActor () -> any HostCaptureProvider
    private var task: Task<Void, Never>?
    private var activeSession: String?
    private var activeID: String?
    private var stopID: String?
    private var lastSession: String?
    private var lastClean = true
    private var seenIDs = Set<String>()
    public private(set) var shouldExit = false
    public private(set) var exitCode: Int32 = 0
    public init(writer: BoundedPipeWriter,
                factory: @escaping @MainActor () -> any HostCaptureProvider = { CaptureSource() }) {
        self.writer = writer; self.factory = factory
    }
    public func command(_ line: Data) async {
        var id: String?, session: String?
        do {
            guard line.count <= 65536, let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  Set(object.keys) == Set(["v", "id", "command", "params"]),
                  let version = object["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let requestID = object["id"] as? String, !requestID.isEmpty, requestID.count <= 128,
                  let command = object["command"] as? String, let params = object["params"] as? [String: Any],
                  let requestSession = params["session"] as? String, UUID(uuidString: requestSession) != nil else {
                throw HostFailure.invalid("Invalid host command/session")
            }
            id = requestID; session = requestSession
            guard seenIDs.count < 4096, seenIDs.insert(requestID).inserted else { throw HostFailure.invalid("Duplicate request id or command budget exceeded") }
            if command == "start" {
                guard Set(params.keys) == Set(["session", "excludedProcessIDs"]), task == nil,
                      let values = params["excludedProcessIDs"] as? [NSNumber], !values.isEmpty, values.count <= 64,
                      values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.int32Value) && $0.int32Value > 0 }) else {
                    throw HostFailure.invalid("Start requires idle host and explicit sender/App exclusions")
                }
                activeSession = requestSession; activeID = requestID; stopID = nil
                task = Task { @MainActor [self] in
                    await capture(id: requestID, session: requestSession, exclusions: values.map(\.int32Value))
                }
            } else if command == "stop" {
                guard Set(params.keys) == Set(["session"]) else { throw HostFailure.invalid("Unknown stop parameters") }
                if let task {
                    guard activeSession == requestSession else { throw HostFailure.invalid("Stale stop session") }
                    stopID = requestID; task.cancel(); await task.value
                } else {
                    guard lastSession == requestSession else { throw HostFailure.invalid("Unknown stopped session") }
                    var header = HostHeader(id: requestID, session: requestSession, kind: "stopped")
                    header.cleanupComplete = lastClean; header.drainComplete = false; header.discardedConverterTail = false
                    try emit(header)
                }
            } else { throw HostFailure.invalid("Unknown host command") }
        } catch { emitError(id: id, session: session, code: "invalid_request", message: error.localizedDescription, clean: task == nil && lastClean) }
    }
    public func endInput() async {
        if let task { stopID = nil; task.cancel(); await task.value }
        shouldExit = true
        if !(await writer.flush()) { exitCode = 3 }
    }
    public func inputFailed(_ message: String) async {
        emitError(id: nil, session: activeSession, code: "invalid_request", message: message, clean: task == nil && lastClean)
        exitCode = 3
        await endInput()
    }
    private func capture(id: String, session: String, exclusions: [Int32]) async {
        let provider = factory()
        var failure: String?
        var usedConverter = false
        var sourceFrames: UInt64 = 0, outputFrames: UInt64 = 0, sequence: UInt64 = 0, clipped: UInt64 = 0
        var previousSourceSequence: UInt64?
        do {
            try Task.checkCancellation()
            try provider.start(configuration: .init(excludedProcessIDs: exclusions))
            guard let format = provider.format, format.channels == 2 else { throw HostFailure.invalid("Host requires actual stereo source") }
            let converter = try FloatResampler(sourceRate: format.sampleRate, channels: format.channels)
            var ready = HostHeader(id: id, session: session, kind: "ready")
            ready.sourceFormat = HostFormat(format); ready.sourceRate = format.sampleRate; ready.sourceChannels = format.channels
            ready.exclusionPolicy = provider.exclusionReport
            ready.converterLeadingFrames = converter.leadingFrames; ready.converterTrailingFrames = converter.trailingFrames
            try emit(ready)
            while true {
                try Task.checkCancellation()
                if let error = writer.failure { throw HostFailure.output(error) }
                guard let block = try provider.readBlock() else { try await Task.sleep(for: .milliseconds(2)); continue }
                guard block.droppedBlocksBefore == 0, provider.droppedBlocks == 0,
                      previousSourceSequence.map({ block.callbackSequence == $0 + 1 }) ?? true,
                      block.hostTimeIsValid, block.sampleTimeIsValid, block.nowTimestamp.hostTimeIsValid else {
                    throw HostFailure.invalid("Capture gap or invalid timestamps")
                }
                previousSourceSequence = block.callbackSequence
                let metadata = HostSourceMetadata(block: block, frameStart: sourceFrames)
                sourceFrames += UInt64(block.frames)
                try provider.validateHealth()
                let packets = try await converter.convert(block)
                usedConverter = true
                try Task.checkCancellation()
                try provider.validateHealth()
                for packet in packets {
                    try provider.validateHealth()
                    clipped += packet.clippedSamples
                    var header = HostHeader(id: id, session: session, kind: "pcm")
                    header.sequence = sequence; header.outputFrameStart = outputFrames; header.outputFrames = packet.frames
                    header.source = metadata; header.inputFramesConsumedTotal = sourceFrames
                    header.converterLeadingFrames = converter.leadingFrames; header.converterTrailingFrames = converter.trailingFrames
                    header.clippedSamplesTotal = clipped
                    try emit(header, payload: packet.bytes)
                    outputFrames += UInt64(packet.frames); sequence += 1
                }
            }
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
        do { try provider.stop() } catch { failure = [failure, error.localizedDescription].compactMap { $0 }.joined(separator: "; ") }
        lastClean = provider.cleanupComplete
        lastSession = session
        if let failure {
            emitError(id: id, session: session, code: "capture_failed", message: failure, clean: lastClean)
            exitCode = 3
        } else {
            var stopped = HostHeader(id: stopID, session: session, kind: "stopped")
            stopped.cleanupComplete = lastClean; stopped.drainComplete = false
            stopped.discardedConverterTail = usedConverter; stopped.outputFrameStart = outputFrames
            stopped.inputFramesConsumedTotal = sourceFrames; stopped.clippedSamplesTotal = clipped
            do { try emit(stopped) } catch { exitCode = 3 }
            if !lastClean { exitCode = 3 }
        }
        task = nil; activeSession = nil; activeID = nil; stopID = nil
        shouldExit = true // One-shot host: terminal record must be followed by exit.
    }
    private func emit(_ header: HostHeader, payload: Data = Data()) throws {
        try writer.enqueue(HPCMCodec.encode(header: header, payload: payload))
    }
    private func emitError(id: String?, session: String?, code: String, message: String, clean: Bool) {
        var header = HostHeader(id: id, session: session, kind: "error")
        header.code = code; header.message = String(message.prefix(1024)); header.cleanupComplete = clean
        do { try emit(header) } catch { exitCode = 3; shouldExit = true }
    }
}
