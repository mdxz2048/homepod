import Foundation

@main struct CalibrationSignalChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for rate in [44100, 48000] {
            for code in [0] {
                let samples = CalibrationSignal.samples(rate: Double(rate), code: code)
                precondition(samples.count == rate * 9)
                precondition(samples.allSatisfy { $0.isFinite && abs($0) <= 0.501 })
                precondition(abs(samples.map { abs($0) }.max()! - 0.5) < 1e-5)
                try samples.withUnsafeBytes { buffer in
                    try Data(buffer).write(to: directory.appendingPathComponent("\(rate)-\(code).f32"))
                }
            }
        }
        print("PASS: continuous signal duration/amplitude and cross-language fixtures")
    }
}
