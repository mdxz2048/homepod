import Foundation
import Observation

/// Owns user intent separately from an actual capture/send session. No enabled intent is persisted.
@Observable @MainActor final class SystemAudioStore {
    private(set) var serviceReady = false
    private(set) var isBusy = false
    private(set) var isRunning = false
    private(set) var statusText = "系统音频服务未连接"
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var lastDiscoverySucceeded = false
    var selectedDeviceIDs: Set<String> = []
    private(set) var lastResultPayload: [String: JSONValue] = [:]
    private(set) var cleanupRequiresAttention = false
    private(set) var recoveryPending = false
    private(set) var volumeStatus = ""
    private(set) var volumeUpdating = false
    private(set) var appliedVolumePercent: Double?
    private(set) var latencyStatusText = ""
    private(set) var latencyState: LatencyControlState?
    private var recovery = SystemSessionRecovery()
    var desiredEnabled: Bool { recovery.desiredEnabled }
    var recoveryAttempt: Int { recovery.attempts }
    var hasActiveSession: Bool { session != nil }
    private(set) var stableIdentifiersByHost: [String: String] = [:]

    @ObservationIgnored private let serviceFactory: @MainActor () throws -> any SystemAudioRouting
    @ObservationIgnored private let retrySleep: @MainActor (Double) async throws -> Void
    @ObservationIgnored private let observesEnvironment: Bool
    @ObservationIgnored private var service: (any SystemAudioRouting)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var disconnecting = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var stableTask: Task<Void, Never>?
    @ObservationIgnored private var environmentController: SystemAudioEnvironmentController?
    @ObservationIgnored private let defaultOutput: any DefaultOutputControlling
    @ObservationIgnored private var defaultOutputRoutedForSession: String?
    @ObservationIgnored private var defaultOutputPreviousUID: String?
    @ObservationIgnored private var defaultOutputFailure: String?
    private var session: String?
    private var sessionUsesVirtualInput = false
    private var activeMode: PlaybackMode = .synchronized
    private var activeVolume: Double = 15
    private var targetIdentifiers: [String] = []
    private var lastFailure: SystemSessionFailure?
    private var discoveryFailure: SystemSessionFailure?
    private var scanning = false
    private var lastCleanupConfirmed = true
    private var environmentRestartRequested = false
    private var sleeping = false
    private var networkAvailable = true
    private var stoppingSession: String?
    private var pendingVolume: Double?
    private var volumeRequestInFlight = false
    private var volumeEpoch = UUID()
    private var outputCount = 0

    /// Worker-reported playback rendering. Implementation strings stay internal;
    /// the UI only ever shows a truthful, human-readable claim.
    private enum ActualMode {
        case sameStereo, stereoDownmix, channelDistribution, unknown
        init(_ raw: String?) {
            switch raw {
            case "same_stereo": self = .sameStereo
            case "stereo_downmix": self = .stereoDownmix
            case "channel_distribution": self = .channelDistribution
            default: self = .unknown
            }
        }
    }

    /// Keeps at most one pending value. The request already sent is never duplicated or recalled.
    func setVolume(_ value: Double) {
        guard value.isFinite, (0...100).contains(value) else { return }
        activeVolume = value
        guard desiredEnabled, session != nil, stoppingSession == nil else { return }
        pendingVolume = value; volumeUpdating = true
        volumeStatus = isRunning ? "正在更新音量…" : "开始播放时应用当前音量"
        pumpVolume()
    }

    private func invalidateVolumeUpdates(clearStatus: Bool = true) {
        pendingVolume = nil; volumeEpoch = UUID(); volumeUpdating = false
        if clearStatus { volumeStatus = "" }
        appliedVolumePercent = nil
        // Do not clear inFlight here: an old request must settle before another is sent.
    }

    private func pumpVolume() {
        guard !volumeRequestInFlight, let value = pendingVolume, let service,
              let sid = session, desiredEnabled, isRunning, stoppingSession == nil else { return }
        guard service.supportsRealtimeVolume else {
            pendingVolume = nil; volumeUpdating = false
            volumeStatus = "服务不支持实时音量，当前音量未更新"; return
        }
        pendingVolume = nil; volumeRequestInFlight = true
        let epoch = volumeEpoch, token = generation, expectedOutputs = outputCount
        Task { [weak self] in
            guard let self else { return }
            guard self.generation == token, self.session == sid, self.volumeEpoch == epoch,
                  self.desiredEnabled, self.isRunning, self.stoppingSession == nil else {
                self.volumeRequestInFlight = false; self.pumpVolume(); return
            }
            do {
                let reply = try await service.request("set_volume", params: ["session": .string(sid), "volume": .number(value)], session: sid, timeout: 20)
                if self.generation == token, self.session == sid, self.volumeEpoch == epoch, self.desiredEnabled {
                    guard reply.payload["state"]?.string == "volume_applied",
                          let applied = reply.payload["volume_percent"]?.number, applied.isFinite,
                          abs(applied - value) < 0.000001,
                          reply.payload["applied_outputs"]?.number == Double(expectedOutputs),
                          reply.payload["session"] == nil || reply.payload["session"]?.string == sid else {
                        throw WorkerFailure.protocolViolation("Invalid volume acknowledgment")
                    }
                    self.appliedVolumePercent = applied
                    self.volumeStatus = "" // The slider's preference remains distinct from this confirmed value.
                }
            } catch {
                if self.generation == token, self.session == sid, self.volumeEpoch == epoch, self.desiredEnabled {
                    self.volumeStatus = "音量更新失败：\(error.localizedDescription)"
                }
            }
            self.volumeRequestInFlight = false
            if self.pendingVolume == nil { self.volumeUpdating = false }
            self.pumpVolume()
        }
    }

    init(serviceFactory: (@MainActor () throws -> any SystemAudioRouting)? = nil,
         retrySleep: (@MainActor (Double) async throws -> Void)? = nil,
         observesEnvironment: Bool = true,
         defaultOutput: (any DefaultOutputControlling)? = nil) {
        self.serviceFactory = serviceFactory ?? { try SystemRouterService.installed() }
        self.retrySleep = retrySleep ?? { delay in try await Task.sleep(for: .seconds(delay)) }
        self.observesEnvironment = observesEnvironment
        // Hermetic stores (`observesEnvironment == false`) never touch the real
        // default output, so existing silent checks stay side-effect free.
        self.defaultOutput = defaultOutput ?? (observesEnvironment
            ? (DefaultOutputRouteService() as any DefaultOutputControlling)
            : (SilentDefaultOutputController() as any DefaultOutputControlling))
    }

    func connectLocalWorker() async {
        guard service == nil, !isBusy, !disconnecting, !cleanupRequiresAttention else { return }
        isBusy = true; lastDiscoverySucceeded = false
        statusText = "正在连接系统音频服务…"
        let token = UUID(); generation = token
        do {
            let router = try serviceFactory(); service = router
            router.onEvent = { [weak self] event in
                guard let self, self.generation == token else { return }
                self.receive(event)
            }
            router.onFailure = { [weak self] message in
                guard let self, self.generation == token else { return }
                // An exited/poisoned process cannot prove its receiver group was released.
                self.lastCleanupConfirmed = false; self.cleanupRequiresAttention = true
                self.recovery.block(); self.cancelTimers()
                self.restoreDefaultOutputOwned()
                self.invalidateVolumeUpdates(clearStatus: false)
                self.statusText = message; self.serviceReady = false
                self.isRunning = false; self.isBusy = self.disconnecting
                self.session = nil; self.service = nil; self.generation = UUID()
                self.lastDiscoverySucceeded = false
            }
            try await router.connect()
            guard generation == token else { return }
            serviceReady = true; statusText = "服务已就绪 · 尚未开始采集或播放"
        } catch {
            if generation == token { service = nil; serviceReady = false; statusText = error.localizedDescription }
        }
        if generation == token { isBusy = false }
    }

    func scanDevices() async {
        guard let service, serviceReady, !isBusy, session == nil else { return }
        isBusy = true; lastDiscoverySucceeded = false; let token = generation
        scanning = true; discoveryFailure = nil
        defer { if generation == token { scanning = false } }
        do {
            let result = try await service.request("scan", params: [:], session: nil, timeout: 20)
            guard generation == token else { return }
            try acceptDiscoveryPayload(result.payload)
        } catch {
            if case WorkerFailure.protocolViolation(let message) = error { service.abortProtocol(message) }
            if generation == token { statusText = error.localizedDescription }
        }
        if generation == token { isBusy = false }
    }

    /// Legacy discovery without identifiers permits explicit start, never autonomous recovery.
    func acceptDiscoveryPayload(_ payload: [String: JSONValue]) throws {
        lastDiscoverySucceeded = false
        guard let values = payload["devices"]?.array, values.count <= 64 else {
            throw WorkerFailure.protocolViolation("Invalid receiver discovery list")
        }
        var found: [DiscoveredDevice] = [], seen = Set<String>(), identifiers = [String: String]()
        var seenIdentifiers = Set<String>()
        for value in values {
            guard let object = value.object,
                  let name = object["name"]?.string, name.count <= 1024,
                  let address = object["address"]?.string, !address.isEmpty, address.count <= 255,
                  let model = object["model"]?.string, model.count <= 1024 else {
                throw WorkerFailure.protocolViolation("Invalid discovered receiver/model")
            }
            guard seen.insert(address).inserted else { throw WorkerFailure.protocolViolation("Duplicate receiver address") }
            if let raw = object["identifier"], raw != .null {
                guard let identifier = raw.string, !identifier.isEmpty, identifier.count <= 1024,
                      seenIdentifiers.insert(identifier).inserted else {
                    throw WorkerFailure.protocolViolation("Invalid or ambiguous stable receiver identifier")
                }
                identifiers[address] = identifier
            }
            found.append(.init(name: name, host: address, model: model, identifier: identifiers[address]))
        }
        devices = found; stableIdentifiersByHost = identifiers
        selectedDeviceIDs.formIntersection(Set(found.map(\.id)))
        lastDiscoverySucceeded = true; statusText = "发现 \(found.count) 个输出 · 请选择独立音箱"
    }

    /// Begins the explicit user operation before async connection/discovery, so Stop can cancel it.
    func beginPlaybackPreparation() -> UUID? {
        guard !desiredEnabled, !hasActiveSession, !isBusy, !disconnecting, !cleanupRequiresAttention else { return nil }
        cancelTimers(); recovery.enable()
        return recovery.intent
    }
    func isPlaybackIntentCurrent(_ intent: UUID) -> Bool { desiredEnabled && recovery.intent == intent }

    func start(mode: PlaybackMode, volume: Double) async {
        guard serviceReady, !isBusy, session == nil, !disconnecting else { return }
        guard !cleanupRequiresAttention else { statusText = "上次清理未确认，请先检查音箱并重新启动应用"; return }
        let selected = devices.filter { selectedDeviceIDs.contains($0.id) }
        guard !selected.isEmpty, selected.count <= 8, selected.count == selectedDeviceIDs.count else {
            statusText = "请先选择1至8个当前可用的独立音箱"; return
        }
        guard volume.isFinite, (0...100).contains(volume) else { statusText = "启动音量无效"; return }
        if let service, service.runtime.virtual_capture_host != nil, !service.supportsVirtualInput {
            statusText = "本机服务尚不支持 Flow 虚拟声卡，请更新采集服务"; return
        }
        cancelTimers()
        if !desiredEnabled { recovery.enable() }
        guard !recovery.blocked else { return }
        activeMode = mode; activeVolume = volume
        targetIdentifiers = selected.compactMap { stableIdentifiersByHost[$0.host] }
        if targetIdentifiers.count != selected.count { targetIdentifiers = [] }
        installEnvironmentControllerIfNeeded()
        await runSession(hosts: selected.map(\.host), intent: recovery.intent)
    }

    private func runSession(hosts: [String], intent: UUID) async {
        guard let service, serviceReady, desiredEnabled, recovery.intent == intent,
              !cleanupRequiresAttention, !sleeping, networkAvailable, session == nil, !disconnecting else { return }
        // A previous session must not leave Flow as the default while the next
        // negotiated latency write expects an idle driver.
        restoreDefaultOutputOwned()
        defaultOutputFailure = nil
        sessionUsesVirtualInput = service.runtime.virtual_capture_host != nil
        let sid = UUID().uuidString; session = sid
        invalidateVolumeUpdates(); outputCount = hosts.count
        let token = generation
        isBusy = true; isRunning = false; lastFailure = nil; lastCleanupConfirmed = false
        lastResultPayload = [:]; recoveryPending = false
        statusText = "正在准备系统音频 · 首次启动可能需要系统授权"
        let routes: [JSONValue] = hosts.enumerated().map { index, host in
            .object(["output_id": .integer(index), "channels": .array([.integer(0), .integer(1)]), "host": .string(host)])
        }
        var retryable = false
        do {
            var params: [String: JSONValue] = [
                "session": .string(sid), "library": .string(service.runtime.library),
                "capture_host": .string(service.runtime.virtual_capture_host ?? service.runtime.capture_host), "routes": .array(routes),
                "volume": .number(activeVolume), "mode": .string(activeMode.rawValue),
                "exclude_pids": .array([.integer(Int(ProcessInfo.processInfo.processIdentifier))])
            ]
            if service.runtime.virtual_capture_host != nil {
                var input: [String: JSONValue] = [
                    "backend": .string("virtual_device_v2"),
                    "device_uid": .string(FlowVirtualDevice.uid),
                    "layout": .string("7_1")
                ]
                if let helper = service.runtime.latency_control, !helper.isEmpty {
                    input["latency_control"] = .string(helper)
                }
                params["input"] = .object(input)
            }
            let result = try await service.request("start", params: params, session: sid, timeout: nil)
            guard generation == token, session == sid else { return }
            lastResultPayload = result.payload
            guard result.payload["state"]?.string == "stopped",
                  result.payload["cleanup_complete"]?.bool == true,
                  let report = result.payload["report"]?.object,
                  report["cleanup_complete"]?.bool == true,
                  report["input_closed"]?.bool == true,
                  report["hub_stopped"]?.bool == true else {
                throw WorkerFailure.protocolViolation("Live stop lacks resource cleanup confirmation")
            }
            lastCleanupConfirmed = true; retryable = environmentRestartRequested
            statusText = "系统音频已停止 · 清理已确认"
        } catch {
            guard generation == token, session == sid else { return }
            if let failure = lastFailure {
                lastCleanupConfirmed = failure.cleanupConfirmed; retryable = failure.retryable
            }
            if case WorkerFailure.protocolViolation(let message) = error { service.abortProtocol(message) }
            statusText = error.localizedDescription
        }
        guard generation == token, session == sid else { return }
        stableTask?.cancel(); stableTask = nil
        restoreDefaultOutputOwned()
        invalidateVolumeUpdates(clearStatus: false)
        session = nil; isBusy = false; isRunning = false
        if let failure = defaultOutputFailure {
            statusText = "系统音频已停止 · \(failure)"
        }
        if !lastCleanupConfirmed {
            cleanupRequiresAttention = true; recovery.block()
            statusText += " · 清理未确认，已禁止自动重启"
        }
        guard desiredEnabled, recovery.intent == intent else { return }
        if retryable { scheduleRecovery() }
        else { recovery.block() } // Permission/format/internal failures need an explicit user decision.
    }

    func revokePlaybackIntent() {
        invalidateVolumeUpdates()
        recovery.cancel(); cancelTimers(); environmentRestartRequested = false; recoveryPending = false
    }

    func stop() async { revokePlaybackIntent(); await stopSession() }

    /// SwiftUI's synchronous setter cancels intent now; its queued stop cannot cancel a new intent.
    func requestStop() {
        revokePlaybackIntent()
        guard let sid = session else {
            restoreDefaultOutputOwned()
            if !cleanupRequiresAttention { statusText = "系统音频已停止" }
            return
        }
        Task { [weak self] in
            guard let self, self.session == sid else { return }
            await self.stopSession()
        }
    }

    private func stopSession() async {
        guard let service, let sid = session else {
            restoreDefaultOutputOwned()
            if !cleanupRequiresAttention { statusText = "系统音频已停止" }
            return
        }
        guard stoppingSession != sid else { return }
        stoppingSession = sid
        invalidateVolumeUpdates()
        defer { if stoppingSession == sid { stoppingSession = nil } }
        let token = generation; statusText = "正在停止采集与音箱发送…"
        do {
            let result = try await service.request("stop", params: ["session": .string(sid)], session: sid, timeout: 15)
            guard generation == token, session == nil || session == sid else { return }
            guard result.payload["cleanup_complete"]?.bool == true else { throw WorkerFailure.cleanupUnconfirmed }
            // start's terminal result remains the authoritative session-completion barrier.
            restoreDefaultOutputOwned()
            statusText = defaultOutputFailure.map { "系统音频已停止 · \($0)" }
                ?? "系统音频已停止 · 清理已确认"
        } catch {
            guard generation == token else { return }
            restoreDefaultOutputOwned()
            lastCleanupConfirmed = false; cleanupRequiresAttention = true; recovery.block(); cancelTimers()
            statusText = error.localizedDescription
        }
    }

    func disconnect() async {
        revokePlaybackIntent()
        guard let service, !disconnecting else { return }
        restoreDefaultOutputOwned()
        disconnecting = true; isBusy = true; serviceReady = false
        statusText = "正在停止系统音频并退出服务…"
        let token = generation
        do {
            try await service.disconnect()
            lastCleanupConfirmed = true; cleanupRequiresAttention = false
            statusText = "系统音频服务已退出 · 清理已确认"
        } catch {
            lastCleanupConfirmed = false; cleanupRequiresAttention = true
            statusText = error.localizedDescription
        }
        // connect is guarded by disconnecting; old shutdown cannot overwrite a new service.
        if generation == token { generation = UUID() }
        self.service = nil; session = nil
        isRunning = false; isBusy = false; serviceReady = false; disconnecting = false
        lastDiscoverySucceeded = false
    }

    func prepareForTermination() async {
        revokePlaybackIntent(); environmentController?.invalidate(); environmentController = nil
        await disconnect()
    }

    private func scheduleRecovery() {
        guard retryTask == nil, desiredEnabled, !cleanupRequiresAttention else { return }
        recoveryPending = true
        if sleeping || !networkAvailable {
            statusText = sleeping ? "已停止并清理 · 等待唤醒后重新发现音箱" : "已停止并清理 · 等待网络恢复"
            return
        }
        guard let delay = recovery.nextDelay(cleanupConfirmed: lastCleanupConfirmed,
                                             retryable: true, hasStableTargets: !targetIdentifiers.isEmpty) else {
            recoveryPending = false
            statusText = targetIdentifiers.isEmpty ? "音箱缺少稳定标识，需手动重新选择" : "自动恢复已停止，请检查音箱后手动重试"
            return
        }
        let intent = recovery.intent
        statusText = "连接已中断 · \(Int(delay)) 秒后重新发现音箱（\(recoveryAttempt)/5）"
        let sleep = retrySleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.desiredEnabled, self.recovery.intent == intent else { return }
            self.retryTask = nil; await self.recover(intent: intent)
        }
    }

    private func recover(intent: UUID) async {
        guard desiredEnabled, recovery.intent == intent, !sleeping, networkAvailable,
              !cleanupRequiresAttention, session == nil else { return }
        guard serviceReady, service != nil else { recovery.block(); recoveryPending = false; return }
        await scanDevices()
        guard desiredEnabled, recovery.intent == intent, !cleanupRequiresAttention,
              !sleeping, networkAvailable else { return }
        guard lastDiscoverySucceeded else {
            if discoveryFailure?.retryable == true, discoveryFailure?.cleanupConfirmed == true { scheduleRecovery() }
            else { recovery.block(); recoveryPending = false }
            return
        }
        guard let hosts = StableReceiverResolution.addresses(for: targetIdentifiers, discovery: stableIdentifiersByHost) else {
            scheduleRecovery(); return
        }
        selectedDeviceIDs = Set(hosts); environmentRestartRequested = false
        await runSession(hosts: hosts, intent: intent)
    }

    private func cancelTimers() {
        retryTask?.cancel(); retryTask = nil; stableTask?.cancel(); stableTask = nil
    }
    private func installEnvironmentControllerIfNeeded() {
        guard observesEnvironment, environmentController == nil else { return }
        environmentController = SystemAudioEnvironmentController { [weak self] event in self?.handleEnvironment(event) }
    }
    func handleEnvironment(_ event: SystemAudioEnvironmentEvent) {
        switch event {
        case .willTerminate: revokePlaybackIntent(); return
        case .networkChanged:
            guard desiredEnabled, !cleanupRequiresAttention else { return }
            cancelTimers(); environmentRestartRequested = true; recoveryPending = true
            if let sid = session {
                Task { [weak self] in
                    guard let self, self.session == sid else { return }
                    await self.stopSession()
                }
            } else { scheduleRecovery() }
            return
        case .willSleep: sleeping = true
        case .didWake: sleeping = false
        case .networkAvailable(let available): networkAvailable = available
        }
        guard desiredEnabled, !cleanupRequiresAttention else { return }
        if sleeping || !networkAvailable {
            cancelTimers(); environmentRestartRequested = true; recoveryPending = true
            if let sid = session {
                Task { [weak self] in
                    guard let self, self.session == sid else { return }
                    await self.stopSession()
                }
            }
        } else if session == nil, recoveryPending { scheduleRecovery() }
    }

    private func receive(_ event: WorkerEvent) {
        if event.id == nil, event.event == "error" {
            statusText = "系统服务协议警告：\(event.payload["message"]?.string ?? "无法关联的错误")"; return
        }
        if scanning, event.session == nil, event.event == "error" {
            discoveryFailure = SystemSessionFailure(payload: event.payload); return
        }
        guard event.session == session, let sid = session else { return }
        if event.event == "error" {
            lastFailure = SystemSessionFailure(payload: event.payload)
            if event.payload["code"]?.string == "volume_failed" {
                pendingVolume = nil; volumeUpdating = false
                volumeStatus = "音量更新失败：\(event.payload["message"]?.string ?? "音箱未确认，已停止整组播放")"
            }
            return
        }
        guard event.event == "state", let phase = event.payload["state"]?.string else { return }
        if let latencyPayload = event.payload["latency_state"]?.object,
           let latency = LatencyControlState.fromWorker(latencyPayload) {
            latencyState = latency
            latencyStatusText = latency.statusText
        } else if let mismatch = Self.planMismatchText(event.payload) {
            latencyStatusText = mismatch
        }
        switch phase {
        case "preparing": statusText = "正在准备音箱与采集 · 尚未开始发送"
        case "capturing":
            switchDefaultOutputForCurrentSessionIfNeeded(sid)
            guard desiredEnabled, stoppingSession == nil else { break }
            statusText = "正在采集系统音频并准备播放"
        case "streaming":
            switchDefaultOutputForCurrentSessionIfNeeded(sid)
            guard desiredEnabled, stoppingSession == nil else { break }
            isRunning = true
            pumpVolume()
            switch ActualMode(event.payload["actual_mode"]?.string) {
            case .channelDistribution:
                statusText = "已按所选音箱分配声道发送"
            case .stereoDownmix:
                statusText = activeMode == .cinema
                    ? "8 声道输入 · 影院模式已下混为立体声发送"
                    : "8 声道输入 · 已下混为立体声同步发送"
            case .sameStereo:
                statusText = activeMode == .cinema
                    ? "系统立体声正在发送 · 影院模式当前同声退化"
                    : "系统立体声正在同步发送 · 声学同步尚未测量"
            case .unknown:
                statusText = activeMode == .cinema ? "影院模式当前同声退化" : "正在同步发送"
            }
            if stableTask == nil {
                let intent = recovery.intent, sid = session
                stableTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, !Task.isCancelled, self.recovery.intent == intent,
                          self.session == sid, self.isRunning else { return }
                    self.recovery.markStable(); self.stableTask = nil
                }
            }
        case "stopped", "failed": isRunning = false
        default: break
        }
    }

    /// Sets the MEDIA default output to Flow exactly once per live virtual
    /// session. Called from the first `capturing` state (fallback `streaming`),
    /// never from start preflight, so a browser-triggered virtual device cannot
    /// make the negotiated latency helper busy before its write.
    private func switchDefaultOutputForCurrentSessionIfNeeded(_ sid: String) {
        guard sessionUsesVirtualInput, desiredEnabled, session == sid, stoppingSession == nil,
              !cleanupRequiresAttention, !disconnecting else { return }
        guard defaultOutputRoutedForSession == nil else { return }
        let flow = FlowVirtualDevice.uid
        let previousUID = defaultOutput.currentDefaultOutputUID()
        if previousUID == flow {
            // Already routed; nothing to restore later, and the user's manual
            // Flow selection (or an inherited state) is left untouched.
            defaultOutputRoutedForSession = sid
            defaultOutputPreviousUID = nil
            return
        }
        do {
            guard previousUID != nil else { throw DefaultOutputRouteError.currentOutputUnavailable }
            let verified = try defaultOutput.setDefaultOutput(uid: flow)
            guard verified else { throw DefaultOutputRouteError.readbackUnverified }
            defaultOutputPreviousUID = previousUID
            defaultOutputRoutedForSession = sid
        } catch {
            // A half-applied write must not leave Flow as the default.
            if defaultOutput.currentDefaultOutputUID() == flow, let previousUID {
                _ = defaultOutput.restoreDefaultOutput(uid: previousUID)
            }
            let note = "默认输出切换未验证：\(error.localizedDescription)"
            defaultOutputFailure = note
            statusText = note + " · 正在停止本次播放"
            revokePlaybackIntent()
            let active = session
            Task { [weak self] in
                guard let self, self.session == active else { return }
                await self.stopSession()
            }
        }
    }

    /// Restores the previous default output only while Flow still owns it.
    /// A user who manually picked another device during the session keeps it.
    private func restoreDefaultOutputOwned() {
        guard let _ = defaultOutputRoutedForSession else { return }
        defaultOutputRoutedForSession = nil
        guard let previous = defaultOutputPreviousUID else {
            defaultOutputPreviousUID = nil
            return
        }
        defaultOutputPreviousUID = nil
        guard defaultOutput.currentDefaultOutputUID() == FlowVirtualDevice.uid else { return }
        _ = defaultOutput.restoreDefaultOutput(uid: previous)
    }

    /// User-facing plan vs. report difference. This is a nominal-vs-read
    /// comparison, explicitly not an acoustic sync conclusion.
    private static func planMismatchText(_ payload: [String: JSONValue]) -> String? {
        guard let comparison = payload["programmed_vs_reported_ms"]?.object,
              let programmed = comparison["programmed_ms"]?.number,
              let reported = comparison["reported_ms"]?.number,
              let difference = comparison["signed_difference_ms"]?.number else { return nil }
        return "计划 \(Int(programmed.rounded()))ms · 设备报告 \(Int(reported.rounded()))ms · 差值 \(Int(difference.rounded()))ms（非声学同步结论）"
    }
}

/// Hermetic stores are never allowed to probe or move a real default output.
@MainActor private final class SilentDefaultOutputController: DefaultOutputControlling {
    func currentDefaultOutputUID() -> String? { "silent-default-output" }
    func setDefaultOutput(uid: String) throws -> Bool { true }
    func restoreDefaultOutput(uid: String) -> Bool { true }
}
