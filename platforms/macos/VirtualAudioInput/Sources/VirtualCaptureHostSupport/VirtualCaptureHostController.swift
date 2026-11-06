import Foundation
import CoreFoundation
import Darwin
import VirtualAudioInput
import TapCaptureHostSupport

/// Failures raised inside the capture task. Only the descriptive text reaches
/// the wire; the enum keeps it bounded and greppable in tests.
enum VirtualCaptureHostError: Error, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case descriptorMismatch(String)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case droppedBlocks
    case captureUnverified
    case counterOverflow
    case timebaseUnavailable
    case output(String)

    var description: String {
        switch self {
        case .invalidRequest(let message): message
        case .descriptorMismatch(let message): message
        case .sequenceGap(let expected, let actual): "callback sequence gap: expected \(expected), got \(actual)"
        case .droppedBlocks: "capture dropped blocks before a packet"
        case .captureUnverified: "capture_unverified"
        case .counterOverflow: "capture counter overflow"
        case .timebaseUnavailable: "mach_timebase_info unavailable"
        case .output(let message): message
        }
    }
}

/// Injectable device-tap transport. `DeviceTapCapture` already matches these
/// signatures; the protocol only exists so tests can run without the real HAL.
@MainActor
public protocol VirtualCaptureProvider: AnyObject {
    func start(deviceUID: String) throws -> DeviceTapDescriptor
    func readBlock() throws -> VirtualAudioInput.CapturedPCMBlock?
    func stop() throws
}

extension DeviceTapCapture: VirtualCaptureProvider { }

/// One-shot managed capture host (HPCM v2 over stdout / JSONL v2 over stdin).
///
/// No resources are acquired on init. A single session is permitted; after a
/// clean stop, failure or EOF the controller sets `shouldExit` and the entry
/// point flushes the writer and terminates the process.
@MainActor
public final class VirtualCaptureHostController {
    private static let canonicalDeviceUID: [String: String] = [
        "mono": "com.homepodflow.virtual-audio.mono.v1",
        "stereo": "com.homepodflow.virtual-audio.stereo.v1",
        "3_0": "com.homepodflow.virtual-audio.surround30.v1",
        "4_0": "com.homepodflow.virtual-audio.quad40.v1",
        "5_1_side": "com.homepodflow.virtual-audio.surround51s.v1",
        "5_1_back": "com.homepodflow.virtual-audio.surround51b.v1",
        "7_1": "com.homepodflow.virtual-audio.surround71.v1",
    ]

    private static let layoutChannels: [String: Int] = [
        "mono": 1,
        "stereo": 2,
        "3_0": 3,
        "4_0": 4,
        "5_1_side": 6,
        "5_1_back": 6,
        "7_1": 8,
    ]

    private let writer: BoundedPipeWriter
    private let factory: @MainActor () -> any VirtualCaptureProvider
    private var task: Task<Void, Never>?
    private var activeSession: String?
    private var activeID: String?
    private var stopID: String?
    private var seenIDs = Set<String>()
    private var inputFailedFlag = false

    public private(set) var shouldExit = false
    public private(set) var exitCode: Int32 = 0

    public init(writer: BoundedPipeWriter,
                factory: @escaping @MainActor () -> any VirtualCaptureProvider = { DeviceTapCapture() }) {
        self.writer = writer
        self.factory = factory
    }

    /// Parse and execute exactly one control command. Invalid commands emit a
    /// correlated error record and never touch an active capture session.
    public func command(_ line: Data) async {
        var requestID: String?
        var session: String?
        do {
            guard line.count <= 65_536 else {
                throw VirtualCaptureHostError.invalidRequest("command line exceeds 64 KiB")
            }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  Set(object.keys) == Set(["v", "id", "command", "params"]) else {
                throw VirtualCaptureHostError.invalidRequest("Invalid control record shape")
            }
            guard let version = object["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.intValue == 2,
                  version.doubleValue == 2 else {
                throw VirtualCaptureHostError.invalidRequest("Control version must be integer 2")
            }
            guard let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else {
                throw VirtualCaptureHostError.invalidRequest("Invalid request id")
            }
            guard let commandName = object["command"] as? String else {
                throw VirtualCaptureHostError.invalidRequest("Missing command")
            }
            guard let params = object["params"] as? [String: Any],
                  let sessionString = params["session"] as? String,
                  UUID(uuidString: sessionString) != nil else {
                throw VirtualCaptureHostError.invalidRequest("Invalid session")
            }
            requestID = id
            session = sessionString
            guard seenIDs.count < 128, seenIDs.insert(id).inserted else {
                throw VirtualCaptureHostError.invalidRequest("Duplicate request id or command budget exceeded")
            }

            switch commandName {
            case "start":
                try parseStart(id: id, session: sessionString, params: params)
            case "stop":
                try await parseStop(id: id, session: sessionString, params: params)
            default:
                throw VirtualCaptureHostError.invalidRequest("Unknown command")
            }
        } catch {
            emitError(id: requestID, session: session, code: "invalid_request",
                      message: bounded((error as? VirtualCaptureHostError)?.description ?? error.localizedDescription),
                      cleanupComplete: task == nil)
        }
    }

    private func parseStart(id: String, session: String, params: [String: Any]) throws {
        guard Set(params.keys) == Set(["session", "deviceUID", "layout"]),
              let deviceUID = params["deviceUID"] as? String,
              let layout = params["layout"] as? String else {
            throw VirtualCaptureHostError.invalidRequest("Start requires exactly session/deviceUID/layout")
        }
        guard Self.layoutChannels[layout] != nil else {
            throw VirtualCaptureHostError.invalidRequest("Unsupported layout")
        }
        guard Self.canonicalDeviceUID[layout] == deviceUID else {
            throw VirtualCaptureHostError.invalidRequest("deviceUID does not match layout")
        }
        guard task == nil, activeSession == nil else {
            throw VirtualCaptureHostError.invalidRequest("Start requires an idle host")
        }
        activeSession = session
        activeID = id
        stopID = nil
        task = Task { @MainActor [self] in
            await capture(id: id, session: session, deviceUID: deviceUID, layout: layout)
        }
    }

    private func parseStop(id: String, session: String, params: [String: Any]) async throws {
        guard Set(params.keys) == Set(["session"]) else {
            throw VirtualCaptureHostError.invalidRequest("Stop accepts exactly session")
        }
        guard let activeTask = task else {
            throw VirtualCaptureHostError.invalidRequest("No active session to stop")
        }
        guard activeSession == session else {
            // Correlated error; the different active session must keep running.
            throw VirtualCaptureHostError.invalidRequest("Stale stop session")
        }
        stopID = id
        activeTask.cancel()
        await activeTask.value
    }

    /// EOF on stdin. Cancels an active capture without a stop id, awaits full
    /// teardown, then requests exit. A clean EOF may exit 0.
    public func endInput() async {
        if let activeTask = task {
            stopID = nil
            activeTask.cancel()
            await activeTask.value
        }
        if inputFailedFlag { exitCode = 3 }
        shouldExit = true
    }

    /// Fatal stdin/protocol failure. Emits an `invalid_request` error first
    /// (id null), then tears down exactly like EOF. Exit stays non-zero.
    public func inputFailed(_ message: String) async {
        inputFailedFlag = true
        exitCode = 3
        emitError(id: nil, session: activeSession, code: "invalid_request",
                  message: bounded(message), cleanupComplete: task == nil)
        await endInput()
    }

    private func capture(id: String, session: String, deviceUID: String, layout: String) async {
        let provider = factory()
        var failure: String?
        var converterCreated = false
        do {
            try Task.checkCancellation()
            let descriptor = try provider.start(deviceUID: deviceUID)
            try Self.validate(descriptor, deviceUID: deviceUID, layout: layout)
            let resampler = try VirtualPCMResampler(sourceRate: descriptor.sampleRate,
                                                     channels: Int(descriptor.channels))
            let encoder = try VirtualHPCMEncoder(session: session,
                                                 startID: id,
                                                 deviceUID: deviceUID,
                                                 layout: layout,
                                                 sourceRate: descriptor.sampleRate,
                                                 leadingFrames: Int(resampler.leadingFrames),
                                                 trailingFrames: Int(resampler.trailingFrames))
            converterCreated = true
            let channels = Self.layoutChannels[layout] ?? Int(descriptor.channels)
            try emit(readyHeader(id: id, session: session, deviceUID: deviceUID, layout: layout,
                                 sourceRate: descriptor.sampleRate, sourceChannels: Int(descriptor.channels),
                                 channels: channels))

            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
                throw VirtualCaptureHostError.timebaseUnavailable
            }

            var previousSequence: UInt64?
            var inputTotal: UInt64 = 0
            let started = DispatchTime.now()
            var firstBlock = true

            while true {
                try Task.checkCancellation()
                if let error = writer.failure {
                    throw VirtualCaptureHostError.output(error)
                }
                guard let block = try provider.readBlock() else {
                    if firstBlock, DispatchTime.now() >= started + .seconds(5) {
                        // Zero-valued frames are legitimate; absence of any
                        // callback is the only thing treated as unverified.
                        throw VirtualCaptureHostError.captureUnverified
                    }
                    try await Task.sleep(for: .milliseconds(2))
                    continue
                }
                firstBlock = false
                guard block.droppedBefore == 0 else {
                    throw VirtualCaptureHostError.droppedBlocks
                }
                if let previous = previousSequence {
                    let (expected, overflow) = previous.addingReportingOverflow(1)
                    guard !overflow, block.callbackSequence == expected else {
                        throw VirtualCaptureHostError.sequenceGap(expected: previous + 1,
                                                                  actual: block.callbackSequence)
                    }
                }
                previousSequence = block.callbackSequence

                let frameStart = inputTotal
                let (nextTotal, overflow) = inputTotal.addingReportingOverflow(UInt64(block.frames))
                guard !overflow else { throw VirtualCaptureHostError.counterOverflow }
                inputTotal = nextTotal

                let source = VirtualHPCMSource(block: block,
                                               frameStart: frameStart,
                                               timebaseNumerator: timebase.numer,
                                               timebaseDenominator: timebase.denom)
                let packets = try resampler.convert(samples: block.samples, frames: block.frames)
                for packet in packets {
                    try Task.checkCancellation()
                    if let error = writer.failure {
                        throw VirtualCaptureHostError.output(error)
                    }
                    let framed = try encoder.encodePCM(frames: packet.frames,
                                                       payload: packet.bytes,
                                                       source: source)
                    try writer.enqueue(framed)
                }
            }
        } catch is CancellationError {
            // Cancellation is the normal stop/EOF path, not a failure.
        } catch {
            failure = bounded((error as? VirtualCaptureHostError)?.description ?? error.localizedDescription)
        }

        var stopSucceeded = true
        do {
            try provider.stop()
        } catch {
            stopSucceeded = false
            let stopText = bounded((error as? VirtualCaptureHostError)?.description ?? error.localizedDescription)
            failure = failure.map { $0 + "; " + stopText } ?? stopText
        }

        activeSession = nil
        activeID = nil

        if let failure {
            let header: [String: Any] = [
                "v": 2, "id": id, "session": session, "kind": "error",
                "code": "capture_failed", "message": bounded(failure),
                "cleanupComplete": stopSucceeded, "drainComplete": false,
                "discardedConverterTail": converterCreated,
            ]
            do { try emit(header) } catch { exitCode = 3 }
            exitCode = 3
        } else {
            let stoppedID = stopID ?? id
            let header: [String: Any] = [
                "v": 2, "id": stoppedID, "session": session, "kind": "stopped",
                "cleanupComplete": stopSucceeded, "drainComplete": false,
                "discardedConverterTail": converterCreated,
            ]
            do { try emit(header) } catch { exitCode = 3 }
            exitCode = stopSucceeded ? (inputFailedFlag ? 3 : 0) : 3
        }

        task = nil
        shouldExit = true
    }

    private func readyHeader(id: String, session: String, deviceUID: String, layout: String,
                             sourceRate: Double, sourceChannels: Int, channels: Int) -> [String: Any] {
        [
            "v": 2, "id": id, "session": session, "kind": "ready",
            "outputRate": 44_100, "outputChannels": channels, "outputLayout": layout,
            "deviceUID": deviceUID, "sourceRate": sourceRate, "sourceChannels": sourceChannels,
        ]
    }

    private static func validate(_ descriptor: DeviceTapDescriptor, deviceUID: String, layout: String) throws {
        guard descriptor.deviceUID == deviceUID else {
            throw VirtualCaptureHostError.descriptorMismatch("Descriptor deviceUID does not match request")
        }
        guard let expected = layoutChannels[layout] else {
            throw VirtualCaptureHostError.descriptorMismatch("Unsupported layout")
        }
        guard Int(descriptor.channels) == expected else {
            throw VirtualCaptureHostError.descriptorMismatch("Descriptor channel count does not match layout")
        }
        guard descriptor.sampleRate == 44_100 || descriptor.sampleRate == 48_000 else {
            throw VirtualCaptureHostError.descriptorMismatch("Unsupported descriptor sample rate")
        }
    }

    private func emit(_ header: [String: Any]) throws {
        try writer.enqueue(Self.control(header))
    }

    private func emitError(id: String?, session: String?, code: String, message: String, cleanupComplete: Bool) {
        var header: [String: Any] = [
            "v": 2, "kind": "error", "code": code,
            "message": bounded(message), "cleanupComplete": cleanupComplete,
        ]
        header["id"] = id ?? NSNull()
        header["session"] = session ?? NSNull()
        do { try emit(header) } catch { exitCode = 3; shouldExit = true }
    }

    /// Frames one non-PCM HPCM v2 control record. Adds `v=2` when missing and
    /// rejects oversized headers. The payload length is always zero.
    public static func control(_ header: [String: Any]) throws -> Data {
        var object = header
        if object["v"] == nil { object["v"] = 2 }
        let json = try JSONSerialization.data(withJSONObject: object, options: [])
        guard !json.isEmpty, json.count <= 16_384 else {
            throw VirtualCaptureHostError.invalidRequest("Control header exceeds 16384 bytes")
        }
        var framed = Data(capacity: 12 + json.count)
        framed.append(contentsOf: Array("HPCM".utf8))
        Self.appendUInt32LE(UInt32(json.count), to: &framed)
        Self.appendUInt32LE(0, to: &framed)
        framed.append(json)
        return framed
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func bounded(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return String(collapsed.prefix(1024))
    }
}
