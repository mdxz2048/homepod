import Foundation
import VirtualAudioInput

private struct CaptureReport: Encodable {
    let deviceUID: String
    let channels: UInt32
    let sampleRate: Double
    let bytesPerFrame: UInt32
    let blocks: Int
    let frames: Int
    let nonzeroSamples: Int
    let rms: Double
    let peak: Double
    let channelRms: [Double]
    let channelPeak: [Double]
    let channelNonzero: [Int]
    let droppedBefore: UInt64
    let firstHostTime: UInt64
    let lastHostTime: UInt64
    let firstSampleTime: Double
    let lastSampleTime: Double
    let timestampFlags: UInt32
    let tapVerified: Bool
    let note: String
}

@main
struct VirtualAudioInputCLI {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--capture" {
            var seconds = 3.0
            var reportPath: String?
            var deviceUID = VirtualIdentity.deviceUID
            if let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count,
               let value = Double(arguments[index + 1]), value.isFinite, (1...10).contains(value) {
                seconds = value
            }
            if let index = arguments.firstIndex(of: "--report"), index + 1 < arguments.count {
                let value = arguments[index + 1]
                guard value.hasPrefix("/") else {
                    FileHandle.standardError.write(Data("report path must be absolute\n".utf8))
                    exit(2)
                }
                reportPath = value
            }
            if let index = arguments.firstIndex(of: "--device-uid"), index + 1 < arguments.count {
                deviceUID = arguments[index + 1]
            }
            let capture = DeviceTapCapture()
            do {
                let descriptor = try capture.start(deviceUID: deviceUID)
                defer { try? capture.stop() }
                var blocks = 0, frames = 0, nonzero = 0
                var sumSquares = 0.0, peak = 0.0
                var channelSums = [Double](repeating: 0, count: Int(descriptor.channels))
                var channelPeaks = [Double](repeating: 0, count: Int(descriptor.channels))
                var channelNonzero = [Int](repeating: 0, count: Int(descriptor.channels))
                var dropped: UInt64 = 0
                var firstHost: UInt64 = 0, lastHost: UInt64 = 0
                var firstSample = 0.0, lastSample = 0.0
                var flags: UInt32 = 0
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if let block = try capture.readBlock() {
                        blocks += 1
                        frames += block.frames
                        dropped = max(dropped, block.droppedBefore)
                        if firstHost == 0 { firstHost = block.hostTime; firstSample = block.sampleTime }
                        lastHost = block.hostTime; lastSample = block.sampleTime; flags = block.timestampFlags
                        for (index, sample) in block.samples.enumerated() {
                            let magnitude = abs(sample)
                            if magnitude > 1e-7 { nonzero += 1 }
                            peak = max(peak, Double(magnitude))
                            sumSquares += Double(sample) * Double(sample)
                            let channel = index % Int(descriptor.channels)
                            channelSums[channel] += Double(sample) * Double(sample)
                            channelPeaks[channel] = max(channelPeaks[channel], Double(magnitude))
                            if magnitude > 1e-7 { channelNonzero[channel] += 1 }
                        }
                    } else {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                }
                let rms = frames > 0 ? sqrt(sumSquares / Double(frames * Int(descriptor.channels))) : 0
                let channelRms = channelSums.map { frames > 0 ? sqrt($0 / Double(frames)) : 0 }
                let report = CaptureReport(deviceUID: descriptor.deviceUID, channels: descriptor.channels,
                    sampleRate: descriptor.sampleRate, bytesPerFrame: descriptor.bytesPerFrame,
                    blocks: blocks, frames: frames, nonzeroSamples: nonzero, rms: rms, peak: peak,
                    channelRms: channelRms, channelPeak: channelPeaks, channelNonzero: channelNonzero,
                    droppedBefore: dropped, firstHostTime: firstHost, lastHostTime: lastHost,
                    firstSampleTime: firstSample, lastSampleTime: lastSample, timestampFlags: flags,
                    tapVerified: blocks > 0 && nonzero > 0,
                    note: blocks == 0 || nonzero == 0
                        ? "silent_or_permission_unconfirmed: this process may lack System Audio Recording permission; do not treat as driver failure"
                        : "bounded device-tap capture; not an acoustic or browser A/V measurement")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                if let reportPath {
                    try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                }
                print(String(decoding: data, as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
            return
        }
        guard arguments == ["--discover"] else {
            print("""
            virtual-audio-input --discover
            virtual-audio-input --capture [--seconds 1...10] [--device-uid UID] [--report /absolute/path.json]
            Read-only HAL discovery or an explicit bounded device-tap capture.
            Capture requires a TCC-authorized app identity; a CLI may return silence.
            No installation, output switching, or automatic playback.
            """)
            if !arguments.isEmpty && arguments != ["--help"] { exit(2) }
            return
        }
        do {
            let result = try VirtualInputClient(backend: HALVirtualDeviceBackend()).discover()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
