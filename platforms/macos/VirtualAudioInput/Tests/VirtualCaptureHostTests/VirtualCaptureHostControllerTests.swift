import XCTest
import Darwin
@testable import VirtualCaptureHostSupport
@testable import VirtualAudioInput
import TapCaptureHostSupport

private let monoSession = UUID().uuidString

@MainActor
private final class FakeProvider: VirtualCaptureProvider {
    var descriptor: DeviceTapDescriptor
    var blocks: [VirtualAudioInput.CapturedPCMBlock] = []
    var started = false
    private(set) var stopCallCount = 0
    var stopError: Error?
    var readError: Error?

    init(descriptor: DeviceTapDescriptor) {
        self.descriptor = descriptor
    }

    func start(deviceUID: String) throws -> DeviceTapDescriptor {
        started = true
        return descriptor
    }

    func readBlock() throws -> VirtualAudioInput.CapturedPCMBlock? {
        if let readError { throw readError }
        return blocks.isEmpty ? nil : blocks.removeFirst()
    }

    func stop() throws {
        stopCallCount += 1
        if let stopError { throw stopError }
    }
}

/// Real nonblocking pipe + strict HPCM framing reader. The controller writes
/// through the public `BoundedPipeWriter`; tests drain the read end exactly the
/// way the Python consumer would.
@MainActor
private final class FrameRecorder {
    let writer: BoundedPipeWriter
    private let readFD: Int32
    private let writeFD: Int32
    private var buffer = Data()
    private(set) var records: [(header: [String: Any], payload: Data)] = []

    init() throws {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else { throw VirtualCaptureHostError.output("pipe allocation failed") }
        readFD = fds[0]
        writeFD = fds[1]
        let flags = fcntl(readFD, F_GETFL)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        writer = try BoundedPipeWriter(descriptor: writeFD)
    }

    func drain() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(readFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                parseComplete()
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
    }

    func close() {
        Darwin.close(writeFD)
        Darwin.close(readFD)
    }

    private func parseComplete() {
        while buffer.count >= 12 {
            guard String(data: buffer.prefix(4), encoding: .utf8) == "HPCM" else { return }
            let headerLength = Int(uInt32LE(4))
            let payloadLength = Int(uInt32LE(8))
            guard headerLength >= 0, payloadLength >= 0,
                  buffer.count >= 12 + headerLength + payloadLength else { return }
            let headerData = buffer.subdata(in: 12..<(12 + headerLength))
            let payload = buffer.subdata(in: (12 + headerLength)..<(12 + headerLength + payloadLength))
            buffer.removeSubrange(0..<(12 + headerLength + payloadLength))
            if let object = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] {
                records.append((object, payload))
            }
        }
    }

    private func uInt32LE(_ offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

@MainActor
private func descriptor(uid: String, channels: Int, rate: Double = 44_100) -> DeviceTapDescriptor {
    DeviceTapDescriptor(deviceUID: uid, streamIndex: 0, sampleRate: rate,
                        channels: UInt32(channels), bytesPerFrame: UInt32(4 * channels),
                        formatFlags: 9)
}

@MainActor
private func block(sequence: UInt64, channels: Int, frames: Int = 2,
                   value: Float = 0.1, dropped: UInt64 = 0,
                   flags: UInt32 = 3, nowFlags: UInt32 = 2) -> VirtualAudioInput.CapturedPCMBlock {
    VirtualAudioInput.CapturedPCMBlock(
        frames: frames,
        channels: channels,
        samples: Array(repeating: value, count: frames * channels),
        hostTime: 1000 + sequence * UInt64(frames),
        sampleTime: Double(sequence * UInt64(frames)),
        timestampFlags: flags,
        callbackSequence: sequence,
        droppedBefore: dropped,
        nowHostTime: 2000 + sequence * UInt64(frames),
        nowSampleTime: Double(sequence * UInt64(frames) + 1),
        nowFlags: nowFlags)
}

private func jsonLine(id: String, command: String, params: [String: Any], v: Int = 2) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "v": v, "id": id, "command": command, "params": params,
    ])
}

private func startLine(id: String, session: String, uid: String, layout: String) -> Data {
    jsonLine(id: id, command: "start", params: ["session": session, "deviceUID": uid, "layout": layout])
}

private func stopLine(id: String, session: String) -> Data {
    jsonLine(id: id, command: "stop", params: ["session": session])
}

final class VirtualCaptureHostControllerTests: XCTestCase {
    @MainActor
    func testInitAcquiresNoResourcesOrFactoryCall() throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        var factoryCalled = false
        let controller = VirtualCaptureHostController(writer: recorder.writer) {
            factoryCalled = true
            return FakeProvider(descriptor: descriptor(uid: "unused", channels: 1))
        }
        XCTAssertFalse(controller.shouldExit)
        XCTAssertEqual(controller.exitCode, 0)
        XCTAssertFalse(factoryCalled)
        recorder.drain()
        XCTAssertTrue(recorder.records.isEmpty)
    }

    @MainActor
    func testRejectsInvalidCommandsIncludingBooleanVersion() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let controller = VirtualCaptureHostController(writer: recorder.writer)
        let session = UUID().uuidString
        let uid = "com.homepodflow.virtual-audio.mono.v1"

        let booleanVersion: [String: Any] = [
            "v": true, "id": "1", "command": "start",
            "params": ["session": session, "deviceUID": uid, "layout": "mono"],
        ]
        await controller.command(try JSONSerialization.data(withJSONObject: booleanVersion))

        await controller.command(jsonLine(id: "2", command: "start",
                                          params: ["session": session, "deviceUID": uid, "layout": "mono"], v: 1))

        await controller.command(jsonLine(id: "3", command: "start",
                                          params: ["session": session, "deviceUID": uid, "layout": "mono", "extra": 1]))

        await controller.command(jsonLine(id: "", command: "stop", params: ["session": session]))

        _ = await recorder.writer.flush(timeout: 2)
        recorder.drain()
        XCTAssertEqual(recorder.records.count, 4)
        for record in recorder.records {
            XCTAssertEqual(record.header["kind"] as? String, "error")
            XCTAssertEqual(record.header["code"] as? String, "invalid_request")
            XCTAssertEqual(record.header["cleanupComplete"] as? Bool, true)
        }
        XCTAssertFalse(controller.shouldExit)
        XCTAssertEqual(controller.exitCode, 0)
    }

    @MainActor
    func testReadyAndPCMForMonoStereoAndSurround71() async throws {
        let layouts: [(String, String, Int)] = [
            ("mono", "com.homepodflow.virtual-audio.mono.v1", 1),
            ("stereo", "com.homepodflow.virtual-audio.stereo.v1", 2),
            ("7_1", "com.homepodflow.virtual-audio.surround71.v1", 8),
        ]
        for (layout, uid, channels) in layouts {
            let recorder = try FrameRecorder()
            let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: channels))
            provider.blocks = [block(sequence: 0, channels: channels),
                               block(sequence: 1, channels: channels)]
            let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
            let session = UUID().uuidString

            await controller.command(startLine(id: "s", session: session, uid: uid, layout: layout))

            guard let ready = try await wait(recorder, kind: "ready") else {
                return XCTFail("\(layout): ready record missing")
            }
            XCTAssertEqual(ready["outputRate"] as? Int, 44_100)
            XCTAssertEqual(ready["outputChannels"] as? Int, channels)
            XCTAssertEqual(ready["outputLayout"] as? String, layout)
            XCTAssertEqual(ready["deviceUID"] as? String, uid)
            XCTAssertEqual((ready["sourceRate"] as? NSNumber)?.intValue, 44_100)
            XCTAssertEqual(ready["sourceChannels"] as? Int, channels)

            let pcms = try await waitForPCM(recorder, count: 2)
            XCTAssertEqual(pcms.count, 2, "\(layout): expected 2 pcm records")
            for (index, header) in pcms.enumerated() {
                XCTAssertEqual(header["sequence"] as? Int, index)
                XCTAssertEqual(header["outputFrames"] as? Int, 2)
                XCTAssertEqual(header["kind"] as? String, "pcm")
                let source = header["source"] as? [String: Any]
                XCTAssertEqual((source?["sourceFrameStart"] as? NSNumber)?.uint64Value, UInt64(index * 2))
            }
            let payload = recorder.records.first { $0.header["kind"] as? String == "pcm" }?.payload ?? Data()
            XCTAssertEqual(payload.count, 2 * channels * MemoryLayout<Float>.size)

            await controller.command(stopLine(id: "t", session: session))
            guard let stopped = await waitStopped(recorder) else {
                return XCTFail("\(layout): stopped record missing")
            }
            XCTAssertEqual(stopped["cleanupComplete"] as? Bool, true)
            XCTAssertEqual(stopped["drainComplete"] as? Bool, false)
            XCTAssertEqual(stopped["discardedConverterTail"] as? Bool, true)
            XCTAssertEqual(controller.exitCode, 0)
            XCTAssertTrue(controller.shouldExit)
            XCTAssertEqual(provider.stopCallCount, 1)
            recorder.close()
        }
    }

    @MainActor
    func testCallbackGapFailsBounded() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1), block(sequence: 2, channels: 1)]
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))

        guard let error = try await wait(recorder, kind: "error") else {
            return XCTFail("gap: error record missing")
        }
        XCTAssertEqual(error["code"] as? String, "capture_failed")
        XCTAssertTrue((error["message"] as? String)?.contains("gap") == true)
        XCTAssertEqual(error["cleanupComplete"] as? Bool, true)
        XCTAssertEqual(error["discardedConverterTail"] as? Bool, true)
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testDroppedCallbackFailsBounded() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1, dropped: 1)]
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))

        guard let error = try await wait(recorder, kind: "error") else {
            return XCTFail("dropped: error record missing")
        }
        XCTAssertEqual(error["code"] as? String, "capture_failed")
        XCTAssertTrue((error["message"] as? String)?.contains("dropped") == true)
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
    }

    @MainActor
    func testReadErrorSurfacesAsCaptureFailed() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.readError = VirtualCaptureHostError.invalidRequest("injected read boom")
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))

        guard let error = try await wait(recorder, kind: "error") else {
            return XCTFail("read error: error record missing")
        }
        XCTAssertEqual(error["code"] as? String, "capture_failed")
        XCTAssertTrue((error["message"] as? String)?.contains("boom") == true)
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
    }

    @MainActor
    func testNoCallbacksFailsCaptureUnverified() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))

        guard let error = try await wait(recorder, kind: "error", timeout: 8) else {
            return XCTFail("unverified: error record missing")
        }
        XCTAssertEqual(error["code"] as? String, "capture_failed")
        XCTAssertEqual(error["message"] as? String, "capture_unverified")
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testEOFEmitsStoppedWithStartIDAndCleanExit() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1)]
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))
        _ = try await wait(recorder, kind: "ready")

        await controller.endInput()
        _ = await recorder.writer.flush(timeout: 2)
        recorder.drain()
        guard let stopped = recorder.records.last?.header, stopped["kind"] as? String == "stopped" else {
            return XCTFail("EOF: stopped record missing")
        }
        XCTAssertEqual(stopped["id"] as? String, "s")
        XCTAssertEqual(stopped["cleanupComplete"] as? Bool, true)
        XCTAssertEqual(stopped["drainComplete"] as? Bool, false)
        XCTAssertEqual(stopped["discardedConverterTail"] as? Bool, true)
        XCTAssertEqual(controller.exitCode, 0)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testInputFailedEmitsErrorThenTearsDownWithExit3() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1)]
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))
        _ = try await wait(recorder, kind: "ready")

        await controller.inputFailed("stdin failed with incomplete command")
        _ = await recorder.writer.flush(timeout: 2)
        recorder.drain()

        let headers = recorder.records.map(\.header)
        XCTAssertEqual(headers.first { $0["code"] as? String == "invalid_request" }?["message"] as? String,
                       "stdin failed with incomplete command")
        guard let stopped = headers.last, stopped["kind"] as? String == "stopped" else {
            return XCTFail("input failed: terminal stopped record missing")
        }
        XCTAssertEqual(stopped["id"] as? String, "s")
        XCTAssertEqual(stopped["cleanupComplete"] as? Bool, true)
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testStaleStopDoesNotCancelCurrentSession() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1)]
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))
        _ = try await wait(recorder, kind: "ready")

        await controller.command(stopLine(id: "stale", session: UUID().uuidString))
        guard let error = try await wait(recorder, kind: "error") else {
            return XCTFail("stale stop: correlated error missing")
        }
        XCTAssertEqual(error["id"] as? String, "stale")
        XCTAssertEqual(error["code"] as? String, "invalid_request")
        XCTAssertEqual(error["cleanupComplete"] as? Bool, false)
        XCTAssertFalse(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 0)
        XCTAssertEqual(controller.exitCode, 0)

        await controller.command(stopLine(id: "t", session: session))
        guard let stopped = await waitStopped(recorder) else {
            return XCTFail("real stop: stopped record missing")
        }
        XCTAssertEqual(stopped["cleanupComplete"] as? Bool, true)
        XCTAssertEqual(controller.exitCode, 0)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testStopCleanupFailureExits3AndReportsCleanupFalse() async throws {
        let recorder = try FrameRecorder()
        defer { recorder.close() }
        let uid = "com.homepodflow.virtual-audio.mono.v1"
        let provider = FakeProvider(descriptor: descriptor(uid: uid, channels: 1))
        provider.blocks = [block(sequence: 0, channels: 1)]
        provider.stopError = VirtualCaptureHostError.invalidRequest("injected stop boom")
        let controller = VirtualCaptureHostController(writer: recorder.writer) { provider }
        let session = UUID().uuidString
        await controller.command(startLine(id: "s", session: session, uid: uid, layout: "mono"))
        _ = try await wait(recorder, kind: "ready")

        await controller.command(stopLine(id: "t", session: session))
        _ = await recorder.writer.flush(timeout: 2)
        recorder.drain()
        guard let last = recorder.records.last?.header else { return XCTFail("cleanup failure: record missing") }
        XCTAssertEqual(last["kind"] as? String, "error")
        XCTAssertEqual(last["code"] as? String, "capture_failed")
        XCTAssertEqual(last["cleanupComplete"] as? Bool, false)
        XCTAssertTrue((last["message"] as? String)?.contains("stop boom") == true)
        XCTAssertEqual(controller.exitCode, 3)
        XCTAssertTrue(controller.shouldExit)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    @MainActor
    func testControlHelperFramesHPCMAndAddsVersion() throws {
        let data = try VirtualCaptureHostController.control(["kind": "ready"])
        XCTAssertEqual(data.prefix(4), Data("HPCM".utf8))
        let headerLength = data.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        }
        let payloadLength = data.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        }
        XCTAssertEqual(payloadLength, 0)
        XCTAssertEqual(data.count, 12 + headerLength)
        let json = data.subdata(in: 12..<data.count)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 2)
        XCTAssertEqual(object["kind"] as? String, "ready")
    }

    // MARK: - Helpers

    @MainActor
    private func wait(_ recorder: FrameRecorder, kind: String,
                      timeout: TimeInterval = 6) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = await recorder.writer.flush(timeout: 0.5)
            recorder.drain()
            if let found = recorder.records.map(\.header).last(where: { ($0["kind"] as? String) == kind }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await recorder.writer.flush(timeout: 1)
        recorder.drain()
        return recorder.records.map(\.header).last(where: { ($0["kind"] as? String) == kind })
    }

    @MainActor
    private func waitForPCM(_ recorder: FrameRecorder, count: Int,
                            timeout: TimeInterval = 6) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = await recorder.writer.flush(timeout: 0.5)
            recorder.drain()
            let pcms = recorder.records.map(\.header).filter { ($0["kind"] as? String) == "pcm" }
            if pcms.count >= count { return pcms }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await recorder.writer.flush(timeout: 1)
        recorder.drain()
        return recorder.records.map(\.header).filter { ($0["kind"] as? String) == "pcm" }
    }

    @MainActor
    private func waitStopped(_ recorder: FrameRecorder, timeout: TimeInterval = 6) async -> [String: Any]? {
        try? await wait(recorder, kind: "stopped", timeout: timeout)
    }
}
