import Foundation
@preconcurrency import AVFAudio
import ProcessTapCapture

public struct ConvertedPCM: Sendable {
    public let frames: Int
    public let bytes: Data
    public let clippedSamples: UInt64
}

/// Converter ownership is confined to one serial non-RT queue.
public final class FloatResampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HomePodFlow.capture.resample")
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    public let sourceRate: Double
    public let leadingFrames: UInt32
    public let trailingFrames: UInt32
    public init(sourceRate: Double, channels: Int) throws {
        guard (8000...192000).contains(sourceRate), channels == 2,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 2, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw HostFailure.converter("Unsupported stereo source format") }
        converter.primeMethod = .none
        inputFormat = input; outputFormat = output; self.converter = converter; self.sourceRate = sourceRate
        leadingFrames = converter.primeInfo.leadingFrames; trailingFrames = converter.primeInfo.trailingFrames
    }
    public func convert(_ block: CapturedPCMBlock) async throws -> [ConvertedPCM] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try convertOnQueue(block)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func convertOnQueue(_ block: CapturedPCMBlock) throws -> [ConvertedPCM] {
        guard block.format.channels == 2, block.format.sampleRate == sourceRate else { throw HostFailure.converter("Source format changed") }
        let values = try block.interleavedFloat32()
        var offset = 0
        var packets: [ConvertedPCM] = []
        for _ in 0..<128 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw HostFailure.converter("Output allocation failed") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                guard offset < block.frames else { inputStatus.pointee = .noDataNow; return nil }
                let count = min(Int(requested), block.frames - offset)
                guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: AVAudioFrameCount(count)),
                      let channels = input.floatChannelData else { inputStatus.pointee = .noDataNow; return nil }
                input.frameLength = AVAudioFrameCount(count)
                for frame in 0..<count {
                    channels[0][frame] = values[(offset + frame) * 2]
                    channels[1][frame] = values[(offset + frame) * 2 + 1]
                }
                offset += count
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw HostFailure.converter(error?.localizedDescription ?? "AVAudioConverter failed") }
            if output.frameLength > 0, let channels = output.floatChannelData {
                let frames = Int(output.frameLength)
                var bytes = Data(capacity: frames * 8)
                var clipped: UInt64 = 0
                for frame in 0..<frames {
                    for channel in 0..<2 {
                        let sample = channels[channel][frame]
                        guard sample.isFinite else { throw HostFailure.converter("Non-finite converted sample") }
                        let limited = min(1, max(-1, sample))
                        if limited != sample { clipped += 1 }
                        var bits = limited.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                    }
                }
                packets.append(.init(frames: frames, bytes: bytes, clippedSamples: clipped))
            }
            if status == .inputRanDry || status == .endOfStream {
                guard offset == block.frames else { throw HostFailure.converter("Converter did not consume input block") }
                return packets
            }
        }
        throw HostFailure.converter("Converter exceeded bounded work budget")
    }
}
