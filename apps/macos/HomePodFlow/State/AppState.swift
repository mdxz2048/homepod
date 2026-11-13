import Foundation
import Observation

private struct StoredPreferences: Codable {
    var version = 1
    var mode: PlaybackMode
    var volume: Double
    var avOffsetMS: Double
    var layout: RoomLayout
}

@Observable @MainActor final class AppState {
    let worker = WorkerStore()
    let systemAudio: SystemAudioStore
    let audioComponent: AudioComponentService
    private var storedMode: PlaybackMode
    var mode: PlaybackMode {
        get { storedMode }
        set { guard !sessionControlsLocked else { return }; storedMode = newValue; persist() }
    }
    private var storedVolume: Double
    var volume: Double {
        get { storedVolume }
        set {
            storedVolume = Self.bounded(newValue, 0...100, fallback: 15)
            persist(); systemAudio.setVolume(storedVolume)
            systemAudio.setSystemOutputVolume(storedVolume)
        }
    }
    private var storedAVOffsetMS: Double
    var avOffsetMS: Double {
        get { storedAVOffsetMS }
        set { storedAVOffsetMS = Self.bounded(newValue, -3500...3500, fallback: 0); persist() }
    }
    private(set) var isRunning = false
    let isDemo: Bool
    let visualDemo: Bool
    private(set) var layout: RoomLayout
    private var storedDraftLayout: RoomLayout
    var draftLayout: RoomLayout {
        get { storedDraftLayout }
        set { guard layoutEditable else { return }; storedDraftLayout = newValue }
    }
    var selectedDeviceID: UUID?
    var selectedPage: SettingsPage = .layout
    private(set) var statusText = "演示 · 未连接真实设备"
    var notice = "尚未配置音箱 · 添加发现的设备并应用布局后即可开启系统音频。"
    var sessionControlsLocked: Bool { systemAudio.desiredEnabled || systemAudio.hasActiveSession || systemAudio.isBusy }
    var layoutEditable: Bool { mode == .cinema && !sessionControlsLocked }
    /// Removing a saved speaker is allowed in either playback mode. A powered-
    /// off speaker must not force the user to switch to cinema mode first.
    var canRemoveDevice: Bool { !sessionControlsLocked }
    var previewLayout: RoomLayout { layout }
    var hasUnsavedLayout: Bool { draftLayout != layout }
    var deviceCount: Int { layout.devices.count }
    private(set) var unconfirmedSpeakerHosts: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: any RouterService
    private static let storageKey = "homepod-flow.preferences.v1"

    init(defaults: UserDefaults = .standard, service: (any RouterService)? = nil, visualDemo: Bool = false,
         systemAudio: SystemAudioStore? = nil, audioComponent: AudioComponentService? = nil) {
        self.defaults = defaults
        self.systemAudio = systemAudio ?? SystemAudioStore()
        self.audioComponent = audioComponent ?? AudioComponentService()
        self.visualDemo = visualDemo
        let router = service ?? DemoRouterService()
        self.service = router
        isDemo = router.isDemo
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(StoredPreferences.self, from: $0) }
        let valid = saved?.version == 1 ? saved : nil
        storedMode = valid?.mode ?? .cinema
        storedVolume = Self.bounded(valid?.volume ?? 15, 0...100, fallback: 15)
        storedAVOffsetMS = Self.bounded(valid?.avOffsetMS ?? 0, -3500...3500, fallback: 0)
        var restoredLayout = valid?.layout.normalized ?? (visualDemo ? .demo : .empty)
        if !visualDemo {
            restoredLayout.devices = restoredLayout.devices.filter {
                guard let host = $0.host else { return false }
                return !host.isEmpty && host.count <= 255
            }
        }
        layout = restoredLayout
        storedDraftLayout = restoredLayout
        self.systemAudio.selectedDeviceIDs = Set(restoredLayout.devices.compactMap(\.host))
        if visualDemo { notice = "界面演示：布局与参数仅保存在本机，未应用到音箱。" }
        else if !restoredLayout.devices.isEmpty { notice = "已恢复保存的音箱布局 · 尚未连接或开始采集。" }
        self.audioComponent.refresh()
        self.systemAudio.onSystemVolumeChanged = { [weak self] value, muted in
            self?.systemVolumeDidChange(value, muted: muted)
        }
        self.systemAudio.recoverStaleRouteIfNeeded()
    }

    /// The virtual device is the system's volume authority while Flow owns the
    /// output. Update the menu slider from the hardware value, but do not
    /// overwrite the saved level with a temporary mute value.
    private func systemVolumeDidChange(_ value: Double, muted: Bool) {
        guard !muted else { return }
        let bounded = Self.bounded(value, 0...100, fallback: storedVolume)
        guard abs(bounded - storedVolume) > 0.01 else { return }
        storedVolume = bounded
        persist()
    }

    func setRunning(_ running: Bool) {
        let result = service.setRunning(running)
        switch result {
        case .simulated: isRunning = running && isDemo
        case .unsupported, .failed: isRunning = false
        }
        statusText = result.message
    }
    func applyLayout() {
        guard canRemoveDevice else { return }
        guard !sessionControlsLocked else {
            notice = "请先停止系统音频或等待设备操作完成，再保存布局。"; return
        }
        guard unconfirmedSpeakerHosts.isEmpty else {
            notice = "有设备型号未识别，请在设备属性中选择 HomePod 或 mini 后保存。"; return
        }
        layout = draftLayout.normalized
        draftLayout = layout
        systemAudio.selectedDeviceIDs = Set(layout.devices.compactMap(\.host))
        persist()
        notice = "布局已保存 · 尚未改变实际音箱声道。"
    }
    func cancelLayout() {
        guard !sessionControlsLocked else { return }
        storedDraftLayout = layout
        unconfirmedSpeakerHosts.removeAll()
        if !draftLayout.devices.contains(where: { $0.id == selectedDeviceID }) { selectedDeviceID = nil }
        notice = "已取消未保存的布局修改。"
    }
    func resetLayout() {
        guard layoutEditable else { return }
        draftLayout = layout
        unconfirmedSpeakerHosts.removeAll()
        for index in draftLayout.devices.indices {
            let points = [RoomPoint(x: 0.5, y: 0.29), RoomPoint(x: 0.2, y: 0.73), RoomPoint(x: 0.8, y: 0.73)]
            draftLayout.devices[index].position = points[index % points.count]
        }
        draftLayout.listener = .init(x: 0.5, y: 0.83)
        selectedDeviceID = nil
        notice = "已重置草稿；点击应用后保存。"
    }
    func addDemoDevice() {
        guard layoutEditable, isDemo, draftLayout.devices.count < 16 else { return }
        let device = RoomDevice(name: "示例 mini \(draftLayout.devices.count + 1)",
            position: .init(x: 0.5, y: 0.6), kind: .mini, role: .rearRight)
        draftLayout.devices.append(device)
        selectedDeviceID = device.id
        notice = "已添加示例设备 · 并非真实发现的音箱。"
    }
    func testSound() { notice = service.testSound().message }

    /// Discovery and explicit selection determine the real room; a stored
    /// position is never proof that its device is connected.
    func useSelectedSystemDevices() {
        stageSystemDevices(systemAudio.selectedDeviceIDs)
    }

    func stageSystemDevices(_ ids: Set<String>) {
        guard layoutEditable else {
            notice = "请先停止系统音频，再更新音箱布局。"; return
        }
        guard ids.count <= 8 else { notice = "最多选择8个独立音箱。"; return }
        let previouslyUnconfirmed = unconfirmedSpeakerHosts
        var unconfirmed: Set<String> = []
        var previous: [String: RoomDevice] = [:]
        for device in draftLayout.devices {
            if let host = device.host, previous[host] == nil { previous[host] = device }
        }
        let available = Dictionary(uniqueKeysWithValues: systemAudio.devices.map { ($0.id, $0) })
        guard ids.isSubset(of: Set(available.keys).union(previous.keys)) else {
            notice = "新音箱已不在发现列表中，请重新查找。"; return
        }
        var selected: [(discovery: DiscoveredDevice, stored: RoomDevice?)] = []
        var includedHosts = Set<String>(), includedIdentifiers = Set<String>()
        for stored in draftLayout.devices {
            guard let host = stored.host else { continue }
            let identityMatch = stored.stableIdentifier.flatMap { identifier in
                systemAudio.devices.first { $0.identifier == identifier }
            }
            guard ids.contains(host) || identityMatch.map({ ids.contains($0.id) }) == true else { continue }
            // A known stable identity takes priority over address reuse by another receiver.
            let discovered = identityMatch ?? (stored.stableIdentifier == nil ? available[host] : nil)
            let device = discovered ?? DiscoveredDevice(name: stored.name, host: host, identifier: stored.stableIdentifier)
            selected.append((device, stored)); includedHosts.insert(device.host)
            if let identifier = device.identifier { includedIdentifiers.insert(identifier) }
        }
        for device in systemAudio.devices where ids.contains(device.id) {
            guard !includedHosts.contains(device.host),
                  device.identifier.map({ !includedIdentifiers.contains($0) }) ?? true else { continue }
            selected.append((device, nil)); includedHosts.insert(device.host)
            if let identifier = device.identifier { includedIdentifiers.insert(identifier) }
        }
        let roles: [SpeakerRole] = [.front, .rearLeft, .rearRight]
        let positions = [RoomPoint(x: 0.5, y: 0.29), RoomPoint(x: 0.2, y: 0.73), RoomPoint(x: 0.8, y: 0.73)]
        draftLayout.devices = selected.enumerated().map { index, pair in
            let device = pair.discovery
            if var stored = pair.stored {
                let oldHost = stored.host ?? device.host
                stored.name = device.name
                stored.host = device.host
                stored.stableIdentifier = device.identifier ?? stored.stableIdentifier
                if previouslyUnconfirmed.contains(oldHost) {
                    if let detected = device.detectedSpeakerKind { stored.kind = detected }
                    else { unconfirmed.insert(device.host) }
                }
                return stored
            }
            if device.detectedSpeakerKind == nil { unconfirmed.insert(device.host) }
            return RoomDevice(name: device.name, position: positions[index % positions.count],
                kind: device.detectedSpeakerKind ?? .homePod,
                role: roles[index % roles.count], host: device.host, stableIdentifier: device.identifier)
        }
        unconfirmedSpeakerHosts = unconfirmed
        selectedDeviceID = draftLayout.devices.first?.id
        notice = unconfirmed.isEmpty
            ? "所选音箱已加入布局草稿 · 点击应用保存。"
            : "所选音箱已加入草稿；有型号未识别，请选择实际型号后应用。"
    }

    func confirmSpeakerKind(_ kind: SpeakerKind, for id: UUID) {
        guard layoutEditable, let index = draftLayout.devices.firstIndex(where: { $0.id == id }),
              let host = draftLayout.devices[index].host else { return }
        draftLayout.devices[index].kind = kind
        unconfirmedSpeakerHosts.remove(host)
    }

    func removeDevice(_ id: UUID) {
        guard canRemoveDevice, !systemAudio.hasActiveSession,
              let device = draftLayout.devices.first(where: { $0.id == id }) else { return }
        if let host = device.host { unconfirmedSpeakerHosts.remove(host) }
        var updated = storedDraftLayout
        updated.devices.removeAll { $0.id == id }
        storedDraftLayout = updated
        if selectedDeviceID == id { selectedDeviceID = nil }
    }

    func startSystemAudio() async {
        guard audioComponent.allowsStart else {
            notice = audioComponent.snapshot.message
            return
        }
        let requestedLayout = layout
        let hosts = Set(requestedLayout.devices.compactMap(\.host))
        guard !hosts.isEmpty, hosts.count == requestedLayout.devices.count, hosts.count <= 8 else {
            notice = "请先添加1至8个音箱并应用布局。"; return
        }
        guard !sessionControlsLocked,
              let preparation = systemAudio.beginPlaybackPreparation() else {
            notice = "系统音频正在准备或运行中。"; return
        }
        var handedOff = false
        defer {
            // A failed connection/discovery/identity check must not leave the UI enabled/locked.
            // Only revoke this preparation; a newer user intent/session owns its own lifetime.
            if !handedOff, systemAudio.isPlaybackIntentCurrent(preparation), !systemAudio.hasActiveSession {
                systemAudio.revokePlaybackIntent()
            }
        }
        if !systemAudio.serviceReady { await systemAudio.connectLocalWorker() }
        guard systemAudio.isPlaybackIntentCurrent(preparation) else { return }
        guard systemAudio.serviceReady else { notice = systemAudio.statusText; return }
        await systemAudio.scanDevices()
        guard systemAudio.isPlaybackIntentCurrent(preparation) else { return }
        guard systemAudio.serviceReady, systemAudio.lastDiscoverySucceeded else {
            notice = systemAudio.statusText; return
        }
        guard layout == requestedLayout else { notice = "保存的布局已修改，请重新开启。"; return }
        guard let resolved = resolveSavedReceivers(in: systemAudio.devices) else {
            notice = "保存布局中的部分音箱当前不可用，请检查电源和网络后重试。"; return
        }
        // Only transport metadata changes. Saved positions, kind and UUID remain intact.
        layout = resolved
        storedDraftLayout = resolved
        persist()
        systemAudio.selectedDeviceIDs = Set(resolved.devices.compactMap(\.host))
        notice = "正在准备系统音频与保存的音箱…"
        systemAudio.setSystemOutputVolume(volume)
        handedOff = true
        await systemAudio.start(mode: mode, volume: volume)
        notice = systemAudio.statusText
    }

    /// Stable identities never fall back to an old address/name when missing.
    /// Old preferences without identity may acquire it only from an explicit fresh discovery.
    func resolveSavedReceivers(in discovered: [DiscoveredDevice]) -> RoomLayout? {
        var result = layout
        var hosts = Set<String>(), identifiers = Set<String>()
        for index in result.devices.indices {
            let stored = result.devices[index]
            let matches: [DiscoveredDevice]
            if let identifier = stored.stableIdentifier {
                matches = discovered.filter { $0.identifier == identifier }
            } else { matches = discovered.filter { $0.host == stored.host } }
            guard matches.count == 1, let match = matches.first,
                  hosts.insert(match.host).inserted else { return nil }
            if let identifier = match.identifier {
                guard identifiers.insert(identifier).inserted else { return nil }
            }
            result.devices[index].host = match.host
            result.devices[index].stableIdentifier = match.identifier ?? stored.stableIdentifier
            result.devices[index].name = match.name
        }
        return result
    }

    private func persist() {
        let preferences = StoredPreferences(mode: mode, volume: volume, avOffsetMS: avOffsetMS, layout: layout)
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.storageKey) }
    }
    private static func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

extension DiscoveredDevice {
    /// Exact discovery model IDs, never user-assigned names. Kept in App state
    /// so the transport-only WorkerProtocol remains independently compilable.
    /// Verified identifiers: artifacts/paired-discovery.json.
    var detectedSpeakerKind: SpeakerKind? {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "devicemodel.homepodmini", "homepodmini", "audioaccessory5,1": .mini
        case "devicemodel.homepod", "homepod", "devicemodel.homepodgen2", "homepodgen2", "audioaccessory6,1": .homePod
        default: nil
        }
    }
}
