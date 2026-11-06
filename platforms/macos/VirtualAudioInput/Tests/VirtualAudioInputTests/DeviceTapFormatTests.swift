import XCTest
import CoreAudio
import AudioToolbox
@testable import VirtualAudioInput

final class DeviceTapFormatTests: XCTestCase {
    private func makeASBD(channels: UInt32, rate: Double) -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = rate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        asbd.mBytesPerPacket = 4 * channels
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 4 * channels
        asbd.mChannelsPerFrame = channels
        asbd.mBitsPerChannel = 32
        return asbd
    }

    private func assertUnsupported(_ asbd: AudioStreamBasicDescription,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DeviceTapCapture.validate(asbd), file: file, line: line) { error in
            guard let failure = error as? InputFailure, case .unsupportedFormat = failure else {
                return XCTFail("expected unsupportedFormat, got \(error)", file: file, line: line)
            }
        }
    }

    func testAcceptsNativeMonoAndMultichannelAtBothRates() {
        for channels: UInt32 in [1, 2, 6, 8] {
            for rate in [44_100.0, 48_000.0] {
                XCTAssertNoThrow(try DeviceTapCapture.validate(makeASBD(channels: channels, rate: rate)),
                                 "\(channels)ch @ \(rate)")
            }
        }
    }

    func testRejectsZeroOrExcessChannels() {
        assertUnsupported(makeASBD(channels: 0, rate: 48_000))
        assertUnsupported(makeASBD(channels: 9, rate: 48_000))
    }

    func testRejectsWrongByteStrideAndPacketSizes() {
        var packed = makeASBD(channels: 2, rate: 48_000)
        packed.mBytesPerFrame = 4 * 2 + 4
        assertUnsupported(packed)

        var packet = makeASBD(channels: 2, rate: 48_000)
        packet.mBytesPerPacket = 4
        assertUnsupported(packet)

        var frames = makeASBD(channels: 2, rate: 48_000)
        frames.mFramesPerPacket = 2
        frames.mBytesPerPacket = 8
        assertUnsupported(frames)

        var bits = makeASBD(channels: 2, rate: 48_000)
        bits.mBitsPerChannel = 16
        assertUnsupported(bits)
    }

    func testRejectsIntegerAndPlanarFormats() {
        var integer = makeASBD(channels: 2, rate: 48_000)
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        assertUnsupported(integer)

        var planar = makeASBD(channels: 2, rate: 48_000)
        planar.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
            | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        planar.mBytesPerFrame = 4
        assertUnsupported(planar)
    }

    func testRejectsUnsupportedSampleRatesAndNonPCM() {
        assertUnsupported(makeASBD(channels: 2, rate: 44_000))
        assertUnsupported(makeASBD(channels: 2, rate: 96_000))

        var nonPCM = makeASBD(channels: 2, rate: 48_000)
        nonPCM.mFormatID = kAudioFormatMPEG4AAC
        assertUnsupported(nonPCM)
    }
}
