import Foundation

struct SpeakerLatencyMeasurement: Codable, Equatable, Identifiable {
    var id: UUID
    var stableIdentifier: String
    var name: String
    var measuredMS: Double
    var nominalMS: Double
    var residualMS: Double
    var spreadMS: Double
    var confidence: Double
    var measuredAt: Date
    var testVolume: Double? = nil
    var sampleCount: Int? = nil
    var driftMSPerSecond: Double? = nil
    var windowResidualsMS: [Double]? = nil
    var isValid: Bool {
        [measuredMS, nominalMS, residualMS, spreadMS, confidence].allSatisfy(\.isFinite)
        && (0...3000).contains(measuredMS) && (0...3000).contains(nominalMS)
        && (-250...750).contains(residualMS) && (0...12).contains(spreadMS)
        && (0.12...1.001).contains(confidence)
        && abs(measuredMS - nominalMS - residualMS) < 0.1
        && !stableIdentifier.isEmpty
    }
}

struct AcousticCalibrationProfile: Codable, Equatable {
    var version = 4
    var layout: RoomLayout
    var microphoneUID: String
    var measurements: [SpeakerLatencyMeasurement]
    var savedAt: Date
    var verification: CalibrationVerification? = nil

    func matches(_ current: RoomLayout) -> Bool {
        guard version == 4, !measurements.isEmpty, !microphoneUID.isEmpty,
              measurements.count == current.devices.count,
              layout.devices.count == current.devices.count,
              layout.listener == current.listener,
              Set(measurements.map(\.id)).count == measurements.count,
              Set(measurements.map(\.stableIdentifier)).count == measurements.count,
              Set(current.devices.map(\.id)).count == current.devices.count,
              measurements.allSatisfy(\.isValid) else { return false }
        return current.devices.allSatisfy { device in
            guard let stored = layout.devices.first(where: { $0.id == device.id }),
                  let measured = measurements.first(where: { $0.id == device.id }) else { return false }
            return stored.position == device.position && stored.kind == device.kind && stored.role == device.role
                && measured.stableIdentifier == device.stableIdentifier
                && stored.stableIdentifier == device.stableIdentifier
        }
    }

    var commonResidualMS: Double { max(0, measurements.map(\.residualMS).max() ?? 0) }
    func compensationMS(for measurement: SpeakerLatencyMeasurement) -> Double {
        commonResidualMS - measurement.residualMS
    }
}

struct CalibrationVerification: Codable, Equatable {
    var measuredMS: [Double]
    var targetMS: Double
    var spreadMS: Double
    var maximumErrorMS: Double
    var volume: Double
    var verifiedAt: Date
    /// Repeatability accepted by the user: a second pass of the same speaker
    /// may move by up to 100 ms. AirPlay buffering can shift one pass by ~20 ms
    /// even when the room and probe are unchanged.
    static let toleranceMS: Double = 100
    var passed: Bool {
        !measuredMS.isEmpty && measuredMS.allSatisfy(\.isFinite)
        && targetMS.isFinite && (0...3000).contains(targetMS)
        && spreadMS.isFinite && (0...Self.toleranceMS).contains(spreadMS)
        && maximumErrorMS.isFinite && (0...Self.toleranceMS).contains(maximumErrorMS)
        && (1...100).contains(volume)
    }
}
