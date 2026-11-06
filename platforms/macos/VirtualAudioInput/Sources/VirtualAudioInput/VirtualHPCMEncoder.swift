import Foundation

/// Immutable description of one device-tap PCM block to be framed as HPCM v2.
///
/// This type deliberately carries the raw `CapturedPCMBlock` and the small
/// amount of source clock context that belongs to a block. It has no
/// dependency on any resampler or capture layer type.
public struct VirtualHPCMSource: Sendable {
    public let block: CapturedPCMBlock
    public let frameStart: UInt64
    public let timebaseNumerator: UInt32
    public let timebaseDenominator: UInt32

    public init(block: CapturedPCMBlock,
                frameStart: UInt64,
                timebaseNumerator: UInt32,
                timebaseDenominator: UInt32) {
        self.block = block
        self.frameStart = frameStart
        self.timebaseNumerator = timebaseNumerator
        self.timebaseDenominator = timebaseDenominator
    }

    public var channels: Int { block.channels }
    public var frames: Int { block.frames }
    public var samples: [Float] { block.samples }
}

public enum VirtualHPCMEncoderError: Error, Equatable, CustomStringConvertible {
    case invalidSession
    case invalidStartID
    case invalidDeviceUID
    case invalidLayout
    case unsupportedSourceRate
    case invalidPrimeFrames
    case invalidFrameCount
    case blockFrameMismatch
    case channelMismatch
    case sampleCountMismatch
    case payloadSizeMismatch
    case payloadDataMismatch
    case pcmOutOfRange
    case droppedBlocks
    case invalidTimebase
    case invalidSampleTime
    case invalidCaptureFlags
    case counterOverflow
    case sourceSequenceRegressed
    case metadataMismatch
    case sourceOverlapOrRegress
    case inputTotalRegressed
    case headerTooLarge

    public var description: String {
        switch self {
        case .invalidSession: "invalid_session"
        case .invalidStartID: "invalid_start_id"
        case .invalidDeviceUID: "invalid_device_uid"
        case .invalidLayout: "invalid_layout"
        case .unsupportedSourceRate: "unsupported_source_rate"
        case .invalidPrimeFrames: "invalid_prime_frames"
        case .invalidFrameCount: "invalid_frame_count"
        case .blockFrameMismatch: "block_frame_mismatch"
        case .channelMismatch: "channel_mismatch"
        case .sampleCountMismatch: "sample_count_mismatch"
        case .payloadSizeMismatch: "payload_size_mismatch"
        case .payloadDataMismatch: "payload_data_mismatch"
        case .pcmOutOfRange: "pcm_out_of_range"
        case .droppedBlocks: "dropped_blocks"
        case .invalidTimebase: "invalid_timebase"
        case .invalidSampleTime: "invalid_sample_time"
        case .invalidCaptureFlags: "invalid_capture_flags"
        case .counterOverflow: "counter_overflow"
        case .sourceSequenceRegressed: "source_sequence_regressed"
        case .metadataMismatch: "metadata_mismatch"
        case .sourceOverlapOrRegress: "source_overlap_or_regress"
        case .inputTotalRegressed: "input_total_regressed"
        case .headerTooLarge: "header_too_large"
        }
    }
}

/// Serial, non-real-time HPCM v2 identity producer.
///
/// This type only frames already-captured Float32 device-container PCM into
/// HPCM v2 wire frames. It makes no source-native claim: observations are
/// device-container PCM, not original decoder layout. No capture, playback,
/// network or system changes happen here. The encoder is intentionally serial
/// and non-real-time; callers must serialise access to a single instance.
public final class VirtualHPCMEncoder: @unchecked Sendable {
    public static let maxFrames = 4096
    public static let maxPrimeFrames = 4096
    public static let maxHeaderBytes = 16_384

    private static let layoutOrder: [String: [String]] = [
        "mono": ["M"],
        "stereo": ["FL", "FR"],
        "3_0": ["FL", "FR", "FC"],
        "4_0": ["FL", "FR", "BL", "BR"],
        "5_1_side": ["FL", "FR", "FC", "LFE", "SL", "SR"],
        "5_1_back": ["FL", "FR", "FC", "LFE", "BL", "BR"],
        "7_1": ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"],
    ]

    private static let canonicalDeviceUID: [String: String] = [
        "mono": "com.homepodflow.virtual-audio.mono.v1",
        "stereo": "com.homepodflow.virtual-audio.stereo.v1",
        "3_0": "com.homepodflow.virtual-audio.surround30.v1",
        "4_0": "com.homepodflow.virtual-audio.quad40.v1",
        "5_1_side": "com.homepodflow.virtual-audio.surround51s.v1",
        "5_1_back": "com.homepodflow.virtual-audio.surround51b.v1",
        "7_1": "com.homepodflow.virtual-audio.surround71.v1",
    ]

    private let lock = NSLock()
    private let session: String
    private let startID: String
    private let deviceUID: String
    private let layout: String
    private let order: [String]
    private let channels: Int
    private let sourceRate: Double
    private let leadingFrames: Int
    private let trailingFrames: Int

    private var frameSequence = 0
    private var outputFrameStart: UInt64 = 0
    private var lastInputTotal: UInt64?
    private var lastSourceSequence: UInt64?
    private var lastSourceJSON: Data?
    private var lastSourceFrameStart: UInt64 = 0
    private var lastSourceFrames: Int = 0
    private var lastHostTime: UInt64 = 0
    private var acceptedTimebase: (UInt32, UInt32)?

    /// Insert-only initialiser: validates configuration and stores it. It opens
    /// no device, allocates no audio resources and performs no capture work.
    public init(session: String,
                startID: String,
                deviceUID: String,
                layout: String,
                sourceRate: Double,
                leadingFrames: Int = 0,
                trailingFrames: Int = 0) throws {
        let normalizedSession = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSession.utf8.count <= 64,
              let parsedSession = UUID(uuidString: normalizedSession),
              normalizedSession.lowercased() == parsedSession.uuidString.lowercased() else {
            throw VirtualHPCMEncoderError.invalidSession
        }
        let trimmedStartID = startID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStartID.isEmpty, trimmedStartID.utf8.count <= 512 else {
            throw VirtualHPCMEncoderError.invalidStartID
        }
        let trimmedDeviceUID = deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeviceUID.isEmpty, trimmedDeviceUID.utf8.count <= 512 else {
            throw VirtualHPCMEncoderError.invalidDeviceUID
        }
        guard let order = Self.layoutOrder[layout] else {
            throw VirtualHPCMEncoderError.invalidLayout
        }
        guard Self.canonicalDeviceUID[layout] == trimmedDeviceUID else {
            throw VirtualHPCMEncoderError.invalidDeviceUID
        }
        guard sourceRate.isFinite, sourceRate == 44_100 || sourceRate == 48_000 else {
            throw VirtualHPCMEncoderError.unsupportedSourceRate
        }
        guard (0...Self.maxPrimeFrames).contains(leadingFrames),
              (0...Self.maxPrimeFrames).contains(trailingFrames) else {
            throw VirtualHPCMEncoderError.invalidPrimeFrames
        }
        self.session = normalizedSession
        self.startID = trimmedStartID
        self.deviceUID = trimmedDeviceUID
        self.layout = layout
        self.order = order
        self.channels = order.count
        self.sourceRate = sourceRate
        self.leadingFrames = leadingFrames
        self.trailingFrames = trailingFrames
    }

    /// Frames one HPCM v2 packet. State advances only when the frame is fully
    /// validated and encoded; any thrown error leaves all continuity state
    /// unchanged.
    public func encodePCM(frames: Int,
                          payload: Data,
                          source: VirtualHPCMSource) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard (1...Self.maxFrames).contains(frames) else {
            throw VirtualHPCMEncoderError.invalidFrameCount
        }
        let inputFrames = source.block.frames
        guard (1...Self.maxFrames).contains(inputFrames) else {
            throw VirtualHPCMEncoderError.invalidFrameCount
        }
        guard source.block.channels == channels else {
            throw VirtualHPCMEncoderError.channelMismatch
        }
        let inputSampleCount = inputFrames * channels
        guard source.block.samples.count == inputSampleCount else {
            throw VirtualHPCMEncoderError.sampleCountMismatch
        }
        for sampleValue in source.block.samples where !sampleValue.isFinite {
            throw VirtualHPCMEncoderError.pcmOutOfRange
        }
        let outputSampleCount = frames * channels
        guard payload.count == outputSampleCount * MemoryLayout<Float>.size else {
            throw VirtualHPCMEncoderError.payloadSizeMismatch
        }
        guard Self.validatePayload(payload, count: outputSampleCount) else {
            throw VirtualHPCMEncoderError.pcmOutOfRange
        }
        guard source.timebaseNumerator > 0, source.timebaseDenominator > 0 else {
            throw VirtualHPCMEncoderError.invalidTimebase
        }
        guard source.block.droppedBefore == 0 else {
            throw VirtualHPCMEncoderError.droppedBlocks
        }
        guard source.block.sampleTime.isFinite, source.block.nowSampleTime.isFinite else {
            throw VirtualHPCMEncoderError.invalidSampleTime
        }
        guard source.block.timestampFlags & 3 == 3, source.block.nowFlags & 2 == 2 else {
            throw VirtualHPCMEncoderError.invalidCaptureFlags
        }

        try validateSourceContinuity(source)

        let inputTotal = try Self.checkedAdd(source.frameStart, UInt64(inputFrames))
        if let last = lastInputTotal, inputTotal < last {
            throw VirtualHPCMEncoderError.inputTotalRegressed
        }

        let sequence = frameSequence
        let outputStart = outputFrameStart
        let nextSequence = try Self.checkedAdd(sequence, 1)
        let nextOutputStart = try Self.checkedAdd(outputStart, UInt64(frames))
        let (headerData, headerLength, payloadLength) = try makeHeader(
            sequence: sequence,
            outputFrameStart: outputStart,
            frames: frames,
            inputTotal: inputTotal,
            source: source)
        guard headerLength >= 1,
              headerLength <= Self.maxHeaderBytes else {
            throw VirtualHPCMEncoderError.headerTooLarge
        }
        let snapshot = try sourceJSON(source)

        var framed = Data(capacity: 12 + headerData.count + payload.count)
        framed.append(contentsOf: Array("HPCM".utf8))
        appendUInt32LE(UInt32(headerLength), to: &framed)
        appendUInt32LE(UInt32(payloadLength), to: &framed)
        framed.append(headerData)
        framed.append(payload)

        // Commit continuity only now that every check and encoding succeeded.
        frameSequence = nextSequence
        outputFrameStart = nextOutputStart
        lastInputTotal = inputTotal
        lastSourceSequence = source.block.callbackSequence
        lastSourceJSON = snapshot
        lastSourceFrameStart = source.frameStart
        lastSourceFrames = inputFrames
        lastHostTime = source.block.hostTime
        acceptedTimebase = (source.timebaseNumerator, source.timebaseDenominator)

        return framed
    }

    private func validateSourceContinuity(_ source: VirtualHPCMSource) throws {
        let newSequence = source.block.callbackSequence
        guard let lastSequence = lastSourceSequence else { return }

        if newSequence < lastSequence {
            throw VirtualHPCMEncoderError.sourceSequenceRegressed
        }

        if newSequence == lastSequence {
            let currentJSON = try sourceJSON(source)
            guard currentJSON == lastSourceJSON else {
                throw VirtualHPCMEncoderError.metadataMismatch
            }
            return
        }

        // Newer source sequence: reject overlap or a regressing capture clock.
        let previousEnd = try Self.checkedAdd(lastSourceFrameStart, UInt64(lastSourceFrames))
        if source.frameStart < previousEnd || source.block.hostTime < lastHostTime {
            throw VirtualHPCMEncoderError.sourceOverlapOrRegress
        }
        if let timebase = acceptedTimebase,
           (source.timebaseNumerator, source.timebaseDenominator) != timebase {
            throw VirtualHPCMEncoderError.invalidTimebase
        }
    }

    private func makeHeader(sequence: Int,
                            outputFrameStart: UInt64,
                            frames: Int,
                            inputTotal: UInt64,
                            source: VirtualHPCMSource) throws -> (Data, Int, Int) {
        let sourceDict = sourceDictionary(source)
        let containerDict: [String: Any] = [
            "deviceUID": deviceUID,
            "streamIndex": 0,
            "channels": channels,
            "layout": layout,
            "channelOrder": order,
            "authority": "device",
            "verified": true,
        ]
        let header: [String: Any] = [
            "v": 2,
            "id": startID,
            "session": session,
            "kind": "pcm",
            "sequence": sequence,
            "outputRate": 44_100,
            "outputChannels": channels,
            "outputLayout": layout,
            "outputChannelOrder": order,
            "outputFrameStart": outputFrameStart,
            "outputFrames": frames,
            "container": containerDict,
            "source": sourceDict,
            "captureTransform": [
                "kind": "identity",
                "placed": [],
                "silentSlots": [],
                "transformations": ["identity"],
            ],
            "provenance": "source_upstream_mapped",
            "inputFramesConsumedTotal": inputTotal,
            "converterLeadingFrames": leadingFrames,
            "converterTrailingFrames": trailingFrames,
            "primeMethod": "none",
            "converterDelayKnown": false,
            "timestampRelation": "input_block_metadata",
        ]

        let data = try JSONSerialization.data(withJSONObject: header,
                                              options: [.sortedKeys])
        return (data, data.count, frames * channels * MemoryLayout<Float>.size)
    }

    private func sourceJSON(_ source: VirtualHPCMSource) throws -> Data {
        return try JSONSerialization.data(withJSONObject: sourceDictionary(source),
                                         options: [.sortedKeys])
    }

    private func sourceDictionary(_ source: VirtualHPCMSource) -> [String: Any] {
        [
            "sourceRate": sourceRate,
            "sourceChannels": channels,
            "sourceLayout": layout,
            "sourceChannelOrder": order,
            "sourceLayoutAuthority": "device",
            "sourceOrigin": "os_mix",
            "sourceLayoutVerified": false,
            "nativeClaim": false,
            "upstreamTransform": "os_mix_possible",
            "sourceFrameStart": source.frameStart,
            "sourceFrames": source.block.frames,
            "sourceSequence": source.block.callbackSequence,
            "hostTime": source.block.hostTime,
            "sampleTime": Self.finiteString(source.block.sampleTime),
            "flags": source.block.timestampFlags,
            "nowHostTime": source.block.nowHostTime,
            "nowSampleTime": Self.finiteString(source.block.nowSampleTime),
            "nowFlags": source.block.nowFlags,
            "timebaseNumerator": source.timebaseNumerator,
            "timebaseDenominator": source.timebaseDenominator,
            "droppedBlocksBefore": 0,
        ]
    }

    private static func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw VirtualHPCMEncoderError.counterOverflow }
        return value
    }

    private static func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw VirtualHPCMEncoderError.counterOverflow }
        return value
    }

    private static func finiteString(_ value: Double) -> String {
        String(value)
    }

    private static func packedLittleEndian(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            let bits = sample.bitPattern.littleEndian
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return data
    }

    private static func validatePayload(_ payload: Data, count: Int) -> Bool {
        guard payload.count == count * MemoryLayout<Float>.size else { return false }
        return payload.withUnsafeBytes { raw in
            for offset in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: offset * MemoryLayout<UInt32>.size,
                                             as: UInt32.self)
                let value = Float(bitPattern: UInt32(littleEndian: bits))
                if !value.isFinite || abs(value) > 1 { return false }
            }
            return true
        }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
