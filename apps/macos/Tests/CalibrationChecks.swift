import Foundation

@main struct CalibrationChecks {
    @MainActor static func main() {
        let suite = "hpf-calibration-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = RoomDevice(name: "A", position: .init(x: 0.2, y: 0.4), kind: .mini, role: .front,
                           host: "192.0.2.1", stableIdentifier: "speaker-a")
        let b = RoomDevice(name: "B", position: .init(x: 0.8, y: 0.4), kind: .homePod, role: .front,
                           host: "192.0.2.2", stableIdentifier: "speaker-b")
        let layout = RoomLayout(devices: [a, b], listener: .init(x: 0.5, y: 0.8))
        let measurements = zip([a, b], [12.0, 47.0]).map { device, residual in
            SpeakerLatencyMeasurement(id: device.id, stableIdentifier: device.stableIdentifier!, name: device.name,
                measuredMS: 2000 + residual, nominalMS: 2000, residualMS: residual,
                spreadMS: 1.1, confidence: 0.8, measuredAt: Date())
        }
        let profile = AcousticCalibrationProfile(layout: layout, microphoneUID: "builtin",
            measurements: measurements, savedAt: Date(),
            verification: CalibrationVerification(measuredMS: [2047, 2048], targetMS: 2047, spreadMS: 1, maximumErrorMS: 1, volume: 1, verifiedAt: Date()))
        precondition(profile.matches(layout))
        precondition(profile.compensationMS(for: measurements[0]) == 35)
        precondition(profile.compensationMS(for: measurements[1]) == 0)
        var changed = layout
        changed.devices.reverse()
        changed.devices[0].host = "192.0.2.99"; changed.devices[0].name = "new name"
        precondition(profile.matches(changed), "DHCP/name/order must not invalidate identity")
        changed.devices[0].stableIdentifier = "replacement"
        precondition(!profile.matches(changed), "never calibrate another device at a reused address")
        changed = layout; changed.listener.x += 0.1
        precondition(!profile.matches(changed))
        changed = layout; changed.devices[0].position.y += 0.1
        precondition(!profile.matches(changed))
        changed = layout; changed.devices.removeLast()
        precondition(!profile.matches(changed))
        defaults.set(try! JSONEncoder().encode(profile), forKey: "homepod-flow.acoustic-calibration.v1")
        let store = CalibrationStore(defaults: defaults)
        precondition(store.residuals(for: layout) == ["speaker-a": 12, "speaker-b": 47])
        precondition(store.residuals(for: changed) == nil)
        store.clear()
        precondition(CalibrationStore(defaults: defaults).saved == nil)
        precondition(store.testVolume == 10)
        store.setTestVolume(37)
        store.resetPresentation()
        precondition(store.testVolume == 37 && store.currentVolume == 37)
        precondition(CalibrationStore(defaults: defaults).testVolume == 37)
        store.setTestVolume(.nan)
        precondition(store.testVolume == 37)
        store.setTestVolume(999)
        precondition(store.testVolume == 100)
        store.setTestVolume(-1)
        precondition(store.testVolume == 1)
        var verification = profile.verification!
        verification.volume = 100
        precondition(verification.passed)
        verification.volume = 101
        precondition(!verification.passed)
        print("PASS: identity, persistence, layout invalidation, compensation, volume persistence/range and verification")
    }
}
