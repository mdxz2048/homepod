import Foundation

public enum InputFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case driverUnavailable
    case unsupportedFormat(String)
    case deviceBusy
    case capturePathUnverified
    case latencyRevisionChanged
    case recoveryHelperUnavailable
    case userOverride
    case invalidLease
    case outputRestoreFailed
    case hal(operation: String, status: Int32)
    case invalidProperty(String)

    public var description: String {
        switch self {
        case .driverUnavailable: "driver_unavailable"
        case .unsupportedFormat(let detail): "unsupported_format: \(detail)"
        case .deviceBusy: "device_busy"
        case .capturePathUnverified: "capture_path_unverified"
        case .latencyRevisionChanged: "latency_revision_changed"
        case .recoveryHelperUnavailable: "recovery_helper_unavailable"
        case .userOverride: "user_override"
        case .invalidLease: "invalid_lease"
        case .outputRestoreFailed: "output_restore_failed"
        case .hal(let operation, let status): "hal_error: \(operation) (\(status))"
        case .invalidProperty(let detail): "invalid_property: \(detail)"
        }
    }
}

public enum ChannelLabel: String, Codable, Sendable { case FL, FR, FC, LFE, SL, SR, BL, BR, unknown }
public enum Packing: String, Codable, Sendable { case interleaved, planar }
public enum Provenance: String, Codable, Sendable { case deviceMix = "device_mix", stereoMixdown = "stereo_mixdown", discretePCM = "discrete_pcm", unknown }
public enum Calibration: String, Codable, Sendable { case uncalibrated, planned, measured }
public enum AudioCapturePermission: String, Codable, Sendable { case unknown, notDetermined, allowed, denied }

public struct InputFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var sampleType: String = "f32"
    public var packing: Packing
    public var channelCount: UInt32
    public var labels: [ChannelLabel]
    public var layoutAuthority: String
    public var layoutVerified: Bool

    public init(sampleRate: Double, packing: Packing, channelCount: UInt32,
                labels: [ChannelLabel], layoutAuthority: String, layoutVerified: Bool) throws {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0, channelCount <= 64,
              labels.count == Int(channelCount) else { throw InputFailure.unsupportedFormat("invalid format or labels") }
        self.sampleRate = sampleRate; self.packing = packing; self.channelCount = channelCount
        self.labels = labels; self.layoutAuthority = layoutAuthority; self.layoutVerified = layoutVerified
    }
}

public struct LatencyDescriptor: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var reportedFrames: UInt32
    public var sampleRate: Double
    public var calibration: Calibration

    public init(revision: UInt64, reportedFrames: UInt32, sampleRate: Double, calibration: Calibration) {
        self.revision = revision; self.reportedFrames = reportedFrames
        self.sampleRate = sampleRate; self.calibration = calibration
    }
}

public struct InputDescriptor: Codable, Equatable, Sendable {
    public private(set) var schemaVersion: Int = 1
    public var backend: String
    public var deviceUID: String?
    public var streamIndex: UInt32?
    public var capturedFormat: InputFormat
    public var decoderReportedFormat: InputFormat?
    public var provenance: Provenance
    public var transformations: [String]
    public var sourceClockDomain: String
    public var audioCapturePermission: AudioCapturePermission
    public var latency: LatencyDescriptor

    public init(deviceUID: String, capturedFormat: InputFormat, latency: LatencyDescriptor) {
        backend = "virtual_device_stream_tap"; self.deviceUID = deviceUID; streamIndex = 0
        self.capturedFormat = capturedFormat; provenance = .deviceMix; transformations = []
        sourceClockDomain = "mach_absolute"; audioCapturePermission = .unknown; self.latency = latency
    }
}

/// Format model only. No real-time buffer or new PCM wire protocol is introduced here.
public struct AudioBlockMetadata: Codable, Equatable, Sendable {
    public var sessionUUID: UUID
    public var epoch: UInt64
    public var sequence: UInt64
    public var firstFrame: UInt64
    public var frameCount: UInt32
    public var formatRevision: UInt64
    public var hostTicks: UInt64
    public var timebaseNumer: UInt32
    public var timebaseDenom: UInt32
    public var timestampValidFlags: UInt32
    public var sourceSampleTime: Double?
    public var sourceSampleTimeValid: Bool
    public var discontinuity: Bool
    public var gapFrames: UInt64?
}

public enum VirtualIdentity {
    public static let deviceUID = "com.homepodflow.virtual-audio.stereo.v1"
    public static let modelUID = "com.homepodflow.virtual-audio.model.v1"
}

/// Device discovery does not imply permission, valid PCM, calibrated latency, or readiness.
public struct DiscoveredVirtualDevice: Codable, Equatable, Sendable {
    public var descriptor: InputDescriptor
    public var running: Bool
    public var availableSampleRates: [Double]
    public var deviceLatencyFrames: UInt32
    public var safetyOffsetFrames: UInt32
    public var bufferFrames: UInt32
    public var zeroTimestampPeriod: UInt32
    public var tapVerified: Bool = false

    public init(descriptor: InputDescriptor, running: Bool, availableSampleRates: [Double],
                deviceLatencyFrames: UInt32, safetyOffsetFrames: UInt32, bufferFrames: UInt32,
                zeroTimestampPeriod: UInt32) {
        self.descriptor = descriptor; self.running = running; self.availableSampleRates = availableSampleRates
        self.deviceLatencyFrames = deviceLatencyFrames; self.safetyOffsetFrames = safetyOffsetFrames
        self.bufferFrames = bufferFrames; self.zeroTimestampPeriod = zeroTimestampPeriod
    }
}
