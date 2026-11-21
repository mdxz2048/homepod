import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Records the physical microphone directly. Input IOProc timestamps refer to
/// the actual input frames; no output-engine clock or callback receipt anchor.
private final class MicrophoneSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private struct Clock: Encodable { var frame: Int; var ns: Double }
    private var clocks: [Clock] = []
    private var rate = 0.0
    private var invalid = false
    private var callbacks = 0
    func prepare(rate: Double) {
        self.rate = rate
        samples.reserveCapacity(Int(rate * 90))
        clocks.reserveCapacity(18000)
    }
    func append(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        guard !invalid, time.mFlags.contains(.hostTimeValid) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        let stride = Int(first.mNumberChannels)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        guard count > 0 else { return }
        let ns = AVAudioTime.seconds(forHostTime: time.mHostTime) * 1e9
        if let last = clocks.last, ns <= last.ns { return }
        guard samples.count + count <= Int(rate * 90) else { invalid = true; return }
        clocks.append(Clock(frame: samples.count, ns: ns))
        let floats = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<count { samples.append(floats[frame * stride]) }
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "callbacks=\(callbacks), frames=\(samples.count), clockedBlocks=\(clocks.count), rate=\(rate), invalid=\(invalid)"
    }
    func write(to url: URL) throws -> (rate: Double, firstNS: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !invalid, let first = clocks.first, !samples.isEmpty else {
            throw WorkerFailure.remote("没有收到带硬件时间戳的麦克风录音，请检查输入设备。")
        }
        try samples.withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
        try JSONEncoder().encode(clocks).write(to: url.appendingPathExtension("clock.json"), options: .atomic)
        return (rate, first.ns)
    }
}

private let microphoneIOProc: AudioDeviceIOProc = { @Sendable _, _, input, time, _, _, context in
    guard let context else { return noErr }
    Unmanaged<MicrophoneSamples>.fromOpaque(context).takeUnretainedValue().append(input, time: time.pointee)
    return noErr
}

private final class MicrophonePermissionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?
    private var result: Result<Bool, any Error>?
    func install(_ continuation: CheckedContinuation<Bool, any Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func finish(_ result: Result<Bool, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}


struct InputMicrophone: Identifiable, Hashable {
    let id: String
    let name: String
    /// True for an iPhone/iPad paired through Continuity.
    let isContinuity: Bool
}

extension CalibrationMicrophone {
    /// Every input the app can record from, including an iPhone paired through
    /// Continuity. All of them deliver CoreAudio host timestamps on the Mac's
    /// own clock, so no cross-device time base has to be reconciled.
    static func available() -> [InputMicrophone] {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes, &devices) == noErr else { return [] }
        let allowed: [UInt32] = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                                 kAudioDeviceTransportTypeContinuityCaptureWired,
                                 kAudioDeviceTransportTypeContinuityCaptureWireless]
        func text(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
            var p = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &value, { AudioObjectGetPropertyData(device, &p, 0, nil, &size, $0) }) == noErr,
                  let value = value?.takeRetainedValue() else { return "" }
            return value as String
        }
        return devices.compactMap { device in
            var p = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &p, 0, nil, &size) == noErr, size > 0 else { return nil }
            p.mSelector = kAudioDevicePropertyTransportType
            var transport: UInt32 = 0; size = 4
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &transport) == noErr,
                  allowed.contains(transport) else { return nil }
            let uid = text(device, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { return nil }
            let continuity = transport == kAudioDeviceTransportTypeContinuityCaptureWired
                || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
            return InputMicrophone(id: uid, name: text(device, kAudioObjectPropertyName),
                                   isContinuity: continuity)
        }
    }
}

@MainActor final class CalibrationMicrophone {
    private let samples = MicrophoneSamples()
    private var device: AudioDeviceID?
    private var io: AudioDeviceIOProcID?
    private var context: UnsafeMutableRawPointer?
    private var cleanupConfirmed = true
    private(set) var uid = ""
    private(set) var name = "Mac 麦克风"
    var diagnostics: String { samples.summary }

    static func requirePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return }
        guard status == .notDetermined else {
            throw WorkerFailure.remote("请在系统设置 → 隐私与安全性 → 麦克风中允许 HomePod Flow。")
        }
        let waiter = MicrophonePermissionWaiter()
        let timer = Task.detached {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            waiter.finish(.failure(WorkerFailure.remote("等待麦克风授权超时，请允许后重新测试。")))
        }
        defer { timer.cancel() }
        let allowed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(continuation) else { return }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in waiter.finish(.success(allowed)) }
            }
        } onCancel: { waiter.finish(.failure(CancellationError())) }
        guard allowed else { throw WorkerFailure.remote("麦克风访问未允许，请在系统设置中开启后重试。") }
    }

    func start(preferredUID: String? = nil) async throws {
        try await Self.requirePermission()
        try Task.checkCancellation()
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes) == noErr else {
            throw WorkerFailure.remote("无法读取麦克风设备")
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes, &devices) == noErr else {
            throw WorkerFailure.remote("无法读取麦克风列表")
        }
        func deviceString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
            var p = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &value, { AudioObjectGetPropertyData(device, &p, 0, nil, &size, $0) }) == noErr,
                  let value = value?.takeRetainedValue() else { return "" }
            return value as String
        }
        let allowed: [UInt32] = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                                 kAudioDeviceTransportTypeContinuityCaptureWired,
                                 kAudioDeviceTransportTypeContinuityCaptureWireless]
        let candidates: [(AudioDeviceID, AudioStreamID, UInt32, String)] = devices.compactMap { device in
            var p = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &p, 0, nil, &size) == noErr, size > 0 else { return nil }
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }
            p.mSelector = kAudioDevicePropertyTransportType; p.mScope = kAudioObjectPropertyScopeGlobal
            var transport: UInt32 = 0; size = 4
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &transport) == noErr,
                  allowed.contains(transport) else { return nil }
            return (device, stream, transport, deviceString(device, kAudioDevicePropertyDeviceUID))
        }
        let preferred = preferredUID.flatMap { wanted in candidates.first { $0.3 == wanted } }
        guard let selected = preferred ?? candidates.first(where: { $0.2 == kAudioDeviceTransportTypeBuiltIn })
                ?? candidates.first(where: { $0.2 == kAudioDeviceTransportTypeUSB }) ?? candidates.first else {
            throw WorkerFailure.remote("请连接内置、USB 或 iPhone 麦克风。")
        }
        func string(_ selector: AudioObjectPropertySelector) -> String {
            var p = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &value, { AudioObjectGetPropertyData(selected.0, &p, 0, nil, &size, $0) }) == noErr,
                  let value = value?.takeRetainedValue() else { return "" }
            return value as String
        }
        uid = string(kAudioDevicePropertyDeviceUID); name = string(kAudioObjectPropertyName)
        var format = AudioStreamBasicDescription()
        property = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(selected.1, &property, 0, nil, &bytes, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, [44100.0, 48000.0, 96000.0].contains(format.mSampleRate) else {
            throw WorkerFailure.remote("麦克风需要 44.1/48/96 kHz 浮点输入格式。")
        }
        samples.prepare(rate: format.mSampleRate)
        let retained = Unmanaged.passRetained(samples).toOpaque()
        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(selected.0, microphoneIOProc, retained, &created)
        guard status == noErr, let created else {
            Unmanaged<MicrophoneSamples>.fromOpaque(retained).release()
            throw WorkerFailure.remote("无法准备麦克风录音（\(status)）")
        }
        device = selected.0; io = created; context = retained
        let started = AudioDeviceStart(selected.0, created)
        guard started == noErr else { stop(); throw WorkerFailure.remote("无法启动麦克风（\(started)）") }
    }
    func stop() {
        guard let device, let io else { return }
        let stopped = AudioDeviceStop(device, io)
        let destroyed = AudioDeviceDestroyIOProcID(device, io)
        cleanupConfirmed = stopped == noErr && destroyed == noErr
        if destroyed == noErr, let context { Unmanaged<MicrophoneSamples>.fromOpaque(context).release(); self.context = nil }
        self.device = nil; self.io = nil
    }
    func finish(to url: URL) throws -> (rate: Double, firstNS: Double) {
        stop()
        guard cleanupConfirmed else { throw WorkerFailure.cleanupUnconfirmed }
        return try samples.write(to: url)
    }
}
