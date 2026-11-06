import Foundation

@MainActor
public protocol VirtualDeviceBackend {
    func discover() throws -> DiscoveredVirtualDevice
    func setLatencyFrames(_ frames: UInt32) throws
}

@MainActor
public struct VirtualInputClient {
    private let backend: any VirtualDeviceBackend
    public init(backend: any VirtualDeviceBackend) { self.backend = backend }

    public func discover() throws -> DiscoveredVirtualDevice { try backend.discover() }

    /// This is an explicit write API, not invoked by initialization or discovery.
    /// The driver performs its own atomic stopped-only check to close the query/write race.
    public func setLatencyFrames(_ frames: UInt32, expectedRevision: UInt64) throws -> DiscoveredVirtualDevice {
        let before = try backend.discover()
        guard before.descriptor.latency.revision == expectedRevision else { throw InputFailure.latencyRevisionChanged }
        guard !before.running else { throw InputFailure.deviceBusy }
        guard Double(frames) <= 10 * before.descriptor.capturedFormat.sampleRate else {
            throw InputFailure.invalidProperty("latency outside 0...10 seconds")
        }
        try backend.setLatencyFrames(frames)
        let after = try backend.discover()
        let expected = frames == before.descriptor.latency.reportedFrames
            ? before.descriptor.latency.revision : before.descriptor.latency.revision &+ 1
        guard after.descriptor.latency.reportedFrames == frames,
              after.descriptor.latency.sampleRate == before.descriptor.latency.sampleRate,
              after.descriptor.latency.revision == expected else { throw InputFailure.latencyRevisionChanged }
        // A confirmed property write still does not establish calibration or readiness.
        return after
    }

    public func startCapture() throws -> Never { throw InputFailure.capturePathUnverified }
}
