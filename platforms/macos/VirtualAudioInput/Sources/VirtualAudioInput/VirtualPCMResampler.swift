import Foundation
import AudioToolbox
@preconcurrency import AVFAudio

/// One packet of 44.1 kHz, interleaved Float32 little-endian PCM.
/// Payload is `frames * channels * 4` bytes: frame-major, channel-minor,
/// 4-byte aligned, no planar fan-out.
public struct VirtualConvertedPCM: Sendable {
    public let frames: Int
    public let bytes: Data
    public let clippedSamples: UInt64

    public init(frames: Int, bytes: Data, clippedSamples: UInt64) {
        self.frames = frames
        self.bytes = bytes
        self.clippedSamples = clippedSamples
    }
}

public enum VirtualPCMResamplerError: Error, Equatable, Sendable {
    case invalidSourceRate(Double)
    case unsupportedChannelCount(Int)
    case invalidFrameCount(Int)
    case samplesCountMismatch(expected: Int, actual: Int)
    case nonFiniteInput(index: Int)
    case converterUnavailable
    case outputAllocationFailed
    case converterFailed(String)
    case nonFiniteOutput
    case workBudgetExceeded
}

/// Streaming Float32 interleaved -> 44.1 kHz Float32 interleaved resampler for
/// native 1/2/3/4/6/8-channel streams. No process, device, or TCC APIs are
/// used. Input and output share the same channel count, with an explicit
/// identity channel map to prevent implicit remapping by AVFoundation.
///
/// The API is deliberately non-real-time; converter work and allocations are
/// bounded per call. `converter.primeMethod` is `.none` and the streaming
/// converter is retained across calls. End-of-stream draining is not exposed;
/// stopping can discard the converter tail and must be reported by its owner.
public final class VirtualPCMResampler: @unchecked Sendable {
    public static let outputSampleRate: Double = 44100
    public static let minFramesPerCall: Int = 1
    public static let maxFramesPerCall: Int = 4096
    public static let maxOutputFramesPerPacket: Int = 4096
    public static let supportedChannelCounts: Set<Int> = [1, 2, 3, 4, 6, 8]

    public let sourceRate: Double
    public let channels: Int
    public let leadingFrames: UInt32
    public let trailingFrames: UInt32

    /// Always false: priming/latency is reported as raw frame counts only and
    /// is not characterized as an accurate end-to-end delay estimate.
    public let delayKnown: Bool = false

    private let lock = NSLock()
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    // Input requests execute synchronously under the instance lock. This
    // cursor satisfies the SDK's Sendable callback and never escapes a call.
    private final class InputCursor: @unchecked Sendable { var offset = 0 }

    public init(sourceRate: Double, channels: Int) throws {
        guard sourceRate == 44100.0 || sourceRate == 48000.0 else {
            throw VirtualPCMResamplerError.invalidSourceRate(sourceRate)
        }
        guard Self.supportedChannelCounts.contains(channels) else {
            throw VirtualPCMResamplerError.unsupportedChannelCount(channels)
        }
        // AVAudioFormat's channels-only initializer rejects >2 channels.
        // Discrete slots deliberately give the converter no spatial labels;
        // those remain owned by the capture descriptor and routing layer.
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else {
            throw VirtualPCMResamplerError.converterUnavailable
        }
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: sourceRate, interleaved: true, channelLayout: layout)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Self.outputSampleRate, interleaved: true, channelLayout: layout)
        self.sourceRate = sourceRate
        self.channels = channels
        self.inputFormat = input
        self.outputFormat = output

        if sourceRate == Self.outputSampleRate {
            converter = nil
            leadingFrames = 0
            trailingFrames = 0
            return
        }

        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw VirtualPCMResamplerError.converterUnavailable
        }
        converter.primeMethod = .none
        converter.channelMap = (0..<channels).map { NSNumber(value: $0) }
        self.converter = converter
        leadingFrames = converter.primeInfo.leadingFrames
        trailingFrames = converter.primeInfo.trailingFrames
    }

    /// Convert one call's worth of interleaved samples. `frames` must be in
    /// `1...4096` and `samples.count` must equal `frames * channels`. All
    /// samples must be finite; the block is validated before any sample is
    /// consumed so malformed blocks never advance converter state.
    public func convert(samples: [Float], frames: Int) throws -> [VirtualConvertedPCM] {
        guard frames >= Self.minFramesPerCall, frames <= Self.maxFramesPerCall else {
            throw VirtualPCMResamplerError.invalidFrameCount(frames)
        }
        let expected = frames * channels
        guard samples.count == expected else {
            throw VirtualPCMResamplerError.samplesCountMismatch(expected: expected, actual: samples.count)
        }
        for (index, sample) in samples.enumerated() where !sample.isFinite {
            throw VirtualPCMResamplerError.nonFiniteInput(index: index)
        }

        lock.lock()
        defer { lock.unlock() }
        if let converter {
            return try resample(samples, frames: frames, channels: channels, converter: converter)
        }
        return try passThrough(samples, frames: frames)
    }

    private func passThrough(_ samples: [Float], frames: Int) throws -> [VirtualConvertedPCM] {
        var bytes = Data(capacity: samples.count * MemoryLayout<Float>.size)
        var clipped: UInt64 = 0
        for sample in samples {
            var bits = try clampFinite(sample, clipped: &clipped).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return [VirtualConvertedPCM(frames: frames, bytes: bytes, clippedSamples: clipped)]
    }

    private func resample(_ samples: [Float], frames: Int, channels: Int,
                          converter: AVAudioConverter) throws -> [VirtualConvertedPCM] {
        let cursor = InputCursor()
        var packets: [VirtualConvertedPCM] = []

        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: AVAudioFrameCount(Self.maxOutputFramesPerPacket)) else {
                throw VirtualPCMResamplerError.outputAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                let remaining = frames - cursor.offset
                guard remaining > 0 else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                let count = min(Int(requested), remaining)
                guard let input = AVAudioPCMBuffer(pcmFormat: self.inputFormat,
                                                   frameCapacity: AVAudioFrameCount(count)),
                      let destination = input.floatChannelData?[0] else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                input.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress! + cursor.offset * channels,
                                       count: count * channels)
                }
                cursor.offset += count
                inputStatus.pointee = .haveData
                return input
            }

            if status == .error {
                throw VirtualPCMResamplerError.converterFailed(error?.localizedDescription ?? "AVAudioConverter failed")
            }

            let outFrames = Int(output.frameLength)
            if outFrames > 0, let interleaved = output.floatChannelData?[0] {
                var bytes = Data(capacity: outFrames * channels * MemoryLayout<Float>.size)
                var clipped: UInt64 = 0
                for index in 0..<(outFrames * channels) {
                    var bits = try clampFinite(interleaved[index], clipped: &clipped).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                }
                packets.append(VirtualConvertedPCM(frames: outFrames, bytes: bytes, clippedSamples: clipped))
            }

            if status == .inputRanDry || status == .endOfStream {
                guard cursor.offset == frames else {
                    throw VirtualPCMResamplerError.converterFailed("converter did not consume the input block")
                }
                return packets
            }
        }
        throw VirtualPCMResamplerError.workBudgetExceeded
    }

    private func clampFinite(_ value: Float, clipped: inout UInt64) throws -> Float {
        guard value.isFinite else { throw VirtualPCMResamplerError.nonFiniteOutput }
        let limited = min(1.0, max(-1.0, value))
        if limited != value { clipped += 1 }
        return limited
    }
}
