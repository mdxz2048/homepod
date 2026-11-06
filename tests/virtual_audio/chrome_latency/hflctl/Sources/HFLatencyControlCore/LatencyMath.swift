/// Pure latency arithmetic shared by the hflctl CLI and its offline tests.
///
/// The driver contract requires, per device:
///  - `hfla` is CFNumber(UInt32): stream latency frames, `0...10*rate`.
///  - Writing the current value is idempotent (revision does not change);
///    a changed value increments the monotonic `hflr` revision by exactly one.
///  - `kAudioStreamPropertyLatency` reports the `hfla` frame count on both
///    global/main and output/main.
///
/// The user-facing control unit of this tool is milliseconds in `0...3000`.

public enum LatencyMathError: Error, Equatable, CustomStringConvertible {
    case millisecondsOutOfRange(Int)
    case unsupportedRate(Double)

    public var description: String {
        switch self {
        case .millisecondsOutOfRange(let value):
            return "milliseconds_out_of_range: \(value) (allowed 0...\(LatencyMath.maxMilliseconds))"
        case .unsupportedRate(let rate):
            return "unsupported_rate: \(rate) (allowed 44100 or 48000)"
        }
    }
}

public struct LatencyPlan: Equatable {
    public let milliseconds: Int
    public let frames: UInt32
    public let sampleRate: Double

    public init(milliseconds: Int, frames: UInt32, sampleRate: Double) {
        self.milliseconds = milliseconds
        self.frames = frames
        self.sampleRate = sampleRate
    }
}

public enum LatencyMath {
    public static let minMilliseconds = 0
    public static let maxMilliseconds = 3000
    public static let allowedSampleRates: Set<Double> = [44_100, 48_000]

    public static func validateMilliseconds(_ value: Int) throws {
        guard value >= minMilliseconds, value <= maxMilliseconds else {
            throw LatencyMathError.millisecondsOutOfRange(value)
        }
    }

    public static func validateRate(_ rate: Double) throws {
        guard rate.isFinite, allowedSampleRates.contains(rate) else {
            throw LatencyMathError.unsupportedRate(rate)
        }
    }

    /// Contract ceiling: 10 seconds expressed in frames at the current rate.
    public static func maxLatencyFrames(rate: Double) -> UInt32 {
        return UInt32(10.0 * rate)
    }

    public static func frames(milliseconds: Int, rate: Double) throws -> LatencyPlan {
        try validateMilliseconds(milliseconds)
        try validateRate(rate)
        let raw = (Double(milliseconds) * rate) / 1000.0
        let rounded = raw.rounded()
        guard rounded >= 0, rounded <= Double(maxLatencyFrames(rate: rate)) else {
            throw LatencyMathError.millisecondsOutOfRange(milliseconds)
        }
        return LatencyPlan(milliseconds: milliseconds, frames: UInt32(rounded), sampleRate: rate)
    }

    public static func milliseconds(frames: UInt32, rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return Double(frames) * 1000.0 / rate
    }

    /// A changed write increments the revision by one; an idempotent write of
    /// the current value leaves it unchanged.
    public static func expectedRevision(previousRevision: UInt64,
                                        previousFrames: UInt32,
                                        requestedFrames: UInt32) -> UInt64 {
        return previousRevision &+ (previousFrames == requestedFrames ? 0 : 1)
    }
}
