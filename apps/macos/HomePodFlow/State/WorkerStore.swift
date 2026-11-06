import Foundation
import Observation

@Observable @MainActor final class WorkerStore {
    private(set) var workerStatus = "未连接本机音频服务"
    private(set) var serviceReady = false
    private(set) var isWorkerBusy = false
    private(set) var discoveredDevices: [DiscoveredDevice] = []
    var routeSelections: [DeviceRouteSelection] = []
    private(set) var selectedAudioURL: URL?
    private(set) var audioInfo: AudioInfo?
    private(set) var offlineCheckStatus = "尚未进行离线验证"
    private(set) var playbackStatus = "尚未播放文件"
    private(set) var realIsPlaying = false
    var hasActiveSession: Bool { session != nil }
    private(set) var lastResultPayload: [String: JSONValue] = [:]
    @ObservationIgnored private var service: WorkerRouterService?
    @ObservationIgnored private var generation = UUID()
    private var session: String?
    @ObservationIgnored private var disconnecting = false

    func connectLocalWorker() async {
        guard !disconnecting else { return }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let path = applicationSupport.appendingPathComponent("HomePod Flow/runtime.json")
        do {
            let runtime = try JSONDecoder().decode(WorkerRuntime.self, from: Data(contentsOf: path))
            await connectWorker(pythonURL: URL(fileURLWithPath: runtime.python),
                                projectURL: URL(fileURLWithPath: runtime.project),
                                libraryURL: URL(fileURLWithPath: runtime.library))
        } catch { workerStatus = "本机音频服务未安装或配置无效：\(error.localizedDescription)" }
    }

    func connectWorker(pythonURL: URL, projectURL: URL, libraryURL: URL) async {
        guard service == nil, !isWorkerBusy, !disconnecting else { return }
        isWorkerBusy = true
        workerStatus = "正在连接本机音频服务…"
        generation = UUID()
        let token = generation
        let router = WorkerRouterService(runtime: .init(python: pythonURL.path, project: projectURL.path, library: libraryURL.path))
        service = router
        router.client.onEvent = { [weak self] event in
            guard let self, self.generation == token else { return }
            self.receive(event)
        }
        router.client.onFailure = { [weak self] message in
            guard let self, self.generation == token else { return }
            if self.session != nil {
                self.offlineCheckStatus = message; self.playbackStatus = message
            }
            self.serviceReady = false; self.realIsPlaying = false
            self.isWorkerBusy = self.disconnecting; self.session = nil; self.service = nil
            self.generation = UUID()
            self.workerStatus = message
        }
        do {
            try await router.connect()
            guard generation == token else { return }
            serviceReady = true
            workerStatus = "本机音频服务已连接 · 尚未连接音箱"
        } catch {
            guard generation == token else { return }
            serviceReady = false; service = nil
            workerStatus = error.localizedDescription
        }
        if generation == token { isWorkerBusy = false }
    }

    func disconnectWorker() async {
        guard let service, !disconnecting else { return }
        disconnecting = true
        serviceReady = false
        workerStatus = "正在等待服务清理并退出…"
        isWorkerBusy = true
        do {
            try await service.disconnect()
            workerStatus = "本机服务已退出，清理已确认"
        } catch { workerStatus = error.localizedDescription }
        generation = UUID(); self.service = nil; session = nil
        serviceReady = false; realIsPlaying = false; isWorkerBusy = false
        discoveredDevices = []; routeSelections = []
        selectedAudioURL = nil; audioInfo = nil
        disconnecting = false
    }

    func scanDevices() async {
        guard let service, serviceReady, !isWorkerBusy else { return }
        isWorkerBusy = true
        let token = generation
        do {
            let result = try await service.request("scan", timeout: 20)
            guard generation == token else { return }
            guard let devices = result.payload["devices"]?.array, devices.count <= 64,
                  devices.allSatisfy({ value in
                      guard let fields = value.object,
                            let address = fields["address"]?.string, !address.isEmpty,
                            let name = fields["name"]?.string,
                            let model = fields["model"]?.string else { return false }
                      return address.count <= 1024 && name.count <= 1024 && model.count <= 1024
                  }) else { throw WorkerFailure.protocolViolation("Invalid device list") }
            var seen = Set<String>()
            discoveredDevices = devices.compactMap { value in
                guard let fields = value.object, let host = fields["address"]?.string,
                      !host.isEmpty, seen.insert(host).inserted else { return nil }
                return DiscoveredDevice(name: fields["name"]?.string ?? host, host: host)
            }
            routeSelections = discoveredDevices.map {
                .init(id: $0.id, name: $0.name, host: $0.host,
                      rightChannel: audioInfo?.channels == 1 ? 0 : 1)
            }
            workerStatus = "发现 \(discoveredDevices.count) 个设备 · 请显式选择独立音箱"
        } catch {
            if case WorkerFailure.protocolViolation(let message) = error { service.client.abortProtocol(message) }
            if generation == token { workerStatus = error.localizedDescription }
        }
        if generation == token { isWorkerBusy = false }
    }

    func selectAudioFile(_ url: URL) async {
        guard let service, serviceReady, !isWorkerBusy else { return }
        selectedAudioURL = url; audioInfo = nil; lastResultPayload = [:]
        isWorkerBusy = true
        let token = generation
        do {
            let result = try await service.request("inspect", params: ["wav": .string(url.path)])
            guard generation == token else { return }
            guard let sampleRate = result.payload["sample_rate"]?.number,
                  let channels = result.payload["channels"]?.number,
                  let frames = result.payload["frames"]?.number,
                  let duration = result.payload["duration_seconds"]?.number,
                  sampleRate > 0, sampleRate <= 384000, channels >= 1, channels <= 32,
                  frames >= 1, frames <= Double(Int.max / 2), duration > 0, duration <= 3600,
                  sampleRate.rounded() == sampleRate, channels.rounded() == channels,
                  frames.rounded() == frames, duration.isFinite else {
                throw WorkerFailure.protocolViolation("Invalid audio metadata")
            }
            audioInfo = .init(sampleRate: Int(sampleRate), channels: Int(channels), frames: Int(frames), durationSeconds: duration)
            for index in routeSelections.indices {
                routeSelections[index].leftChannel = 0
                routeSelections[index].rightChannel = channels == 1 ? 0 : 1
            }
            workerStatus = "文件已检查 · \(Int(channels)) 声道，尚未播放"
        } catch {
            if case WorkerFailure.protocolViolation(let message) = error { service.client.abortProtocol(message) }
            if generation == token { workerStatus = error.localizedDescription }
        }
        if generation == token { isWorkerBusy = false }
    }

    func runOfflineCheck(mode: PlaybackMode) async {
        await start(mode: mode, volume: 0, execution: "offline")
    }
    func startFilePlayback(mode: PlaybackMode, volume: Double) async {
        await start(mode: mode, volume: volume, execution: "airplay")
    }

    private func start(mode: PlaybackMode, volume: Double, execution: String) async {
        guard let service, serviceReady, !isWorkerBusy, session == nil else { return }
        guard let audioInfo, let selectedAudioURL else { workerStatus = "请先选择并检查 WAV 文件"; return }
        guard volume.isFinite, (0...100).contains(volume) else { workerStatus = "无效的启动音量"; return }
        var selections = routeSelections.filter(\.isSelected)
        if execution == "airplay", selections.isEmpty { workerStatus = "请先显式选择独立音箱"; return }
        if selections.isEmpty {
            selections = [.init(id: "offline", name: "离线输出", host: "", isSelected: true,
                                rightChannel: audioInfo.channels == 1 ? 0 : 1)]
        }
        var routes: [JSONValue] = []
        for (index, selection) in selections.enumerated() {
            let left = mode == .synchronized ? 0 : selection.leftChannel
            let right = mode == .synchronized ? (audioInfo.channels == 1 ? 0 : 1) : selection.rightChannel
            guard (0..<audioInfo.channels).contains(left), (0..<audioInfo.channels).contains(right) else {
                workerStatus = "声道映射超出文件声道范围"; return
            }
            var route: [String: JSONValue] = ["output_id": .integer(index),
                "channels": .array([.integer(left), .integer(right)])]
            if execution == "airplay" { route["host"] = .string(selection.host) }
            routes.append(.object(route))
        }
        let currentSession = UUID().uuidString
        session = currentSession
        isWorkerBusy = true
        lastResultPayload = [:]
        let token = generation
        if execution == "offline" { offlineCheckStatus = "正在进行本机原生核心离线验证（不出声）…" }
        else { playbackStatus = "正在准备文件播放 · 尚未确认发送" }
        let params: [String: JSONValue] = ["session": .string(currentSession),
            "library": .string(service.runtime.library), "wav": .string(selectedAudioURL.path),
            "execution": .string(execution), "routes": .array(routes), "volume": .number(volume),
            "lead_seconds": .number(8)]
        do {
            let result = try await service.request("start", params: params, session: currentSession,
                timeout: max(30, audioInfo.durationSeconds + 30))
            guard generation == token, session == currentSession else { return }
            lastResultPayload = result.payload
            guard let state = result.payload["state"]?.string,
                  ["completed", "stopped"].contains(state),
                  result.payload["cleanup_complete"]?.bool == true,
                  let report = result.payload["report"]?.object,
                  report["cleanup_complete"]?.bool == true,
                  report["input_closed"]?.bool == true,
                  report["hub_stopped"]?.bool == true else {
                throw WorkerFailure.protocolViolation("Missing terminal state/cleanup report")
            }
            if state == "completed" {
                guard report["native_core_used"]?.bool == true,
                      report["group_failed"]?.bool == false,
                      report["acoustic_sync_verified"]?.bool == false,
                      report["native_submitted_frames"]?.number == Double(audioInfo.frames),
                      let outputs = report["outputs"]?.array, outputs.count == routes.count,
                      outputs.allSatisfy({ output in
                          guard let fields = output.object,
                                fields["native_frames"]?.number == Double(audioInfo.frames),
                                fields["consumed_frames"]?.number == Double(audioInfo.frames),
                                let native = fields["native_pcm_sha256"]?.string,
                                let consumed = fields["consumed_pcm_sha256"]?.string else { return false }
                          return native.count == 64 && native == consumed
                      }),
                      execution != "offline" || report["network_used"]?.bool == false else {
                    throw WorkerFailure.protocolViolation("Missing native completion evidence")
                }
            }
            if execution == "offline" { offlineCheckStatus = state == "stopped" ? "离线验证已停止" : "离线验证完成 · 请查看实际报告" }
            else { playbackStatus = state == "stopped" ? "文件播放已停止" : "文件播放已结束 · 声学同步需另行测量" }
        } catch {
            if case WorkerFailure.protocolViolation(let message) = error {
                service.client.abortProtocol(message)
            }
            if generation == token, session == currentSession {
                if execution == "offline" { offlineCheckStatus = error.localizedDescription }
                else { playbackStatus = error.localizedDescription }
            }
        }
        if generation == token, session == currentSession {
            session = nil; realIsPlaying = false; isWorkerBusy = false
        }
    }

    func stopFilePlayback() async {
        guard let service, let currentSession = session else { return }
        let token = generation
        playbackStatus = "正在等待会话停止与清理确认…"
        do {
            let result = try await service.request("stop", params: ["session": .string(currentSession)],
                                                   session: currentSession, timeout: 10)
            guard generation == token, session == nil || session == currentSession else { return }
            guard result.payload["cleanup_complete"]?.bool == true else { throw WorkerFailure.cleanupUnconfirmed }
            playbackStatus = "会话已停止 · 清理已确认"
        } catch {
            if generation == token, session == nil || session == currentSession {
                playbackStatus = error.localizedDescription
            }
        }
        // The original start request remains authoritative for its terminal event.
    }

    private func receive(_ event: WorkerEvent) {
        if event.id == nil, event.event == "error" {
            workerStatus = "服务协议警告：\(event.payload["message"]?.string ?? "无法关联的请求错误")"
            return
        }
        guard let eventSession = event.session, eventSession == session else { return }
        if event.event == "state", let state = event.payload["state"]?.string {
            if state == "streaming" {
                realIsPlaying = true
                playbackStatus = "文件流正在发送 · 不代表声学同步已测量"
            } else if ["completed", "stopped", "failed"].contains(state) { realIsPlaying = false }
        }
    }
}
