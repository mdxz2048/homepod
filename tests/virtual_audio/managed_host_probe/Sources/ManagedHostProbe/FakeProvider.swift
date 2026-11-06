import Foundation
@testable import VirtualAudioInput
import VirtualCaptureHostSupport

/// Deterministic non-HAL capture backend used by the managed-host integration
/// gate. It intentionally exercises the real 013 controller against a provider
/// whose clock, sequence and PCM content are fully known and bounded:
///
/// * 480-frame, 8-channel, 48 kHz blocks on a ~10 ms cadence
/// * one channel-distinct constant per 7.1 slot, all inside [-0.8, 0.8]
/// * monotonic hostTime/sampleTime and exactly increasing callbackSequence
/// * timestampFlags = 3 and nowFlags = 3, the same valid clock the real
///   device tap produces for capture blocks
///
/// No HAL, process tap, device, permission or network API is touched here.
@MainActor
final class FakeProvider: VirtualCaptureProvider {
    static let framesPerBlock = 480
    static let channels = 8
    static let sampleRate = 48_000.0

    /// 7.1 canonical order: FL, FR, FC, LFE, SL, SR, BL, BR.
    /// FC is deliberately the strongest positive constant ("dialogue in the
    /// centre") so the downmix checks can prove centre content is retained.
    static let channelValues: [Float] = [
        0.10, -0.20, 0.70, -0.40, 0.30, -0.30, 0.50, -0.50,
    ]

    private let clock = ContinuousClock()
    private let cadence = Duration.milliseconds(10)
    private var started = false
    private var nextDue: ContinuousClock.Instant?
    private var nextSequence: UInt64 = 0
    private var previousHostTime: UInt64?

    func start(deviceUID: String) throws -> DeviceTapDescriptor {
        guard !started else {
            throw FakeProviderError.alreadyStarted
        }
        started = true
        return DeviceTapDescriptor(
            deviceUID: deviceUID,
            streamIndex: 0,
            sampleRate: Self.sampleRate,
            channels: UInt32(Self.channels),
            bytesPerFrame: UInt32(Self.channels * MemoryLayout<Float>.size),
            formatFlags: 0
        )
    }

    /// Non-blocking: returns nil until the next 10 ms grid point, mirroring
    /// the real tap ring which reports no complete block between callbacks.
    /// Returning nil lets the controller's 2 ms sleep yield the main actor so
    /// stdin commands (including stop) stay responsive.
    func readBlock() throws -> CapturedPCMBlock? {
        guard started else { return nil }
        let now = clock.now
        if let due = nextDue, now < due { return nil }
        nextDue = (nextDue ?? now).advanced(by: cadence)

        let hostTime = DispatchTime.now().uptimeNanoseconds
        if let previous = previousHostTime {
            guard hostTime > previous else {
                throw FakeProviderError.clockRegressed
            }
        }
        previousHostTime = hostTime

        var samples = [Float]()
        samples.reserveCapacity(Self.framesPerBlock * Self.channels)
        for _ in 0..<Self.framesPerBlock {
            samples.append(contentsOf: Self.channelValues)
        }

        let sequence = nextSequence
        nextSequence += 1
        let sampleTime = Double(hostTime)
        return CapturedPCMBlock(
            frames: Self.framesPerBlock,
            channels: Self.channels,
            samples: samples,
            hostTime: hostTime,
            sampleTime: sampleTime,
            timestampFlags: 3,
            callbackSequence: sequence,
            droppedBefore: 0,
            nowHostTime: hostTime + 1,
            nowSampleTime: sampleTime,
            nowFlags: 3
        )
    }

    func stop() throws {
        started = false
    }
}

private enum FakeProviderError: Error, CustomStringConvertible {
    case alreadyStarted
    case clockRegressed

    var description: String {
        switch self {
        case .alreadyStarted: "fake provider already started"
        case .clockRegressed: "fake provider host clock regressed"
        }
    }
}
