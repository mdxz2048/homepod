import Testing
import Foundation
import CoreAudio
import CaptureRing
@testable import ProcessTapCapture

private func stereoFormat(planar: Bool = false) throws -> CaptureFormat {
    try CaptureFormat(asbd: .init(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
}

@MainActor private final class MockBackend: CaptureBackend {
    var calls: [String] = []
    var failAt: String?
    var planar = false
    var tap = false, aggregate = false, installed = false, started = false
    var ring: OpaquePointer?
    private var nextSample = 12.0
    private var nextHost: UInt64 = 700
    var callbackDetached: Bool { !started && !installed }
    func createTap(configuration: CaptureConfiguration) throws -> CaptureFormat {
        calls.append("tap"); tap = true
        try fail("tap")
        return try stereoFormat(planar: planar)
    }
    func createAggregate() throws { calls.append("aggregate"); aggregate = true; try fail("aggregate") }
    func installIO(ring: OpaquePointer) throws {
        calls.append("io"); self.ring = ring; installed = true; try fail("io")
    }
    func startDevice() throws { calls.append("start"); started = true; try fail("start") }
    func stopDevice() throws {
        guard started else { return }; calls.append("stop"); try fail("stop"); started = false
    }
    func destroyIO() throws {
        guard installed else { return }
        guard !started else { throw CaptureError.invalidState }
        calls.append("destroyIO"); try fail("destroyIO"); installed = false; ring = nil
    }
    func destroyAggregate() throws {
        guard aggregate else { return }
        guard callbackDetached else { throw CaptureError.invalidState }
        calls.append("destroyAggregate"); try fail("destroyAggregate"); aggregate = false
    }
    func destroyTap() throws {
        guard tap else { return }
        guard !aggregate, callbackDetached else { throw CaptureError.invalidState }
        calls.append("destroyTap"); try fail("destroyTap"); tap = false
    }
    private func fail(_ operation: String) throws {
        if failAt == operation { throw CaptureError.osStatus(operation, -123) }
    }
    func push(_ values: [Float]) {
        push(values, sampleTime: nextSample, hostTime: nextHost)
        nextSample += Double(values.count / 2)
        nextHost += UInt64(values.count / 2)
    }
    func push(_ values: [Float], sampleTime: Double, hostTime: UInt64 = 700) {
        var values = values
        values.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var time = AudioTimeStamp()
            time.mHostTime = hostTime; time.mSampleTime = sampleTime
            time.mFlags = [.hostTimeValid, .sampleTimeValid]
            var now = time; now.mHostTime += 5
            capture_ring_push(ring, &list, &time, &now)
        }
    }
}

@Test @MainActor func normalLifecycleAndSessionIdentity() throws {
    let backend = MockBackend()
    let capture = CaptureSource(backend: backend)
    #expect(capture.state == .idle)
    try capture.start(configuration: .init())
    let firstSession = try #require(capture.sessionID)
    #expect(capture.state == .running)
    backend.push([0.25, -0.5])
    let block = try #require(try capture.readBlock())
    #expect(block.sessionID == firstSession)
    #expect(block.frames == 1 && block.format.sampleRate == 48000)
    #expect(block.hostTime == 700 && block.sampleTime == 12)
    #expect(block.nowTimestamp.hostTime == 705)
    #expect(block.hostTimeIsValid && block.sampleTimeIsValid)
    #expect(try block.interleavedFloat32() == [0.25, -0.5])
    try capture.stop()
    #expect(backend.calls == ["tap", "aggregate", "io", "start", "stop", "destroyIO", "destroyAggregate", "destroyTap"])
    let count = backend.calls.count
    try capture.stop()
    #expect(backend.calls.count == count)
    try capture.start(configuration: .init())
    #expect(capture.sessionID != firstSession)
    try capture.stop()
}

@Test @MainActor func partialStartRollsBackInReverse() throws {
    for point in ["tap", "aggregate", "io", "start"] {
        let backend = MockBackend()
        backend.failAt = point
        let source = CaptureSource(backend: backend)
        #expect(throws: (any Error).self) { try source.start(configuration: .init()) }
        #expect(source.state == .idle)
        #expect(!backend.tap && !backend.aggregate && backend.callbackDetached)
        if point == "start" {
            #expect(Array(backend.calls.suffix(4)) == ["stop", "destroyIO", "destroyAggregate", "destroyTap"])
        }
    }
}

@Test @MainActor func cleanupFailurePreservesDependencyChain() throws {
    for point in ["stop", "destroyIO", "destroyAggregate", "destroyTap"] {
        let backend = MockBackend()
        let capture = CaptureSource(backend: backend)
        try capture.start(configuration: .init())
        backend.failAt = point
        #expect(throws: (any Error).self) { try capture.stop() }
        #expect(capture.state == .cleanupUnconfirmed)
        #expect(backend.tap)
        #expect(throws: (any Error).self) { try capture.start(configuration: .init()) }
        if point == "stop" || point == "destroyIO" { #expect(backend.aggregate && backend.installed) }
        backend.failAt = nil
        try capture.stop()
        #expect(capture.state == .idle && !backend.tap && !backend.aggregate)
    }
}

@Test @MainActor func boundedOverflowIdentifiesGap() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    try source.start(configuration: .init(queueBlocks: 2, maximumFramesPerCallback: 4))
    backend.push([1, 1]); backend.push([2, 2]); backend.push([3, 3])
    #expect(source.droppedBlocks == 1)
    let first = try #require(try source.readBlock())
    let second = try #require(try source.readBlock())
    #expect(first.callbackSequence == 0 && second.callbackSequence == 1)
    backend.push([4, 4])
    let after = try #require(try source.readBlock())
    #expect(after.callbackSequence == 3 && after.droppedBlocksBefore == 1)
    #expect(try after.interleavedFloat32() == [4, 4])
    try source.stop()
    #expect(source.droppedBlocks == 1)
}

@Test @MainActor func callbackFaultStopsOutsideRealTime() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    try source.start(configuration: .init(maximumFramesPerCallback: 1))
    backend.push([1, 1, 2, 2]) // Oversize: never copies out of bounds.
    #expect(throws: (any Error).self) { try source.readBlock() }
    #expect(!backend.started && !backend.installed && !backend.aggregate && !backend.tap)
    #expect(source.state != .running)
    try source.stop()
}

@Test @MainActor func scopedFailureStillStops() async throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    do {
        try await source.withCapture(configuration: .init()) { _ in
            throw CaptureError.invalidConfiguration("consumer failed")
        }
        Issue.record("Expected consumer failure")
    } catch { }
    #expect(source.state == .idle && !backend.tap && backend.callbackDetached)
}

@Test func rejectsUnsupportedFormatAndOversizedMemoryBudget() throws {
    var bad = try stereoFormat().asbd
    bad.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    bad.mBitsPerChannel = 16; bad.mBytesPerFrame = 4; bad.mBytesPerPacket = 4
    #expect(throws: (any Error).self) { try CaptureFormat(asbd: bad) }
    #expect(capture_ring_create(256, 16384, 32, 1, 4) == nil)
    #expect(capture_ring_create(3, 16, 1, 2, 8) == nil)
    #expect(throws: (any Error).self) {
        try CaptureConfiguration(selection: .processes([ProcessInfo.processInfo.processIdentifier])).validate()
    }
}

@Test @MainActor func nonFinitePCMIsRejectedOnConsumerSide() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    try source.start(configuration: .init())
    backend.push([.nan, .infinity])
    let block = try #require(try source.readBlock())
    #expect(throws: (any Error).self) { try block.interleavedFloat32() }
    try source.stop()
}

@Test @MainActor func invalidSampleTimestampIsNotVerified() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    try source.start(configuration: .init())
    backend.push([0.5, 0.5], sampleTime: .nan)
    let block = try #require(try source.readBlock())
    #expect(!block.sampleTimeIsValid && block.sampleTime.isNaN)
    #expect(!block.nowTimestamp.sampleTimeIsValid && block.nowTimestamp.sampleTime.isNaN)
    #expect(block.timebase.numerator > 0 && block.timebase.denominator > 0)
    try source.stop()
}

@Test @MainActor func scopedTaskCancellationStillStops() async throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    let task = Task { @MainActor in
        try await source.withCapture(configuration: .init()) { _ in
            try await Task.sleep(for: .seconds(60))
        }
    }
    for _ in 0..<100 {
        if source.state == .running { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(source.state == .running)
    task.cancel()
    do { try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError { }
    catch { Issue.record("Unexpected cancellation result: \(error)") }
    #expect(source.state == .idle && !backend.tap && backend.callbackDetached)
}

@Test @MainActor func planarRingPreservesAndInterleavesChannels() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    backend.planar = true
    try source.start(configuration: .init())
    let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
    let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
    defer { list.deinitialize(count: 1) }
    var left: [Float] = [0.25, 0.5], right: [Float] = [-0.25, -0.5]
    left.withUnsafeMutableBytes { leftBytes in
        right.withUnsafeMutableBytes { rightBytes in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            buffers[0] = .init(mNumberChannels: 1, mDataByteSize: UInt32(leftBytes.count), mData: leftBytes.baseAddress)
            buffers[1] = .init(mNumberChannels: 1, mDataByteSize: UInt32(rightBytes.count), mData: rightBytes.baseAddress)
            var time = AudioTimeStamp()
            time.mSampleTime = 42; time.mHostTime = 600; time.mFlags = [.hostTimeValid, .sampleTimeValid]
            var now = time
            capture_ring_push(backend.ring, list, &time, &now)
        }
    }
    let block = try #require(try source.readBlock())
    #expect(block.buffers.count == 2 && block.bufferChannels == [1, 1])
    #expect(try block.interleavedFloat32() == [0.25, -0.25, 0.5, -0.5])
    try source.stop()
}

@Test @MainActor func missingCallbackPointersFailStop() throws {
    let backend = MockBackend(), source = CaptureSource(backend: backend)
    try source.start(configuration: .init())
    capture_ring_push(backend.ring, nil, nil, nil)
    #expect(throws: (any Error).self) { try source.readBlock() }
    #expect(!backend.tap && backend.callbackDetached)
    try source.stop()
}

@Test @MainActor func timestampBackwardsAndUnexpectedJumpFailStop() throws {
    for changed in [(13.0, UInt64(699)), (1000.0, UInt64(701)), (11.0, UInt64(701))] {
        let backend = MockBackend(), source = CaptureSource(backend: backend)
        try source.start(configuration: .init())
        backend.push([0.5, 0.5], sampleTime: 12, hostTime: 700)
        _ = try #require(try source.readBlock())
        backend.push([0.5, 0.5], sampleTime: changed.0, hostTime: changed.1)
        do { _ = try source.readBlock(); Issue.record("Expected timestamp discontinuity") }
        catch CaptureError.timestampDiscontinuity { }
        catch { Issue.record("Wrong error: \(error)") }
        #expect(!backend.tap && backend.callbackDetached && source.state != .running)
        try source.stop()
    }
}

