import Foundation
import Testing
import CoreAudio
import CaptureRing
@testable import ProcessTapCapture

@Test func onlyOutputOnlyLiveClockCanAnchorTheAggregate() throws {
    let speakers = OutputClockDescriptor(deviceID: 10, uid: "builtin-speakers", inputStreamCount: 0, outputStreamCount: 1, alive: true)
    try OutputClockPolicy.validate(speakers)
    try OutputClockPolicy.validateUnchanged(speakers, expected: speakers)
    for invalid in [
        OutputClockDescriptor(deviceID: 10, uid: "combined-interface", inputStreamCount: 1, outputStreamCount: 1, alive: true),
        .init(deviceID: 0, uid: "builtin-speakers", inputStreamCount: 0, outputStreamCount: 1, alive: true),
        .init(deviceID: 10, uid: "", inputStreamCount: 0, outputStreamCount: 1, alive: true),
        .init(deviceID: 10, uid: "builtin-speakers", inputStreamCount: 0, outputStreamCount: 0, alive: true),
        .init(deviceID: 10, uid: "builtin-speakers", inputStreamCount: 0, outputStreamCount: 1, alive: false)
    ] {
        #expect(throws: (any Error).self) { try OutputClockPolicy.validate(invalid) }
    }
    let switched = OutputClockDescriptor(deviceID: 11, uid: "new-speakers", inputStreamCount: 0, outputStreamCount: 1, alive: true)
    #expect(throws: (any Error).self) { try OutputClockPolicy.validateUnchanged(switched, expected: speakers) }
}

@Test func outputBuffersAreZeroedWithinTheirDeclaredBounds() {
    let count = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
    let memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
    defer { list.deinitialize(count: 1) }
    var first = [UInt8](repeating: 0xA5, count: 12)
    var second = [UInt8](repeating: 0x5A, count: 16)
    first.withUnsafeMutableBytes { a in
        second.withUnsafeMutableBytes { b in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            buffers[0] = .init(mNumberChannels: 2, mDataByteSize: 8, mData: a.baseAddress)
            buffers[1] = .init(mNumberChannels: 2, mDataByteSize: 12, mData: b.baseAddress)
            #expect(capture_zero_output(list) == 0)
        }
    }
    #expect(first == [0, 0, 0, 0, 0, 0, 0, 0, 0xA5, 0xA5, 0xA5, 0xA5])
    #expect(second == Array(repeating: UInt8(0), count: 12) + Array(repeating: UInt8(0x5A), count: 4))
}

@Test func invalidOutputBufferStillSilencesOtherBuffers() {
    let count = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
    let memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
    defer { list.deinitialize(count: 1) }
    var good = [UInt8](repeating: 0x7F, count: 8)
    good.withUnsafeMutableBytes { raw in
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        buffers[0] = .init(mNumberChannels: 2, mDataByteSize: 8, mData: nil)
        buffers[1] = .init(mNumberChannels: 2, mDataByteSize: 8, mData: raw.baseAddress)
        #expect(capture_zero_output(list) == -1)
    }
    #expect(good == Array(repeating: UInt8(0), count: 8))
    #expect(capture_zero_output(nil) == 0)
}
