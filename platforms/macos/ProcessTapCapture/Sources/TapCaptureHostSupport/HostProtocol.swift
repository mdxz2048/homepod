import Foundation
import ProcessTapCapture

public enum HostFailure: LocalizedError, Sendable {
    case invalid(String), converter(String), output(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let value), .converter(let value), .output(let value): value
        }
    }
}

public struct HostSourceMetadata: Encodable, Sendable {
    public let captureSession: String
    public let sourceRate: Double
    public let sourceChannels: Int
    public let sourceFrameStart: UInt64
    public let sourceFrames: Int
    public let sourceSequence: UInt64
    public let hostTime: UInt64
    public let sampleTime: String
    public let flags: UInt32
    public let nowHostTime: UInt64
    public let nowSampleTime: String
    public let nowFlags: UInt32
    public let timebaseNumerator: UInt32
    public let timebaseDenominator: UInt32
    public let droppedBlocksBefore: UInt64
    public init(block: CapturedPCMBlock, frameStart: UInt64) {
        captureSession = block.sessionID.uuidString; sourceRate = block.format.sampleRate
        sourceChannels = block.format.channels; sourceFrameStart = frameStart; sourceFrames = block.frames
        sourceSequence = block.callbackSequence; hostTime = block.hostTime
        sampleTime = String(block.sampleTime); flags = block.timestampFlags
        nowHostTime = block.nowTimestamp.hostTime; nowSampleTime = String(block.nowTimestamp.sampleTime)
        nowFlags = block.nowTimestamp.flags; timebaseNumerator = block.timebase.numerator
        timebaseDenominator = block.timebase.denominator; droppedBlocksBefore = block.droppedBlocksBefore
    }
}

public struct HostHeader: Encodable, Sendable {
    public var id: String?
    public var session: String?
    public var kind: String
    public var sequence: UInt64?
    public var outputFrameStart: UInt64?
    public var outputFrames: Int?
    public var outputRate = 44100
    public var outputChannels = 2
    public var source: HostSourceMetadata?
    public var sourceRate: Double?
    public var sourceChannels: Int?
    public var sourceFormat: HostFormat?
    public var exclusionPolicy: ProcessExclusionReport?
    public var inputFramesConsumedTotal: UInt64?
    public var converterLeadingFrames: UInt32?
    public var converterTrailingFrames: UInt32?
    public var primeMethod = "none"
    public var timestampRelation = "input_block_metadata"
    public var clippedSamplesTotal: UInt64?
    public var converterDelayKnown = false
    public var cleanupComplete: Bool?
    public var discardedConverterTail: Bool?
    public var drainComplete: Bool?
    public var code: String?
    public var message: String?
    public init(id: String?, session: String?, kind: String) { self.id = id; self.session = session; self.kind = kind }
    enum CodingKeys: String, CodingKey {
        case v, id, session, kind, sequence, outputFrameStart, outputFrames, outputRate, outputChannels
        case source, sourceRate, sourceChannels, sourceFormat, exclusionPolicy, inputFramesConsumedTotal, converterLeadingFrames, converterTrailingFrames
        case primeMethod, timestampRelation, clippedSamplesTotal, converterDelayKnown, cleanupComplete, discardedConverterTail, drainComplete, code, message
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v); try c.encode(id, forKey: .id); try c.encode(session, forKey: .session)
        try c.encode(kind, forKey: .kind); try c.encode(outputRate, forKey: .outputRate)
        try c.encode(outputChannels, forKey: .outputChannels)
        try c.encodeIfPresent(sequence, forKey: .sequence); try c.encodeIfPresent(outputFrameStart, forKey: .outputFrameStart)
        try c.encodeIfPresent(outputFrames, forKey: .outputFrames); try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sourceRate, forKey: .sourceRate); try c.encodeIfPresent(sourceChannels, forKey: .sourceChannels)
        try c.encodeIfPresent(sourceFormat, forKey: .sourceFormat)
        try c.encodeIfPresent(exclusionPolicy, forKey: .exclusionPolicy)
        try c.encodeIfPresent(inputFramesConsumedTotal, forKey: .inputFramesConsumedTotal)
        try c.encodeIfPresent(converterLeadingFrames, forKey: .converterLeadingFrames)
        try c.encodeIfPresent(converterTrailingFrames, forKey: .converterTrailingFrames)
        try c.encode(primeMethod, forKey: .primeMethod); try c.encode(converterDelayKnown, forKey: .converterDelayKnown)
        try c.encode(timestampRelation, forKey: .timestampRelation)
        try c.encodeIfPresent(clippedSamplesTotal, forKey: .clippedSamplesTotal)
        try c.encodeIfPresent(cleanupComplete, forKey: .cleanupComplete)
        try c.encodeIfPresent(discardedConverterTail, forKey: .discardedConverterTail)
        try c.encodeIfPresent(drainComplete, forKey: .drainComplete)
        try c.encodeIfPresent(code, forKey: .code); try c.encodeIfPresent(message, forKey: .message)
    }
}

public struct HostFormat: Encodable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let formatID: UInt32
    public let flags: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let interleaved: Bool
    public init(_ value: CaptureFormat) {
        sampleRate = value.sampleRate; channels = value.channels; formatID = value.asbd.mFormatID
        flags = value.asbd.mFormatFlags; bitsPerChannel = value.asbd.mBitsPerChannel
        bytesPerFrame = value.asbd.mBytesPerFrame; interleaved = !value.isNonInterleaved
    }
}

public enum HPCMCodec {
    public static func encode(header: HostHeader, payload: Data = Data()) throws -> Data {
        let json = try JSONEncoder().encode(header)
        guard !json.isEmpty, json.count <= 16384, payload.count <= 65536 else { throw HostFailure.invalid("HPCM record exceeds bounds") }
        if header.kind == "pcm" {
            guard let frames = header.outputFrames, (1...4096).contains(frames), payload.count == frames * 8 else {
                throw HostFailure.invalid("Invalid stereo Float32 payload length")
            }
        } else if !payload.isEmpty { throw HostFailure.invalid("Control record contains PCM payload") }
        var data = Data("HPCM".utf8)
        for value in [UInt32(json.count), UInt32(payload.count)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(json); data.append(payload)
        return data
    }
}
