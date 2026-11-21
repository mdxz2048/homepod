import AVFoundation
import Foundation

/// Playback waveform loaded from the same external WAV files the Python
/// analyzer reads. Nothing here synthesizes the measurement signal.
enum ProbeKind: String, CaseIterable, Identifiable {
    case sweep, linear, pink
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sweep: "标准对数扫频"
        case .linear: "标准线性扫频"
        case .pink: "标准粉红噪声"
        }
    }
    var detail: String {
        switch self {
        case .sweep: "20 Hz–18 kHz，MIT 测试信号，逆滤波直接求脉冲"
        case .linear: "全频段时间分辨率均匀，适合对比房间反射"
        case .pink: "公有领域噪声，低频能量更足，备用测量"
        }
    }
    var assetName: String {
        switch self {
        case .sweep: "log-sweep"
        case .linear: "linear-sweep"
        case .pink: "pink-noise"
        }
    }
}

enum CalibrationSignal {
    static let duration = 9.0
    static let start = 1.0
    static let repeats = 6
    static let gap = 0.6
    static let period = 1.6
    static let windowCount = repeats
    static let peak = 0.5

    static func samples(rate: Double, code: Int, kind: ProbeKind = .sweep) -> [Float] {
        let rate = Int(rate.rounded())
        precondition([44100, 48000].contains(rate), "probe asset rate must be 44.1 or 48 kHz")
        let units = (0..<repeats).map { unitSamples(rate: rate, kind: kind, index: $0) }
        var output: [Float] = []
        output.reserveCapacity(Int(Double(rate) * duration))
        let silence = [Float](repeating: 0, count: Int(Double(rate) * gap))
        for (index, unit) in units.enumerated() {
            output.append(contentsOf: unit)
            if index != units.count - 1 { output.append(contentsOf: silence) }
        }
        precondition(output.count == Int(Double(rate) * duration))
        return output
    }

    private static func unitSamples(rate: Int, kind: ProbeKind, index: Int) -> [Float] {
        let name = "\(kind.assetName)-\(rate)"
        let url = resourceURL(name: name)
        guard let url, let file = try? AVAudioFile(forReading: url) else {
            preconditionFailure("missing bundled probe asset \(name).wav")
        }
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            preconditionFailure("cannot allocate probe asset \(name).wav")
        }
        do { try file.read(into: buffer) }
        catch { preconditionFailure("cannot read probe asset \(name).wav: \(error)") }
        guard let data = buffer.floatChannelData?[0] else {
            preconditionFailure("probe asset \(name).wav is not mono float PCM")
        }
        let count = Int(buffer.frameLength)
        let period = rate
        let offset: Int
        if kind == .pink { offset = index * period } else { offset = 0 }
        guard offset + period <= count else { preconditionFailure("probe asset \(name).wav is too short") }
        var values = (0..<period).map { Double(data[offset + $0]) }
        taper(&values, rate: rate)
        var maximum = 0.0
        for value in values { maximum = max(maximum, abs(value)) }
        precondition(maximum > 1e-9, "probe asset \(name).wav is silent")
        let scale = peak / maximum
        return values.map { Float($0 * scale) }
    }

    private static func taper(_ values: inout [Double], rate: Int) {
        let n = max(1, Int((0.01 * Double(rate)).rounded()))
        guard values.count >= 2 * n else { return }
        for index in 0..<n {
            let edge = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(n))
            values[index] *= edge
            values[values.count - 1 - index] *= edge
        }
    }

    private static func resourceURL(name: String) -> URL? {
        if let directory = ProcessInfo.processInfo.environment["HOMEPODFLOW_PROBE_ASSETS"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("\(name).wav")
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return Bundle.main.url(forResource: name, withExtension: "wav")
    }
}
