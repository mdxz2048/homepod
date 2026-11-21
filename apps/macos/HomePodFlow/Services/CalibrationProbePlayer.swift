import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Generates only into the exact Flow device, never the Mac's default output.
/// The reference is the callback's PCM injection time, so measurement includes
/// virtual output, capture, conversion, IPC, routing, AirPlay and the room.
private final class ProbeRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var waves: [[Float]] = []
    private var cursor = -1
    private var rate = 44100.0
    private var firstNS: Double?
    private var armed = false
    private var invalidClock = false
    private var clockLeadMS: Double?
    func arm(rate: Double, channels: Int, kind: ProbeKind) {
        // Asset decoding never holds the render lock while IO is running.
        // Two short beeps before the probe and one at the end let anyone in the
        // room tell playback apart from silence without listening for the probe.
        func beep(_ count: Int, delay: Double, frequency: Double) -> [Float] {
            var tone = [Float](repeating: 0, count: count)
            let length = Int(rate * 0.075)
            let start = Int(rate * delay)
            for index in 0..<length where start + index < count {
                let t = Double(index) / rate
                let fade = sin(Double.pi * min(1, Double(index) / Double(length)))
                tone[start + index] = Float(0.18 * fade * sin(2 * Double.pi * frequency * t))
            }
            return tone
        }
        let leadCount = Int((rate * CalibrationSignal.start).rounded())
        let lead = beep(leadCount, delay: 0.12, frequency: 1320)
        let tailLead = beep(leadCount, delay: 0.30, frequency: 1320)
        var leadSignal = lead
        for index in 0..<leadCount { leadSignal[index] += tailLead[index] }
        let body = CalibrationSignal.samples(rate: rate, code: 0, kind: kind)
        let tail = beep(Int(rate * 0.5), delay: 0.05, frequency: 880)
        let complete = leadSignal + body + tail
        let waves = (0..<channels).map { _ in complete }
        lock.lock(); defer { lock.unlock() }
        self.rate = rate; firstNS = nil; cursor = -Int(rate)
        armed = false; invalidClock = false; self.waves = waves
    }
    func silence() { lock.lock(); defer { lock.unlock() }; armed = false; firstNS = nil }

    func trigger() { lock.lock(); defer { lock.unlock() }; cursor = -Int(rate); firstNS = nil; armed = true }
    func render(frames: Int, buffers: UnsafeMutablePointer<AudioBufferList>, timestamp: AudioTimeStamp) {
        lock.lock(); defer { lock.unlock() }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for buffer in list {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard timestamp.mFlags.contains(.hostTimeValid) else { invalidClock = true; return }
        let now = AVAudioTime.seconds(forHostTime: timestamp.mHostTime) * 1e9
        clockLeadMS = (now - Double(DispatchTime.now().uptimeNanoseconds)) / 1e6
        guard armed else { return }
        for frame in 0..<frames {
            if cursor == 0 { firstNS = now + Double(frame) / rate * 1e9 }
            for (channel, buffer) in list.enumerated() where channel < waves.count {
                guard cursor >= 0, cursor < waves[channel].count, let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = waves[channel][cursor]
            }
            cursor += 1
        }
    }
    func clockLead() -> Double? { lock.lock(); defer { lock.unlock() }; return clockLeadMS }
    func clockFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return invalidClock }
    func origin() -> Double? { lock.lock(); defer { lock.unlock() }; return firstNS }
}

@MainActor final class CalibrationProbePlayer {
    private var engine: AVAudioEngine?
    private let state = ProbeRenderState()
    private(set) var rate = 44100.0
    var injectionNS: Double? { state.origin() }
    var clockFailed: Bool { state.clockFailed() }
    var clockLeadMS: Double? { state.clockLead() }

    func start(channels: Int, kind: ProbeKind) throws {
        guard (1...8).contains(channels) else { throw WorkerFailure.remote("测试音箱数量无效") }
        if let engine {
            state.arm(rate: rate, channels: channels, kind: kind)
            if !engine.isRunning { try engine.start() }
            return
        }
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size) == noErr else {
            throw WorkerFailure.remote("无法读取音频设备")
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices) == noErr else {
            throw WorkerFailure.remote("无法读取音频设备列表")
        }
        let selected = devices.first { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, $0)
            }
            guard status == noErr, let string = value?.takeRetainedValue() else { return false }
            return string as String == FlowVirtualDevice.uid
        }
        guard var device = selected else { throw WorkerFailure.remote("需要先安装并加载 Flow 音频组件") }
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw WorkerFailure.remote("测试输出不可用") }
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw WorkerFailure.remote("无法将测试音绑定到 Flow 声卡（\(result)）") }
        var rateProperty = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rateBytes = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &rateProperty, 0, nil, &rateBytes, &rate) == noErr else {
            throw WorkerFailure.remote("无法读取 Flow 声卡采样率")
        }
        guard [44100.0, 48000.0].contains(rate),
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AudioUnit_7_1) else {
            throw WorkerFailure.remote("Flow 测试输出必须是 44.1/48 kHz、8 声道")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        let render = state
        let source = AVAudioSourceNode(format: format) { @Sendable _, timestamp, frames, buffers in
            render.render(frames: Int(frames), buffers: buffers, timestamp: timestamp.pointee)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: format)
        self.engine = engine
        engine.prepare()
        state.arm(rate: rate, channels: channels, kind: kind)
        do { try engine.start() }
        catch { stop(); throw error }
    }
    func beginProbe() { state.trigger() }
    /// Keep the same HAL client alive between speakers; only rearm after the
    /// next worker session confirms its capture clock. No previous tone leaks.
    func silence() { state.silence() }
    func stop() { state.silence(); engine?.stop(); engine = nil }
}
