import Foundation

@main struct StateChecks {
    @MainActor static func main() async {
        let suite = "homepod-flow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let production = AppState(defaults: defaults)
        precondition(production.draftLayout.devices.isEmpty && !production.systemAudio.hasActiveSession)
        let state = AppState(defaults: defaults, visualDemo: true)
        precondition(state.volume == 15 && !state.isRunning && state.isDemo)
        precondition(state.draftLayout.devices.count == 3)
        state.volume = 200
        precondition(state.volume == 100)
        state.volume = .nan
        precondition(state.volume == 15)
        state.volume = -100
        precondition(state.volume == 0)
        state.volume = .infinity
        precondition(state.volume == 15)
        state.avOffsetMS = -8000
        precondition(state.avOffsetMS == -3500)
        state.avOffsetMS = .infinity
        precondition(state.avOffsetMS == 0)
        state.avOffsetMS = .nan
        precondition(state.avOffsetMS == 0)
        state.avOffsetMS = 9999
        precondition(state.avOffsetMS == 3500)
        let initial = state.layout
        state.draftLayout.devices[0].position.x = 0.67
        precondition(state.draftLayout != initial && state.previewLayout == initial && state.layout == initial)
        state.cancelLayout()
        precondition(state.previewLayout == initial && !state.hasUnsavedLayout)
        state.draftLayout.listener = .init(x: -12, y: 30)
        state.applyLayout()
        precondition(state.layout.listener == RoomPoint(x: 0, y: 1))
        state.mode = .synchronized
        let before = state.layout
        let count = state.draftLayout.devices.count
        state.addDemoDevice()
        state.resetLayout()
        state.applyLayout()
        precondition(state.layout == before && state.draftLayout.devices.count == count)
        state.volume = 42
        state.avOffsetMS = -321
        state.setRunning(true)
        precondition(state.isRunning && state.statusText.contains("演示"))
        state.testSound()
        precondition(state.notice.contains("不会播放"))
        let migrated = AppState(defaults: defaults)
        precondition(migrated.layout.devices.isEmpty) // Old host:nil examples are not real outputs.
        let restored = AppState(defaults: defaults, visualDemo: true)
        precondition(restored.mode == .synchronized && restored.volume == 42)
        precondition(restored.avOffsetMS == -321 && restored.layout == before)
        precondition(!restored.isRunning)
        precondition(restored.notice.contains("未应用"))
        restored.mode = .cinema
        restored.addDemoDevice()
        precondition(restored.draftLayout.devices.count == count + 1)
        let uncommitted = AppState(defaults: defaults, visualDemo: true)
        precondition(uncommitted.layout.devices.count == count)
        let saved = defaults.data(forKey: "homepod-flow.preferences.v1")!
        var future = try! JSONSerialization.jsonObject(with: saved) as! [String: Any]
        future["version"] = 999
        defaults.set(try! JSONSerialization.data(withJSONObject: future), forKey: "homepod-flow.preferences.v1")
        let unsupported = AppState(defaults: defaults)
        precondition(unsupported.volume == 15 && unsupported.mode == .cinema)
        defaults.set(Data("corrupted".utf8), forKey: "homepod-flow.preferences.v1")
        let recovered = AppState(defaults: defaults)
        precondition(recovered.volume == 15 && !recovered.isRunning && recovered.layout.devices.isEmpty)
        precondition(!recovered.notice.contains("演示"))

        let realSuite = "homepod-flow-real-layout-tests-\(UUID().uuidString)"
        let realDefaults = UserDefaults(suiteName: realSuite)!
        defer { realDefaults.removePersistentDomain(forName: realSuite) }
        let configured = AppState(defaults: realDefaults)
        await configured.startSystemAudio() // Empty layout must never connect/capture/play.
        precondition(!configured.systemAudio.serviceReady && !configured.systemAudio.hasActiveSession)

        func discovery(_ miniName: String = "沙发右边") -> [String: JSONValue] {
            ["devices": .array([
                .object(["name": .string(miniName), "address": .string("192.0.2.1"), "model": .string("DeviceModel.HomePodMini"), "identifier": .string("mini-identity")]),
                .object(["name": .string("名称故意写 mini"), "address": .string("192.0.2.2"), "model": .string("DeviceModel.HomePodGen2"), "identifier": .string("front-identity")]),
                .object(["name": .string("mini但型号未知"), "address": .string("192.0.2.3"), "model": .string("UnverifiedMiniSpeaker")])
            ])]
        }
        try! configured.systemAudio.acceptDiscoveryPayload(discovery())
        precondition(configured.systemAudio.devices[0].model == "DeviceModel.HomePodMini")
        precondition(configured.systemAudio.devices[0].detectedSpeakerKind == .mini)
        precondition(configured.systemAudio.devices[1].detectedSpeakerKind == .homePod)
        precondition(configured.systemAudio.devices[2].detectedSpeakerKind == nil)
        precondition(DiscoveredDevice(name: "任意名字", host: "test", model: "AudioAccessory5,1").detectedSpeakerKind == .mini)
        precondition(DiscoveredDevice(name: "mini", host: "test").detectedSpeakerKind == nil)

        let knownHosts: Set<String> = ["192.0.2.1", "192.0.2.2"]
        configured.stageSystemDevices(knownHosts)
        precondition(configured.draftLayout.devices.map(\.kind) == [.mini, .homePod])
        precondition(configured.layout.devices.isEmpty && configured.previewLayout.devices.isEmpty)
        precondition(configured.systemAudio.selectedDeviceIDs.isEmpty)
        configured.cancelLayout()
        precondition(configured.draftLayout.devices.isEmpty && configured.systemAudio.selectedDeviceIDs.isEmpty)

        configured.stageSystemDevices(knownHosts)
        configured.applyLayout()
        precondition(configured.systemAudio.selectedDeviceIDs == knownHosts)
        precondition(configured.layout.devices[0].stableIdentifier == "mini-identity")
        let savedLayoutSnapshot = configured.layout
        configured.draftLayout.devices[0].position = .init(x: 0.66, y: 0.44)
        precondition(configured.previewLayout == savedLayoutSnapshot && configured.deviceCount == 2)
        configured.cancelLayout()

        // A real identity follows its new address; an impostor at the old IP cannot replace it.
        let firstID = configured.draftLayout.devices[0].id
        let movedDiscovery: [DiscoveredDevice] = [
            .init(name: "Moved receiver", host: "192.0.2.11", model: "HomePodMini", identifier: "mini-identity"),
            .init(name: "Impostor", host: "192.0.2.1", model: "HomePodMini", identifier: "other-identity"),
            .init(name: "Front", host: "192.0.2.2", model: "HomePod", identifier: "front-identity")]
        let moved = configured.resolveSavedReceivers(in: movedDiscovery)!
        precondition(moved.devices[0].host == "192.0.2.11" && moved.devices[0].id == firstID)
        precondition(moved.devices[0].position == configured.layout.devices[0].position && moved.devices[0].kind == configured.layout.devices[0].kind)
        precondition(configured.resolveSavedReceivers(in: Array(movedDiscovery.dropFirst())) == nil)
        precondition(configured.resolveSavedReceivers(in: movedDiscovery + [movedDiscovery[0]]) == nil)
        let identityRestored = AppState(defaults: realDefaults)
        precondition(identityRestored.layout.devices[0].stableIdentifier == "mini-identity")
        // Existing host-only preferences decode without fabricated stable identifiers.
        let legacyDevice = RoomDevice(name: "Old saved", position: .init(x: 0.5, y: 0.5), kind: .mini, role: .front, host: "192.0.2.99")
        let legacyDecoded = try! JSONDecoder().decode(RoomDevice.self, from: JSONEncoder().encode(legacyDevice))
        precondition(legacyDecoded.stableIdentifier == nil)
        // New finishes must persist without breaking the two legacy raw values.
        precondition(SpeakerKind(rawValue: "mini") == .mini && SpeakerKind(rawValue: "homePod") == .homePod)
        let colored = RoomDevice(name: "Yellow mini", position: .init(x: 0.5, y: 0.5),
                                 kind: .miniYellow, role: .rearLeft, host: "192.0.2.77")
        let coloredDecoded = try! JSONDecoder().decode(RoomDevice.self, from: JSONEncoder().encode(colored))
        precondition(coloredDecoded.kind == .miniYellow && coloredDecoded.kind.form == .mini)
        precondition(SpeakerKind.homePodMidnight.form == .homePod)

        // Preparation/backoff intent locks every editing entry even without an active session.
        let preparation = configured.systemAudio.beginPlaybackPreparation()!
        let lockedLayout = configured.draftLayout, lockedMode = configured.mode, lockedVolume = configured.volume
        precondition(configured.systemAudio.desiredEnabled && !configured.systemAudio.hasActiveSession)
        configured.mode = .synchronized; configured.volume = 99
        configured.draftLayout.devices[0].position.x = 0.01
        configured.removeDevice(firstID); configured.stageSystemDevices([]); configured.resetLayout(); configured.applyLayout()
        precondition(configured.mode == lockedMode && configured.volume == 99 && configured.draftLayout == lockedLayout)
        await configured.systemAudio.stop()
        precondition(!configured.systemAudio.isPlaybackIntentCurrent(preparation) && configured.layoutEditable)
        configured.volume = lockedVolume
        precondition(configured.draftLayout == savedLayoutSnapshot && configured.systemAudio.selectedDeviceIDs == knownHosts)
        try! configured.systemAudio.acceptDiscoveryPayload(["devices": .array([
            .object(["name": .string("Front"), "address": .string("192.0.2.2"), "model": .string("HomePod"), "identifier": .string("front-identity")])])])
        configured.stageSystemDevices(knownHosts)
        precondition(configured.draftLayout.devices.count == 2 && configured.draftLayout.devices[0].id == firstID)
        precondition(configured.draftLayout.devices[0].stableIdentifier == "mini-identity")
        configured.cancelLayout()
        try! configured.systemAudio.acceptDiscoveryPayload(discovery())

        configured.confirmSpeakerKind(.homePod, for: firstID) // Explicit user correction wins future scans.
        configured.draftLayout.devices[0].position = .init(x: 0.66, y: 0.44)
        configured.applyLayout()
        try! configured.systemAudio.acceptDiscoveryPayload(discovery("重新命名的沙发音箱"))
        configured.stageSystemDevices(knownHosts)
        precondition(configured.draftLayout.devices[0].id == firstID)
        precondition(configured.draftLayout.devices[0].kind == .homePod)
        precondition(configured.draftLayout.devices[0].position == .init(x: 0.66, y: 0.44))
        precondition(configured.draftLayout.devices[0].name == "重新命名的沙发音箱")
        configured.cancelLayout()

        let withUnknown: Set<String> = ["192.0.2.1", "192.0.2.3"]
        configured.stageSystemDevices(withUnknown)
        precondition(configured.unconfirmedSpeakerHosts == ["192.0.2.3"])
        configured.applyLayout()
        precondition(configured.systemAudio.selectedDeviceIDs == knownHosts) // No guessed model saved.
        let unknownID = configured.draftLayout.devices.first(where: { $0.host == "192.0.2.3" })!.id
        configured.confirmSpeakerKind(.mini, for: unknownID)
        configured.applyLayout()
        precondition(configured.unconfirmedSpeakerHosts.isEmpty && configured.systemAudio.selectedDeviceIDs == withUnknown)
        let restoredReal = AppState(defaults: realDefaults)
        precondition(restoredReal.layout == configured.layout && restoredReal.unconfirmedSpeakerHosts.isEmpty)
        precondition(restoredReal.systemAudio.selectedDeviceIDs == withUnknown)

        let savedBeforeEmpty = configured.layout
        configured.stageSystemDevices([])
        precondition(configured.previewLayout == savedBeforeEmpty && configured.systemAudio.selectedDeviceIDs == withUnknown)
        configured.cancelLayout()
        precondition(configured.layout == savedBeforeEmpty && configured.systemAudio.selectedDeviceIDs == withUnknown)
        configured.stageSystemDevices([])
        configured.applyLayout()
        precondition(configured.previewLayout.devices.isEmpty && configured.systemAudio.selectedDeviceIDs.isEmpty)
        precondition(!configured.systemAudio.hasActiveSession && !configured.systemAudio.serviceReady)

        // Removing a powered-off speaker must work without switching to cinema mode.
        let removalSuite = "homepod-flow-sync-removal-\(UUID().uuidString)"
        let removalDefaults = UserDefaults(suiteName: removalSuite)!
        defer { removalDefaults.removePersistentDomain(forName: removalSuite) }
        let removalState = AppState(defaults: removalDefaults, visualDemo: true)
        removalState.mode = .synchronized
        let removalID = removalState.draftLayout.devices[0].id
        let removalCount = removalState.draftLayout.devices.count
        removalState.removeDevice(removalID)
        precondition(removalState.draftLayout.devices.count == removalCount - 1)
        removalState.applyLayout()
        precondition(removalState.layout.devices.count == removalCount - 1)
        print("PASS: preferences, saved-menu layout, draft/cancel/apply selection isolation, reliable model mapping, explicit unknown correction, persisted coordinates/kind, empty-start safety")
    }
}

