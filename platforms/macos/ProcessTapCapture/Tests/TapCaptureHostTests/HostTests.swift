import Foundation
import Testing
import CoreAudio
@testable import ProcessTapCapture
@testable import TapCaptureHostSupport

private func block(rate: Double, start: Int, frames: Int, sequence: UInt64, amplitude: Float = 0.25) throws -> CapturedPCMBlock {
    let format = try CaptureFormat(asbd: .init(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
    let values = (0..<frames).flatMap { frame -> [Float] in
        let value = amplitude * Float(sin(2 * Double.pi * 440 * Double(start + frame) / rate))
        return [value, -value]
    }
    let data = values.withUnsafeBytes { Data($0) }
    return .init(sessionID: UUID(), format: format, frames: frames, buffers: [data], bufferChannels: [2],
        hostTime: UInt64(start + 100), sampleTime: Double(start), timestampFlags: 3, callbackSequence: sequence,
        droppedBlocksBefore: 0, nowTimestamp: .init(hostTime: UInt64(start + 101), sampleTime: Double(start), flags: 3),
        timebase: .init(numerator: 1, denominator: 1))
}

@Test func hpcmUsesIndependentKnownLittleEndianPrefixAndNullIDs() throws {
    let header = HostHeader(id: nil, session: nil, kind: "ready")
    let encoded = try HPCMCodec.encode(header: header)
    #expect(Array(encoded.prefix(4)) == [72, 80, 67, 77])
    let count = encoded[4..<8].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
    #expect(count == encoded.count - 12 && Array(encoded[8..<12]) == [0, 0, 0, 0])
    let fields = try #require(try JSONSerialization.jsonObject(with: encoded.dropFirst(12)) as? [String: Any])
    #expect(fields["id"] is NSNull && fields["session"] is NSNull)
    var pcm = HostHeader(id: "a", session: UUID().uuidString, kind: "pcm")
    pcm.outputFrames = 4097
    #expect(throws: (any Error).self) { try HPCMCodec.encode(header: pcm, payload: Data(count: 32776)) }
}

@Test func convertsOneSecond48kTo44100AndReportsClipping() async throws {
    let converter = try FloatResampler(sourceRate: 48000, channels: 2)
    var frames = 0, nonzero = false
    var clipped: UInt64 = 0
    for index in 0..<100 {
        let input = try block(rate: 48000, start: index * 480, frames: 480, sequence: UInt64(index), amplitude: 2)
        for packet in try await converter.convert(input) {
            #expect((1...4096).contains(packet.frames) && packet.bytes.count == packet.frames * 8)
            frames += packet.frames; clipped += packet.clippedSamples
            packet.bytes.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let sample = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    #expect(sample.isFinite && (-1...1).contains(sample))
                    if abs(sample) > 0.001 { nonzero = true }
                }
            }
        }
    }
    // No EOS flush: converter history may retain its documented tail.
    #expect(frames > 43000 && frames <= 44100 && nonzero && clipped > 0)
}

@Test func boundedWriterTimesOutWithoutBlockingControl() async throws {
    let pipe = Pipe()
    let writer = try BoundedPipeWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor, capacity: 131072, writeTimeout: 0.05)
    try writer.enqueue(Data(count: 100000)) // Reader deliberately does not consume.
    #expect(!(await writer.flush(timeout: 0.5)))
    #expect(writer.failure != nil && writer.pendingBytes <= 131072)
    try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
}

@MainActor private final class FakeCapture: HostCaptureProvider {
    var format: CaptureFormat?
    var sessionID: UUID?
    var droppedBlocks: UInt64 = 0
    var cleanupComplete = true
    var startCount = 0
    var stopCount = 0
    private var index = 0
    func start(configuration: CaptureConfiguration) throws {
        startCount += 1; cleanupComplete = false; sessionID = UUID()
        format = try block(rate: 48000, start: 0, frames: 480, sequence: 0).format
    }
    func readBlock() throws -> CapturedPCMBlock? {
        guard index < 4 else { return nil }
        defer { index += 1 }
        return try block(rate: 48000, start: index * 480, frames: 480, sequence: UInt64(index))
    }
    func stop() throws { stopCount += 1; cleanupComplete = true }
}

private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) { lock.withLock { bytes.append(value) } }
    func snapshot() -> Data { lock.withLock { bytes } }
}

@Test @MainActor func explicitStartStopUsesFakeCaptureAndCleansBeforeExit() async throws {
    let pipe = Pipe(), collector = ByteCollector()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let bytes = handle.availableData
        if bytes.isEmpty { handle.readabilityHandler = nil } else { collector.append(bytes) }
    }
    let writer = try BoundedPipeWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor)
    let capture = FakeCapture()
    let controller = CaptureHostController(writer: writer, factory: { capture })
    #expect(capture.startCount == 0)
    let session = UUID().uuidString
    let start = Data("{\"v\":1,\"id\":\"start\",\"command\":\"start\",\"params\":{\"session\":\"\(session)\",\"excludedProcessIDs\":[123]}}".utf8)
    await controller.command(start)
    try await Task.sleep(for: .milliseconds(80))
    let stop = Data("{\"v\":1,\"id\":\"stop\",\"command\":\"stop\",\"params\":{\"session\":\"\(session)\"}}".utf8)
    await controller.command(stop)
    #expect(await writer.flush())
    try await Task.sleep(for: .milliseconds(30))
    #expect(capture.startCount == 1 && capture.stopCount == 1 && capture.cleanupComplete)
    #expect(controller.shouldExit && controller.exitCode == 0)
    let bytes = collector.snapshot()
    var offset = 0, kinds: [String] = []
    while offset < bytes.count {
        #expect(String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) == "HPCM")
        func length(_ at: Int) -> Int { bytes[at..<(at + 4)].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) } }
        let headerCount = length(offset + 4), payloadCount = length(offset + 8)
        let fields = try #require(try JSONSerialization.jsonObject(with: bytes[(offset + 12)..<(offset + 12 + headerCount)]) as? [String: Any])
        kinds.append(fields["kind"] as? String ?? "")
        if fields["kind"] as? String == "stopped" {
            #expect(fields["id"] as? String == "stop" && fields["cleanupComplete"] as? Bool == true)
            #expect(fields["drainComplete"] as? Bool == false && fields["discardedConverterTail"] as? Bool == true)
        }
        offset += 12 + headerCount + payloadCount
    }
    #expect(kinds.first == "ready" && kinds.last == "stopped" && kinds.contains("pcm"))
    pipe.fileHandleForReading.readabilityHandler = nil
    try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
}

