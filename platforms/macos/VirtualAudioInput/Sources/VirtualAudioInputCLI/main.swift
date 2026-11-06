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
            if let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count,
               let value = Double(arguments[index + 1]), value.isFinite, (1...10).contains(value) {
                seconds = value
            }
            let capture = DeviceTapCapture()
            do {
                let descriptor = try capture.start()
                defer { try? capture.stop() }
                var blocks = 0, frames = 0, nonzero = 0
                var sumSquares = 0.0, peak = 0.0
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
                        for sample in block.samples {
                            let magnitude = abs(sample)
                            if magnitude > 1e-7 { nonzero += 1 }
                            peak = max(peak, Double(magnitude))
                            sumSquares += Double(sample) * Double(sample)
                        }
                    } else {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                }
                let rms = frames > 0 ? sqrt(sumSquares / Double(frames * Int(descriptor.channels))) : 0
                let report = CaptureReport(deviceUID: descriptor.deviceUID, channels: descriptor.channels,
                    sampleRate: descriptor.sampleRate, bytesPerFrame: descriptor.bytesPerFrame,
                    blocks: blocks, frames: frames, nonzeroSamples: nonzero, rms: rms, peak: peak,
                    droppedBefore: dropped, firstHostTime: firstHost, lastHostTime: lastHost,
                    firstSampleTime: firstSample, lastSampleTime: lastSample, timestampFlags: flags,
                    tapVerified: blocks > 0 && nonzero > 0,
                    note: blocks == 0 || nonzero == 0
                        ? "silent_or_permission_unconfirmed: this process may lack System Audio Recording permission; do not treat as driver failure"
                        : "bounded device-tap capture; not an acoustic or browser A/V measurement")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
            return
        }
        guard arguments == ["--discover"] else {
            print("""
            virtual-audio-input --discover
            virtual-audio-input --capture [--seconds 1...10]
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
