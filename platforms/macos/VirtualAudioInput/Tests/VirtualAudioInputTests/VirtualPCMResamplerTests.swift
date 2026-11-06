import Foundation
import XCTest
@testable import VirtualAudioInput

final class VirtualPCMResamplerTests: XCTestCase {
    private let supportedChannels = [1, 2, 3, 4, 6, 8]

    private func makeSamples(frames: Int, channels: Int,
                             value: (_ frame: Int, _ channel: Int) -> Float) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] = value(frame, channel)
            }
        }
        return samples
    }

    private func decodeFloats(_ data: Data) -> [Float] {
        var decoded = [Float]()
        decoded.reserveCapacity(data.count / MemoryLayout<Float>.size)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<UInt32>.size <= raw.count {
                let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                decoded.append(Float(bitPattern: bits))
                offset += MemoryLayout<UInt32>.size
            }
        }
        return decoded
    }

    private func accumulatedFrames(_ packets: [VirtualConvertedPCM]) -> Int {
        packets.reduce(0) { $0 + $1.frames }
    }

    func test44k1PassthroughIdentityAcrossAllChannelCounts() throws {
        for channels in supportedChannels {
            let resampler = try VirtualPCMResampler(sourceRate: 44100, channels: channels)
            let frames = 512
            let samples = makeSamples(frames: frames, channels: channels) { frame, channel in
                Float((frame * 7 + channel * 13) % 101) / 101.0 - 0.5
            }

            let packets = try resampler.convert(samples: samples, frames: frames)
            XCTAssertEqual(packets.count, 1, "channels=\(channels)")
            XCTAssertEqual(packets[0].frames, frames, "channels=\(channels)")
            XCTAssertEqual(packets[0].bytes.count, frames * channels * 4, "channels=\(channels)")
            XCTAssertEqual(packets[0].clippedSamples, 0, "channels=\(channels)")
            XCTAssertEqual(decodeFloats(packets[0].bytes), samples, "channels=\(channels) identity")
        }
    }

    func test48kAccumulatedFramesNearRatioWithoutRemix() throws {
        // Fractional ratio: a streaming converter may hold residual frames in
        // its tail, so only the accumulated total is asserted, never per block.
        let inputFramesPerBlock = 960
        let blockCount = 12
        let expected = Double(inputFramesPerBlock * blockCount) * 44100.0 / 48000.0
        let tolerance = 64.0

        for channels in supportedChannels {
            let resampler = try VirtualPCMResampler(sourceRate: 48000, channels: channels)
            let constants: [Float] = (0..<channels).map { 0.12 + 0.09 * Float($0) }
            let block = makeSamples(frames: inputFramesPerBlock, channels: channels) { _, channel in
                constants[channel]
            }

            var total = 0
            var lastBytes = Data()
            var lastFrames = 0
            for _ in 0..<blockCount {
                let packets = try resampler.convert(samples: block, frames: inputFramesPerBlock)
                XCTAssertFalse(packets.isEmpty, "channels=\(channels)")
                for packet in packets {
                    XCTAssertTrue((1...4096).contains(packet.frames), "channels=\(channels)")
                    XCTAssertEqual(packet.bytes.count, packet.frames * channels * 4, "channels=\(channels)")
                }
                total += accumulatedFrames(packets)
                if let last = packets.last {
                    lastBytes = last.bytes
                    lastFrames = last.frames
                }
            }

            XCTAssertTrue(Double(total) > 0, "channels=\(channels)")
            XCTAssertEqual(Double(total), expected, accuracy: tolerance, "channels=\(channels)")

            // Distinct per-channel constants must stay in their own channels
            // once the filter has converged (use the final packet).
            let decoded = decodeFloats(lastBytes)
            XCTAssertEqual(decoded.count, lastFrames * channels, "channels=\(channels)")
            for frame in 0..<lastFrames {
                for channel in 0..<channels {
                    XCTAssertEqual(decoded[frame * channels + channel], constants[channel],
                                   accuracy: 0.02, "channels=\(channels) channel=\(channel)")
                }
            }
        }
    }

    func test48kOneHotSignalsDoNotLeakAcrossChannels() throws {
        for channels in supportedChannels {
            for target in 0..<channels {
                let resampler = try VirtualPCMResampler(sourceRate: 48000, channels: channels)
                let frames = 4096
                let block = makeSamples(frames: frames, channels: channels) { _, channel in
                    channel == target ? 0.6 : 0.0
                }

                let packets = try resampler.convert(samples: block, frames: frames)
                var decoded: [Float] = []
                for packet in packets {
                    decoded.append(contentsOf: decodeFloats(packet.bytes))
                    XCTAssertEqual(packet.frames * channels * 4, packet.bytes.count, "channels=\(channels)")
                }

                var targetActive = false
                for frame in 0..<(decoded.count / channels) {
                    for channel in 0..<channels {
                        let value = decoded[frame * channels + channel]
                        if channel == target {
                            if abs(value) > 0.2 { targetActive = true }
                        } else {
                            XCTAssertEqual(value, 0.0, accuracy: 1e-5,
                                           "channels=\(channels) target=\(target) frame=\(frame) channel=\(channel)")
                        }
                    }
                }
                XCTAssertTrue(targetActive, "channels=\(channels) target=\(target)")
            }
        }
    }

    func testPayloadStridesAreInterleavedFiniteAndClamped() throws {
        let channels = 3
        let resampler = try VirtualPCMResampler(sourceRate: 44100, channels: channels)
        let frames = 1000
        let samples = makeSamples(frames: frames, channels: channels) { frame, channel in
            let index = frame * channels + channel
            if index % 7 == 0 { return 1.5 }
            if index % 7 == 1 { return -2.0 }
            return 0.3
        }
        let expectedClipped = samples.reduce(UInt64(0)) { $0 + (($1 < -1.0 || $1 > 1.0) ? 1 : 0) }

        let packets = try resampler.convert(samples: samples, frames: frames)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].frames, frames)
        XCTAssertEqual(packets[0].bytes.count, frames * channels * MemoryLayout<Float>.size)
        XCTAssertEqual(packets[0].clippedSamples, expectedClipped)

        let decoded = decodeFloats(packets[0].bytes)
        XCTAssertEqual(decoded.count, frames * channels)
        for (index, value) in decoded.enumerated() {
            XCTAssertTrue(value.isFinite, "index=\(index)")
            XCTAssertTrue((-1.0...1.0).contains(value), "index=\(index)")
        }
    }

    func testInvalidSourceRatesAreRejected() {
        for rate in [0.0, 32000.0, 44101.0, 48000.5, 96000.0, -44100.0] {
            XCTAssertThrowsError(try VirtualPCMResampler(sourceRate: rate, channels: 2),
                                 "rate=\(rate)") { error in
                XCTAssertEqual(error as? VirtualPCMResamplerError,
                               VirtualPCMResamplerError.invalidSourceRate(rate), "rate=\(rate)")
            }
        }
    }

    func testUnsupportedChannelCountsAreRejected() {
        for channels in [0, 5, 7, 9, 10, 64, -1] {
            XCTAssertThrowsError(try VirtualPCMResampler(sourceRate: 48000, channels: channels),
                                 "channels=\(channels)") { error in
                XCTAssertEqual(error as? VirtualPCMResamplerError,
                               VirtualPCMResamplerError.unsupportedChannelCount(channels), "channels=\(channels)")
            }
        }
    }

    func testInvalidFrameCountsAndSampleCountsAreRejected() throws {
        for rate in [44100.0, 48000.0] {
            let resampler = try VirtualPCMResampler(sourceRate: rate, channels: 2)
            XCTAssertThrowsError(try resampler.convert(samples: [Float](), frames: 0)) { error in
                XCTAssertEqual(error as? VirtualPCMResamplerError, VirtualPCMResamplerError.invalidFrameCount(0))
            }
            XCTAssertThrowsError(try resampler.convert(samples: [Float](repeating: 0, count: 4097 * 2),
                                                       frames: 4097)) { error in
                XCTAssertEqual(error as? VirtualPCMResamplerError, VirtualPCMResamplerError.invalidFrameCount(4097))
            }
            XCTAssertThrowsError(try resampler.convert(samples: [Float](repeating: 0, count: 15),
                                                       frames: 8)) { error in
                XCTAssertEqual(error as? VirtualPCMResamplerError,
                               VirtualPCMResamplerError.samplesCountMismatch(expected: 16, actual: 15))
            }
        }
    }

    func testNonFiniteInputIsRejectedBeforeConsumption() throws {
        for rate in [44100.0, 48000.0] {
            let resampler = try VirtualPCMResampler(sourceRate: rate, channels: 2)
            let frames = 64
            let badIndexes: [Float] = [.nan, .infinity, -.infinity]
            for bad in badIndexes {
                var samples = makeSamples(frames: frames, channels: 2) { frame, channel in
                    Float((frame + channel) % 13) / 13.0 - 0.4
                }
                samples[10] = bad
                XCTAssertThrowsError(try resampler.convert(samples: samples, frames: frames),
                                     "rate=\(rate) bad=\(bad)") { error in
                    XCTAssertEqual(error as? VirtualPCMResamplerError,
                                   VirtualPCMResamplerError.nonFiniteInput(index: 10), "rate=\(rate) bad=\(bad)")
                }
            }

            let good = makeSamples(frames: frames, channels: 2) { frame, channel in
                Float((frame + channel) % 13) / 13.0 - 0.4
            }
            let packets = try resampler.convert(samples: good, frames: frames)
            XCTAssertFalse(packets.isEmpty, "rate=\(rate)")
            let total = accumulatedFrames(packets)
            XCTAssertTrue((1...frames).contains(total), "rate=\(rate)")
            if rate == 44100.0 {
                XCTAssertEqual(total, frames, "rate=\(rate)")
                XCTAssertEqual(decodeFloats(packets[0].bytes), good, "rate=\(rate)")
            }
            for packet in packets {
                XCTAssertEqual(packet.bytes.count, packet.frames * 2 * 4, "rate=\(rate)")
                for value in decodeFloats(packet.bytes) {
                    XCTAssertTrue(value.isFinite, "rate=\(rate)")
                    XCTAssertTrue((-1.0...1.0).contains(value), "rate=\(rate)")
                }
            }
        }
    }
}
