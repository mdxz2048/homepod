import Foundation
import XCTest
@testable import VirtualAudioInput

private let session = "AB12CD34-AB12-4D34-AB12-AB12CD34EF56"
private let startID = "start-qa"

private let uid: [String: String] = [
    "mono": "com.homepodflow.virtual-audio.mono.v1",
    "stereo": "com.homepodflow.virtual-audio.stereo.v1",
    "3_0": "com.homepodflow.virtual-audio.surround30.v1",
    "4_0": "com.homepodflow.virtual-audio.quad40.v1",
    "5_1_side": "com.homepodflow.virtual-audio.surround51s.v1",
    "5_1_back": "com.homepodflow.virtual-audio.surround51b.v1",
    "7_1": "com.homepodflow.virtual-audio.surround71.v1",
]

private let order: [String: [String]] = [
    "mono": ["M"],
    "stereo": ["FL", "FR"],
    "3_0": ["FL", "FR", "FC"],
    "4_0": ["FL", "FR", "BL", "BR"],
    "5_1_side": ["FL", "FR", "FC", "LFE", "SL", "SR"],
    "5_1_back": ["FL", "FR", "FC", "LFE", "BL", "BR"],
    "7_1": ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"],
]

private func pack(_ samples: [Float]) -> Data {
    var data = Data()
    for sample in samples {
        let bits = sample.bitPattern.littleEndian
        data.append(UInt8(truncatingIfNeeded: bits))
        data.append(UInt8(truncatingIfNeeded: bits >> 8))
        data.append(UInt8(truncatingIfNeeded: bits >> 16))
        data.append(UInt8(truncatingIfNeeded: bits >> 24))
    }
    return data
}

private func samples(frames: Int, channels: Int, frameIndex: Int = 0) -> [Float] {
    var values: [Float] = []
    values.reserveCapacity(frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            values.append(Float(((frame * channels + channel + frameIndex) % 16) + 1) / 20.0)
        }
    }
    return values
}

private func block(frames: Int,
                   channels: Int,
                   hostTime: UInt64 = 1000,
                   sampleTime: Double = 0.0,
                   callbackSequence: UInt64 = 0,
                   droppedBefore: UInt64 = 0,
                   nowHostTime: UInt64 = 2000,
                   nowSampleTime: Double = 0.0,
                   frameIndex: Int = 0) -> CapturedPCMBlock {
    CapturedPCMBlock(frames: frames,
                     channels: channels,
                     samples: samples(frames: frames, channels: channels, frameIndex: frameIndex),
                     hostTime: hostTime,
                     sampleTime: sampleTime,
                     timestampFlags: 3,
                     callbackSequence: callbackSequence,
                     droppedBefore: droppedBefore,
                     nowHostTime: nowHostTime,
                     nowSampleTime: nowSampleTime,
                     nowFlags: 3)
}

private func decode(_ data: Data) -> ([String: Any], Data) {
    let prefix = Array(data.prefix(12))
    var magic = Data(prefix[0..<4])
    XCTAssertEqual(magic, Data("HPCM".utf8))
    _ = magic
    let headerLength = Int(prefix[4]) | Int(prefix[5]) << 8
        | Int(prefix[6]) << 16 | Int(prefix[7]) << 24
    let payloadLength = Int(prefix[8]) | Int(prefix[9]) << 8
        | Int(prefix[10]) << 16 | Int(prefix[11]) << 24
    let headerJSON = data.subdata(in: 12..<(12 + headerLength))
    let payload = data.subdata(in: (12 + headerLength)..<(12 + headerLength + payloadLength))
    let header = try! JSONSerialization.jsonObject(with: headerJSON) as! [String: Any]
    return (header, payload)
}

final class VirtualHPCMEncoderTests: XCTestCase {
    func testHeaderSchemaAcrossCanonicalLayouts() throws {
        for (layout, labelOrder) in order {
            let channels = labelOrder.count
            let encoder = try VirtualHPCMEncoder(
                session: session, startID: startID, deviceUID: uid[layout]!,
                layout: layout, sourceRate: 48_000)
            let frames = 64
            let sourceBlock = block(frames: frames, channels: channels)
            let src = VirtualHPCMSource(block: sourceBlock, frameStart: 0,
                                        timebaseNumerator: 1_000_000_000,
                                        timebaseDenominator: 48_000)
            let data = try encoder.encodePCM(frames: frames,
                                             payload: pack(sourceBlock.samples),
                                             source: src)
            let (header, _) = decode(data)

            XCTAssertEqual(header["v"] as? Int, 2)
            XCTAssertEqual(header["id"] as? String, startID)
            XCTAssertEqual(header["session"] as? String, session)
            XCTAssertEqual(header["kind"] as? String, "pcm")
            XCTAssertEqual(header["outputRate"] as? Int, 44_100)
            XCTAssertEqual(header["outputChannels"] as? Int, channels)
            XCTAssertEqual(header["outputLayout"] as? String, layout)
            XCTAssertEqual(header["outputChannelOrder"] as? [String], labelOrder)

            let container = try XCTUnwrap(header["container"] as? [String: Any])
            XCTAssertEqual(container["deviceUID"] as? String, uid[layout])
            XCTAssertEqual(container["streamIndex"] as? Int, 0)
            XCTAssertEqual(container["channels"] as? Int, channels)
            XCTAssertEqual(container["layout"] as? String, layout)
            XCTAssertEqual(container["channelOrder"] as? [String], labelOrder)
            XCTAssertEqual(container["authority"] as? String, "device")
            XCTAssertEqual(container["verified"] as? Bool, true)

            let source = try XCTUnwrap(header["source"] as? [String: Any])
            XCTAssertEqual((source["sourceRate"] as? NSNumber)?.doubleValue, 48_000)
            XCTAssertEqual(source["sourceChannels"] as? Int, channels)
            XCTAssertEqual(source["sourceLayout"] as? String, layout)
            XCTAssertEqual(source["sourceChannelOrder"] as? [String], labelOrder)
            XCTAssertEqual(source["sourceLayoutAuthority"] as? String, "device")
            XCTAssertEqual(source["sourceOrigin"] as? String, "os_mix")
            XCTAssertEqual(source["sourceLayoutVerified"] as? Bool, false)
            XCTAssertEqual(source["nativeClaim"] as? Bool, false)
            XCTAssertEqual(source["upstreamTransform"] as? String, "os_mix_possible")

            XCTAssertEqual(header["provenance"] as? String, "source_upstream_mapped")
            let transform = try XCTUnwrap(header["captureTransform"] as? [String: Any])
            XCTAssertEqual(transform["kind"] as? String, "identity")
            XCTAssertEqual((transform["placed"] as? [Any])?.isEmpty, true)
            XCTAssertEqual((transform["silentSlots"] as? [Any])?.isEmpty, true)
            XCTAssertEqual(transform["transformations"] as? [String], ["identity"])
        }
    }

    func testInputAndOutputFrameCountsMayDiffer() throws {
        let encoder = try VirtualHPCMEncoder(
            session: session, startID: startID, deviceUID: uid["stereo"]!,
            layout: "stereo", sourceRate: 48_000)
        let inputFrames = 480
        let outputFrames = 441
        let sourceBlock = block(frames: inputFrames, channels: 2)
        let resampledPayload = pack(samples(frames: outputFrames, channels: 2,
                                            frameIndex: 7))
        XCTAssertNotEqual(resampledPayload, pack(sourceBlock.samples))
        let data = try encoder.encodePCM(
            frames: outputFrames, payload: resampledPayload,
            source: VirtualHPCMSource(
                block: sourceBlock, frameStart: 0,
                timebaseNumerator: 1_000_000_000,
                timebaseDenominator: 48_000))
        let (header, decodedPayload) = decode(data)
        XCTAssertEqual(decodedPayload, resampledPayload)
        let source = try XCTUnwrap(header["source"] as? [String: Any])
        XCTAssertEqual(header["outputFrames"] as? Int, outputFrames)
        XCTAssertEqual(header["inputFramesConsumedTotal"] as? Int, inputFrames)
        XCTAssertEqual(source["sourceFrames"] as? Int, inputFrames)
    }

    func testTwoPacketsSameSourceThenNextBlockAdvancesByInputCount() throws {
        let encoder = try VirtualHPCMEncoder(
            session: session, startID: startID, deviceUID: uid["stereo"]!,
            layout: "stereo", sourceRate: 48_000)
        let inputFrames = 480
        let sourceBlock = block(frames: inputFrames, channels: 2)
        let src = VirtualHPCMSource(block: sourceBlock, frameStart: 0,
                                    timebaseNumerator: 1_000_000_000,
                                    timebaseDenominator: 48_000)
        let payloadA = pack(samples(frames: 441, channels: 2, frameIndex: 0))
        let payloadB = pack(samples(frames: 441, channels: 2, frameIndex: 441))

        let first = try encoder.encodePCM(frames: 441, payload: payloadA, source: src)
        let second = try encoder.encodePCM(frames: 441, payload: payloadB, source: src)
        let (h1, _) = decode(first)
        let (h2, _) = decode(second)
        XCTAssertEqual(h1["sequence"] as? Int, 0)
        XCTAssertEqual(h1["outputFrameStart"] as? Int, 0)
        XCTAssertEqual(h2["sequence"] as? Int, 1)
        XCTAssertEqual(h2["outputFrameStart"] as? Int, 441)
        XCTAssertEqual((h1["source"] as? [String: Any])?["sourceSequence"] as? Int,
                       (h2["source"] as? [String: Any])?["sourceSequence"] as? Int)

        let nextBlock = block(frames: inputFrames, channels: 2,
                              hostTime: 1_000_000_000,
                              callbackSequence: 1,
                              nowHostTime: 1_000_001_000,
                              frameIndex: inputFrames)
        let third = try encoder.encodePCM(
            frames: 441,
            payload: pack(samples(frames: 441, channels: 2, frameIndex: 882)),
            source: VirtualHPCMSource(block: nextBlock, frameStart: UInt64(inputFrames),
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))
        let (h3, _) = decode(third)
        XCTAssertEqual(h3["sequence"] as? Int, 2)
        XCTAssertEqual(h3["outputFrameStart"] as? Int, 882)
        XCTAssertEqual(h3["inputFramesConsumedTotal"] as? Int, inputFrames * 2)
        XCTAssertEqual((h3["source"] as? [String: Any])?["sourceFrames"] as? Int, inputFrames)
    }

    func testRejectionsLeaveStateUnchanged() throws {
        let encoder = try VirtualHPCMEncoder(
            session: session, startID: startID, deviceUID: uid["stereo"]!,
            layout: "stereo", sourceRate: 48_000)
        let frames = 480
        let sourceBlock = block(frames: frames, channels: 2)
        let src = VirtualHPCMSource(block: sourceBlock, frameStart: 0,
                                    timebaseNumerator: 1_000_000_000,
                                    timebaseDenominator: 48_000)
        _ = try encoder.encodePCM(frames: frames, payload: pack(sourceBlock.samples), source: src)

        XCTAssertThrowsError(try encoder.encodePCM(
            frames: frames, payload: Data(), source: src)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .payloadSizeMismatch)
        }

        let shortSamples = Array(sourceBlock.samples.dropLast())
        let shortBlock = CapturedPCMBlock(frames: frames, channels: 2,
                                          samples: shortSamples,
                                          hostTime: sourceBlock.hostTime,
                                          sampleTime: sourceBlock.sampleTime,
                                          timestampFlags: sourceBlock.timestampFlags,
                                          callbackSequence: 1,
                                          droppedBefore: 0,
                                          nowHostTime: sourceBlock.nowHostTime,
                                          nowSampleTime: sourceBlock.nowSampleTime,
                                          nowFlags: sourceBlock.nowFlags)
        XCTAssertThrowsError(try encoder.encodePCM(
            frames: frames, payload: pack(samples(frames: frames, channels: 2)),
            source: VirtualHPCMSource(block: shortBlock, frameStart: UInt64(frames),
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .sampleCountMismatch)
        }

        // Next valid frame must continue from sequence 1 / frameStart 480.
        let nextBlock = block(frames: frames, channels: 2,
                              hostTime: 1_000_000_000,
                              callbackSequence: 1,
                              nowHostTime: 1_000_001_000,
                              frameIndex: frames)
        let next = try encoder.encodePCM(
            frames: frames,
            payload: pack(nextBlock.samples),
            source: VirtualHPCMSource(block: nextBlock, frameStart: UInt64(frames),
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))
        let (header, _) = decode(next)
        XCTAssertEqual(header["sequence"] as? Int, 1)
        XCTAssertEqual(header["outputFrameStart"] as? Int, frames)
    }

    func testTimestampFlagsRoundTripAndInvalidReject() throws {
        func makeEncoder() throws -> VirtualHPCMEncoder {
            try VirtualHPCMEncoder(session: session, startID: startID,
                                   deviceUID: uid["stereo"]!,
                                   layout: "stereo", sourceRate: 48_000)
        }
        let frames = 8
        let flagBlock = CapturedPCMBlock(frames: frames, channels: 2,
                                         samples: samples(frames: frames, channels: 2),
                                         hostTime: 1000, sampleTime: 0,
                                         timestampFlags: 7, callbackSequence: 0,
                                         droppedBefore: 0, nowHostTime: 2000,
                                         nowSampleTime: 0, nowFlags: 7)
        let encoder = try makeEncoder()
        let data = try encoder.encodePCM(
            frames: frames, payload: pack(flagBlock.samples),
            source: VirtualHPCMSource(block: flagBlock, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))
        let (flagHeader, _) = decode(data)
        let source = try XCTUnwrap(flagHeader["source"] as? [String: Any])
        XCTAssertEqual(source["flags"] as? Int, 7)
        XCTAssertEqual(source["nowFlags"] as? Int, 7)

        let invalid = CapturedPCMBlock(frames: frames, channels: 2,
                                       samples: samples(frames: frames, channels: 2),
                                       hostTime: 1000, sampleTime: 0,
                                       timestampFlags: 0, callbackSequence: 0,
                                       droppedBefore: 0, nowHostTime: 2000,
                                       nowSampleTime: 0, nowFlags: 0)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: frames, payload: pack(invalid.samples),
            source: VirtualHPCMSource(block: invalid, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidCaptureFlags)
        }
    }

    func testSourceFrameStartOverflowRejectsBeforeMutation() throws {
        let encoder = try VirtualHPCMEncoder(session: session, startID: startID,
                                             deviceUID: uid["stereo"]!,
                                             layout: "stereo", sourceRate: 48_000)
        let frames = 1
        let overflowBlock = block(frames: frames, channels: 2)
        XCTAssertThrowsError(try encoder.encodePCM(
            frames: frames, payload: pack(overflowBlock.samples),
            source: VirtualHPCMSource(block: overflowBlock, frameStart: .max,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .counterOverflow)
        }

        let validBlock = block(frames: frames, channels: 2)
        let valid = try encoder.encodePCM(
            frames: frames, payload: pack(validBlock.samples),
            source: VirtualHPCMSource(block: validBlock, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))
        let (header, _) = decode(valid)
        XCTAssertEqual(header["sequence"] as? Int, 0)
        XCTAssertEqual(header["outputFrameStart"] as? Int, 0)
    }

    func testMalformedSizesAndNonFinitePCMRejected() throws {
        func makeEncoder() throws -> VirtualHPCMEncoder {
            try VirtualHPCMEncoder(session: session, startID: startID,
                                   deviceUID: uid["stereo"]!,
                                   layout: "stereo", sourceRate: 48_000)
        }

        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: 0, payload: Data(),
            source: VirtualHPCMSource(block: block(frames: 0, channels: 2),
                                      frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidFrameCount)
        }
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: 4097, payload: Data(),
            source: VirtualHPCMSource(block: block(frames: 4097, channels: 2),
                                      frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidFrameCount)
        }

        let goodBlock = block(frames: 16, channels: 2)
        let normalized = VirtualHPCMSource(block: goodBlock, frameStart: 0,
                                           timebaseNumerator: 1_000_000_000,
                                           timebaseDenominator: 48_000)
        // Payload claiming more frames than actual block.
        let oversized = pack(goodBlock.samples) + Data(repeating: 0, count: 8)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: 16, payload: oversized, source: normalized)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .payloadSizeMismatch)
        }

        // Out-of-range sample (packed bytes agree, magnitude fails).
        var outOfRange = samples(frames: 16, channels: 2)
        outOfRange[0] = 2.0
        let outOfRangeBlock = CapturedPCMBlock(frames: 16, channels: 2,
                                               samples: outOfRange,
                                               hostTime: 1000, sampleTime: 0,
                                               timestampFlags: 3,
                                               callbackSequence: 0,
                                               droppedBefore: 0,
                                               nowHostTime: 2000,
                                               nowSampleTime: 0, nowFlags: 3)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: 16, payload: pack(outOfRange),
            source: VirtualHPCMSource(block: outOfRangeBlock, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .pcmOutOfRange)
        }

        var nanBlock = outOfRangeBlock
        nanBlock = CapturedPCMBlock(frames: 16, channels: 2,
                                    samples: [.nan] + Array(outOfRange.dropFirst()),
                                    hostTime: 1000, sampleTime: 0,
                                    timestampFlags: 3, callbackSequence: 0,
                                    droppedBefore: 0, nowHostTime: 2000,
                                    nowSampleTime: 0, nowFlags: 3)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: 16, payload: pack(nanBlock.samples),
            source: VirtualHPCMSource(block: nanBlock, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .pcmOutOfRange)
        }
    }

    func testConfigurationRejections() {
        XCTAssertThrowsError(try VirtualHPCMEncoder(
            session: "not-a-uuid", startID: startID,
            deviceUID: uid["stereo"]!, layout: "stereo", sourceRate: 48_000)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidSession)
        }
        XCTAssertThrowsError(try VirtualHPCMEncoder(
            session: session, startID: startID,
            deviceUID: uid["stereo"]!, layout: "stereo", sourceRate: 96_000)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .unsupportedSourceRate)
        }
        XCTAssertThrowsError(try VirtualHPCMEncoder(
            session: session, startID: startID,
            deviceUID: uid["mono"]!, layout: "stereo", sourceRate: 48_000)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidDeviceUID)
        }
        XCTAssertThrowsError(try VirtualHPCMEncoder(
            session: session, startID: startID,
            deviceUID: uid["stereo"]!, layout: "stereo", sourceRate: 48_000,
            leadingFrames: 4097)) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidPrimeFrames)
        }
    }

    func testCounterAndTimestampRejections() throws {
        func makeEncoder() throws -> VirtualHPCMEncoder {
            try VirtualHPCMEncoder(session: session, startID: startID,
                                   deviceUID: uid["stereo"]!,
                                   layout: "stereo", sourceRate: 48_000)
        }
        let frames = 64

        // Dropped blocks before the first frame.
        let dropped = block(frames: frames, channels: 2, droppedBefore: 1)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: frames, payload: pack(dropped.samples),
            source: VirtualHPCMSource(block: dropped, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .droppedBlocks)
        }

        // Non-finite sample time.
        let infiniteTime = CapturedPCMBlock(frames: frames, channels: 2,
                                            samples: samples(frames: frames, channels: 2),
                                            hostTime: 1000, sampleTime: .infinity,
                                            timestampFlags: 3, callbackSequence: 0,
                                            droppedBefore: 0, nowHostTime: 2000,
                                            nowSampleTime: 0, nowFlags: 3)
        XCTAssertThrowsError(try makeEncoder().encodePCM(
            frames: frames, payload: pack(infiniteTime.samples),
            source: VirtualHPCMSource(block: infiniteTime, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .invalidSampleTime)
        }

        // Establish continuity, then regress the capture clock.
        let encoder = try makeEncoder()
        let firstBlock = block(frames: frames, channels: 2, hostTime: 1000)
        _ = try encoder.encodePCM(
            frames: frames, payload: pack(firstBlock.samples),
            source: VirtualHPCMSource(block: firstBlock, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))

        let regressed = block(frames: frames, channels: 2,
                              hostTime: 500, callbackSequence: 1)
        XCTAssertThrowsError(try encoder.encodePCM(
            frames: frames, payload: pack(regressed.samples),
            source: VirtualHPCMSource(block: regressed, frameStart: UInt64(frames),
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .sourceOverlapOrRegress)
        }
        let overlap = block(frames: frames, channels: 2,
                            hostTime: 2000, callbackSequence: 1)
        XCTAssertThrowsError(try encoder.encodePCM(
            frames: frames, payload: pack(overlap.samples),
            source: VirtualHPCMSource(block: overlap, frameStart: 0,
                                      timebaseNumerator: 1_000_000_000,
                                      timebaseDenominator: 48_000))) { error in
            XCTAssertEqual(error as? VirtualHPCMEncoderError, .sourceOverlapOrRegress)
        }
    }
}
