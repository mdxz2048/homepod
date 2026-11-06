import Testing
import Foundation
import CoreAudio
@testable import ProcessTapCapture

private func independentASBD(flags: AudioFormatFlags) -> AudioStreamBasicDescription {
    .init(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
          mFormatFlags: flags, mBytesPerPacket: 8, mFramesPerPacket: 1,
          mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
}

@Test func independentBigEndianPCMAndInvalidTimestampFlagsRemainHonest() throws {
    let format = try CaptureFormat(asbd: independentASBD(flags:
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian))
    // Known IEEE-754 bytes, not produced using the implementation's byte-swap.
    let bytes = Data([0x3f,0x00,0x00,0x00, 0xbe,0x80,0x00,0x00,
                      0x3f,0x80,0x00,0x00, 0xbf,0x80,0x00,0x00])
    let session = UUID()
    let block = CapturedPCMBlock(sessionID: session, format: format, frames: 2,
        buffers: [bytes], bufferChannels: [2], hostTime: 700, sampleTime: 3.75,
        timestampFlags: 0, callbackSequence: 4, droppedBlocksBefore: 0,
        nowTimestamp: .init(hostTime: 800, sampleTime: 4.5, flags: 0),
        timebase: .init(numerator: 1, denominator: 1))
    #expect(try block.interleavedFloat32() == [0.5, -0.25, 1, -1])
    #expect(block.format.sampleRate == 48000 && block.format.channels == 2)
    #expect(block.sessionID == session && block.callbackSequence == 4)
    #expect(!block.hostTimeIsValid && !block.sampleTimeIsValid)
    #expect(!block.nowTimestamp.hostTimeIsValid && !block.nowTimestamp.sampleTimeIsValid)
    #expect(block.hostTime == 700 && block.sampleTime == 3.75)
    #expect(block.nowTimestamp.hostTime == 800 && block.nowTimestamp.sampleTime == 4.5)
}

@Test func independentContradictoryFloatAndIntegerFormatIsRejected() throws {
    let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger
    #expect(throws: (any Error).self) {
        try CaptureFormat(asbd: independentASBD(flags: flags))
    }
}
