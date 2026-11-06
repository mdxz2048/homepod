import Foundation
import CoreAudio
import ProcessTapCapture
import Darwin

struct TimestampSummary: Encodable {
    let sequence: UInt64
    let droppedBefore: UInt64
    let hostTime: UInt64
    let sampleTime: String
    let flags: UInt32
    let nowHostTime: UInt64
    let nowSampleTime: String
    let nowFlags: UInt32
    init(_ block: CapturedPCMBlock) {
        sequence = block.callbackSequence; droppedBefore = block.droppedBlocksBefore
        hostTime = block.hostTime; sampleTime = String(block.sampleTime); flags = block.timestampFlags
        nowHostTime = block.nowTimestamp.hostTime; nowSampleTime = String(block.nowTimestamp.sampleTime)
        nowFlags = block.nowTimestamp.flags
    }
}
struct FormatSummary: Encodable {
    let sampleRate: Double
    let channels: Int
    let formatID: UInt32
    let flags: UInt32
    let bitsPerChannel: UInt32
    let bytesPerFrame: UInt32
    let interleaved: Bool
    init(_ value: CaptureFormat) {
        sampleRate = value.sampleRate; channels = value.channels; formatID = value.asbd.mFormatID
        flags = value.asbd.mFormatFlags; bitsPerChannel = value.asbd.mBitsPerChannel
        bytesPerFrame = value.asbd.mBytesPerFrame; interleaved = !value.isNonInterleaved
    }
}
struct ProbeReport: Encodable {
    var captureRequested = true
    var captureVerified = false
    var acousticSyncVerified = false
    var permissionStatus = "not_inferred"
    var sessionID: UUID?
    var format: FormatSummary?
    var frames = 0
    var blocks = 0
    var nonzeroSamples = 0
    var peak: Float = 0
    var rms: Double = 0
    var droppedBlocks: UInt64 = 0
    var gapBlocks = 0
    var timestampsValid = true
    var first: TimestampSummary?
    var last: TimestampSummary?
    var timebaseNumerator: UInt32?
    var timebaseDenominator: UInt32?
    var cleanupComplete = false
    var errors: [String] = []
}

@main struct TapCaptureProbe {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--capture"), !arguments.contains("--help") else {
            print("""
            tap-capture-probe (macOS 14.2+)
              --help                       Show help; never captures
              --capture --seconds 5         Explicit finite capture (1...10s)
              --pid PID                    Include only selected PID (repeatable)
              --exclude-pid PID            Exclude sender/App PID (repeatable)
              --output /absolute/file.wav   Optional Float32 WAV (never overwritten)
            Default selection after --capture: all processes except this host and exclusions.
            Capture requires the bundled Info.plist and macOS system-audio permission.
            This probe never plays audio, changes output routing/volume, or starts AirPlay.
            """)
            return
        }
        var seconds = 5.0
        var pids: [Int32] = [], exclusions: [Int32] = []
        var output: URL?
        do {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--capture" { index += 1; continue }
                guard index + 1 < arguments.count else { throw CaptureError.invalidConfiguration("Missing argument value") }
                let value = arguments[index + 1]
                switch argument {
                case "--seconds":
                    guard let parsed = Double(value), parsed.isFinite, (1...10).contains(parsed) else {
                        throw CaptureError.invalidConfiguration("Capture duration must be 1...10 seconds")
                    }
                    seconds = parsed
                case "--pid", "--exclude-pid":
                    guard let parsed = Int32(value), parsed > 0 else { throw CaptureError.invalidConfiguration("Invalid PID") }
                    if argument == "--pid" { pids.append(parsed) } else { exclusions.append(parsed) }
                case "--output":
                    guard value.hasPrefix("/") else { throw CaptureError.invalidConfiguration("Output path must be absolute") }
                    output = URL(fileURLWithPath: value)
                default: throw CaptureError.invalidConfiguration("Unknown argument: \(argument)")
                }
                index += 2
            }
            guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String,
                  !usage.isEmpty else {
                throw CaptureError.invalidConfiguration("Use scripts/package-probe.sh to create the permission-capable app bundle first")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(2)
        }
        let source = CaptureSource()
        var report = ProbeReport()
        var writer: FloatWAVWriter?
        var sumSquares = 0.0
        var sampleCount = 0
        var previousSequence: UInt64?
        var previousDropped: UInt64 = 0
        let configuration = CaptureConfiguration(selection: pids.isEmpty ? .allExceptCurrentProcess : .processes(pids),
            excludedProcessIDs: exclusions)
        let captureTask = Task { @MainActor in
            try await source.withCapture(configuration: configuration) { source in
                guard let format = source.format else { throw CaptureError.unsupportedFormat }
                report.format = FormatSummary(format); report.sessionID = source.sessionID
                if let output { writer = try FloatWAVWriter(url: output, format: format) }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(seconds))
                while clock.now < deadline {
                    try Task.checkCancellation()
                    if let block = try source.readBlock() {
                        let samples = try block.interleavedFloat32()
                        report.frames += block.frames; report.blocks += 1
                        if report.first == nil { report.first = TimestampSummary(block) }
                        report.last = TimestampSummary(block)
                        report.timebaseNumerator = block.timebase.numerator
                        report.timebaseDenominator = block.timebase.denominator
                        let nowSampleConsistent = block.nowTimestamp.flags & AudioTimeStampFlags.sampleTimeValid.rawValue == 0
                            || block.nowTimestamp.sampleTimeIsValid
                        report.timestampsValid = report.timestampsValid && block.hostTimeIsValid && block.sampleTimeIsValid
                            && block.nowTimestamp.hostTimeIsValid && nowSampleConsistent
                        if block.droppedBlocksBefore > previousDropped ||
                           (previousSequence.map { block.callbackSequence != $0 + 1 } ?? false) { report.gapBlocks += 1 }
                        previousSequence = block.callbackSequence; previousDropped = block.droppedBlocksBefore
                        for value in samples {
                            report.peak = max(report.peak, abs(value))
                            if abs(value) > 0.0000001 { report.nonzeroSamples += 1 }
                            sumSquares += Double(value) * Double(value)
                        }
                        sampleCount += samples.count
                        try writer?.append(samples)
                    } else { try await Task.sleep(for: .milliseconds(2)) }
                }
            }
        }
        // Only the explicitly invoked probe changes its own signal disposition.
        // Cancellation returns through withCapture, so Ctrl-C can still clean up.
        let signalSources: [any DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { captureTask.cancel() }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }
        do { try await captureTask.value }
        catch { report.errors.append(error.localizedDescription) }
        do { try writer?.finish() } catch { report.errors.append(error.localizedDescription) }
        report.cleanupComplete = source.state == .idle
        report.droppedBlocks = source.droppedBlocks
        report.rms = sampleCount == 0 ? 0 : sqrt(sumSquares / Double(sampleCount))
        report.timestampsValid = report.timestampsValid && report.blocks > 0
        report.captureVerified = report.frames > 0 && report.nonzeroSamples > 0 && report.timestampsValid
            && report.droppedBlocks == 0 && report.gapBlocks == 0 && report.cleanupComplete && report.errors.isEmpty
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data(("Cannot encode capture report: \(error.localizedDescription)\n").utf8))
            exit(4)
        }
        exit(report.captureVerified ? 0 : 3)
    }
}

/// Optional consumer-side sink; no FileHandle operation is performed in IOProc.
final class FloatWAVWriter {
    private let file: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private var bytes: UInt32 = 0
    private var finished = false
    init(url: URL, format: CaptureFormat) throws {
        guard format.sampleRate.rounded() == format.sampleRate, format.sampleRate <= 384000 else {
            throw CaptureError.invalidConfiguration("WAV sample rate cannot be represented")
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw CaptureError.invalidConfiguration("Cannot exclusively create output file (errno \(errno))")
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        sampleRate = UInt32(format.sampleRate); channels = UInt16(format.channels)
        try file.write(contentsOf: Data(count: 44))
    }
    func append(_ samples: [Float]) throws {
        let count = samples.count * 4
        guard UInt64(bytes) + UInt64(count) <= UInt64(UInt32.max) - 36 else {
            throw CaptureError.invalidConfiguration("WAV size limit exceeded")
        }
        try samples.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
        bytes += UInt32(count)
    }
    func finish() throws {
        guard !finished else { return }
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        text("RIFF"); integer(bytes + 36); text("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(3)); integer(channels); integer(sampleRate)
        integer(sampleRate * UInt32(channels) * 4); integer(channels * 4); integer(UInt16(32))
        text("data"); integer(bytes)
        try file.seek(toOffset: 0); try file.write(contentsOf: header)
        try file.close(); finished = true
    }
}
