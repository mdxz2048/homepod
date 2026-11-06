import Foundation
import CoreAudio
import Darwin

public struct CaptureConfiguration: Sendable {
    public enum Selection: Sendable {
        case processes([Int32])
        case allExceptCurrentProcess
    }
    public let selection: Selection
    public let queueBlocks: Int
    public let maximumFramesPerCallback: Int
    public let excludedProcessIDs: [Int32]
    public init(selection: Selection = .allExceptCurrentProcess,
                queueBlocks: Int = 16, maximumFramesPerCallback: Int = 4096,
                excludedProcessIDs: [Int32] = []) {
        self.selection = selection
        self.queueBlocks = queueBlocks
        self.maximumFramesPerCallback = maximumFramesPerCallback
        self.excludedProcessIDs = excludedProcessIDs
    }
    func validate() throws {
        guard (2...256).contains(queueBlocks), queueBlocks & (queueBlocks - 1) == 0,
              (1...16384).contains(maximumFramesPerCallback) else {
            throw CaptureError.invalidConfiguration("Queue must be a power of two (2...256); callback frames 1...16384")
        }
        guard excludedProcessIDs.count <= 64, excludedProcessIDs.allSatisfy({ $0 > 0 }) else {
            throw CaptureError.invalidConfiguration("Exclusions must contain at most 64 positive PIDs")
        }
        if case .processes(let pids) = selection {
            guard !pids.isEmpty, pids.count <= 64, pids.allSatisfy({ $0 > 0 }), Set(pids).count == pids.count else {
                throw CaptureError.invalidConfiguration("Choose 1...64 distinct positive process IDs")
            }
            let exclusions = Set(excludedProcessIDs + [ProcessInfo.processInfo.processIdentifier])
            guard pids.allSatisfy({ !exclusions.contains($0) }) else {
                throw CaptureError.invalidConfiguration("A selected process is the capture host or an explicitly excluded sender")
            }
        }
    }
}

public enum CaptureError: LocalizedError {
    case invalidConfiguration(String), invalidState, osStatus(String, Int32)
    case unsupportedFormat, callbackFault(UInt32), cleanupFailed([String])
    case missingProcess(Int32), allocationFailed
    case timestampDiscontinuity(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidState: "Capture is active or previous cleanup remains unconfirmed"
        case .osStatus(let operation, let status): "\(operation) failed (OSStatus \(status)); check capture permission, process and device availability"
        case .unsupportedFormat: "Missing or unsupported PCM stream format; capture was not verified"
        case .callbackFault(let code): "Capture callback/format/device changed (\(code)); stop and rebuild explicitly"
        case .cleanupFailed(let errors): "Cleanup unconfirmed: " + errors.joined(separator: "; ")
        case .missingProcess(let pid): "No Core Audio process object for PID \(pid); no broader capture fallback was used"
        case .allocationFailed: "Unable to allocate bounded lock-free capture storage"
        case .timestampDiscontinuity(let message): "Capture timestamp discontinuity: \(message)"
        }
    }
}

public struct CaptureFormat: @unchecked Sendable {
    public let asbd: AudioStreamBasicDescription
    public var sampleRate: Double { asbd.mSampleRate }
    public var channels: Int { Int(asbd.mChannelsPerFrame) }
    public var isNonInterleaved: Bool { asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 }
    public var bufferCount: Int { isNonInterleaved ? channels : 1 }
    public var channelsPerBuffer: Int { isNonInterleaved ? 1 : channels }
    public init(asbd: AudioStreamBasicDescription) throws {
        let float32 = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        let allowedFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved
        let channels = Int(asbd.mChannelsPerFrame)
        let perBuffer = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : channels
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              (1...32).contains(channels), float32,
              asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              asbd.mFormatFlags & ~allowedFlags == 0,
              asbd.mFramesPerPacket == 1,
              Int(asbd.mBytesPerFrame) == perBuffer * Int(asbd.mBitsPerChannel / 8),
              asbd.mBytesPerPacket == asbd.mBytesPerFrame else { throw CaptureError.unsupportedFormat }
        self.asbd = asbd
    }
}

public struct CapturedPCMBlock: @unchecked Sendable {
    public let sessionID: UUID
    public let format: CaptureFormat
    public let frames: Int
    public let buffers: [Data]
    public let bufferChannels: [UInt32]
    public let hostTime: UInt64
    public let sampleTime: Double
    public let timestampFlags: UInt32
    public let callbackSequence: UInt64
    public let droppedBlocksBefore: UInt64
    public let nowTimestamp: CaptureTimestamp
    public let timebase: CaptureTimebase
    public var hostTimeIsValid: Bool { timestampFlags & AudioTimeStampFlags.hostTimeValid.rawValue != 0 }
    public var sampleTimeIsValid: Bool { timestampFlags & AudioTimeStampFlags.sampleTimeValid.rawValue != 0 && sampleTime.isFinite }

    /// Allocates and converts on the consumer side, never inside the IOProc.
    public func interleavedFloat32() throws -> [Float] {
        let channels = format.channels
        let sampleBytes = Int(format.asbd.mBitsPerChannel / 8)
        let bigEndian = format.asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        guard buffers.count == format.bufferCount,
              buffers.allSatisfy({ $0.count == frames * Int(format.asbd.mBytesPerFrame) }) else {
            throw CaptureError.unsupportedFormat
        }
        var result = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let buffer = buffers[format.isNonInterleaved ? channel : 0]
            buffer.withUnsafeBytes { raw in
                for frame in 0..<frames {
                    let index = format.isNonInterleaved ? frame : frame * channels + channel
                    let offset = index * sampleBytes
                    let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    let value = Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
                    result[frame * channels + channel] = value
                }
            }
        }
        guard result.allSatisfy(\.isFinite) else { throw CaptureError.unsupportedFormat }
        return result
    }
}

public struct CaptureTimestamp: Sendable {
    public let hostTime: UInt64
    public let sampleTime: Double
    public let flags: UInt32
    public var hostTimeIsValid: Bool { flags & AudioTimeStampFlags.hostTimeValid.rawValue != 0 }
    public var sampleTimeIsValid: Bool { flags & AudioTimeStampFlags.sampleTimeValid.rawValue != 0 && sampleTime.isFinite }
}
public struct CaptureTimebase: Sendable {
    public let numerator: UInt32
    public let denominator: UInt32
    public static func current() -> Self {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return .init(numerator: info.numer, denominator: info.denom)
    }
    /// Host ticks only. This does not convert to a Python/Core/Unix epoch.
    public func nanoseconds(forHostTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(numerator) / Double(denominator)
    }
}
