import Foundation
@testable import VirtualAudioInput

let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
let layouts: [(String, String, Int)] = [
    ("mono", "mono", 1), ("stereo", "stereo", 2), ("3_0", "surround30", 3),
    ("4_0", "quad40", 4), ("5_1_side", "surround51s", 6),
    ("5_1_back", "surround51b", 6), ("7_1", "surround71", 8)
]
var manifest: [[String: Any]] = []
for (layout, slug, channels) in layouts {
    for rate in [44100.0, 48000.0] {
        let session = "AB12CD34-AB12-4D34-AB12-AB12CD34EF56"
        let converter = try VirtualPCMResampler(sourceRate: rate, channels: channels)
        let writer = try VirtualHPCMEncoder(session: session, startID: "transport-check",
            deviceUID: "com.homepodflow.virtual-audio.\(slug).v1", layout: layout, sourceRate: rate,
            leadingFrames: Int(converter.leadingFrames), trailingFrames: Int(converter.trailingFrames))
        var stream = Data(), totalFrames = 0, packets = 0
        for index in 0..<32 {
            let frames = 512, start = UInt64(index * frames)
            let samples = (0..<(frames * channels)).map { Float($0 % channels + 1) * 0.05 }
            let host = 1_000_000_000 + UInt64(Double(start) * 1_000_000_000 / rate)
            let block = CapturedPCMBlock(frames: frames, channels: channels, samples: samples,
                hostTime: host, sampleTime: Double(start), timestampFlags: 3,
                callbackSequence: UInt64(index), droppedBefore: 0,
                nowHostTime: host + 100, nowSampleTime: Double(start), nowFlags: 3)
            let source = VirtualHPCMSource(block: block, frameStart: start,
                timebaseNumerator: 1, timebaseDenominator: 1)
            for packet in try converter.convert(samples: samples, frames: frames) {
                stream.append(try writer.encodePCM(frames: packet.frames, payload: packet.bytes, source: source))
                totalFrames += packet.frames; packets += 1
            }
        }
        let name = "\(layout)-\(Int(rate)).hpcm"
        try stream.write(to: target.appendingPathComponent(name))
        manifest.append(["file": name, "layout": layout, "channels": channels,
            "sourceRate": Int(rate), "packets": packets, "frames": totalFrames,
            "session": session, "startID": "transport-check", "inputFrames": 32 * 512])
    }
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: target.appendingPathComponent("manifest.json"))
print("Generated \(manifest.count) Swift resampler -> HPCM v2 fixtures")
