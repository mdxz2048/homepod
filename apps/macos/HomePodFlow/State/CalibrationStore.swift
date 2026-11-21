import Foundation
import Observation

@Observable @MainActor final class CalibrationStore {
    private(set) var isBusy = false
    private(set) var phase = "准备好，让声音同时抵达。"
    private(set) var activeDeviceID: UUID?
    private(set) var completed: [SpeakerLatencyMeasurement] = []
    private(set) var candidate: AcousticCalibrationProfile?
    private(set) var saved: AcousticCalibrationProfile?
    private(set) var errorText = ""
    private(set) var progress = 0.0
    private(set) var microphoneName = "Mac 内置或 USB 麦克风"
    private(set) var emitting = false
    private(set) var verifying = false
    private(set) var currentVolume = 10.0
    private(set) var testVolume = 10.0
    private(set) var pulseIndex = -1
    private(set) var probeKind: ProbeKind = .sweep
    private(set) var microphoneUID: String?
    private(set) var microphones: [InputMicrophone] = []
    private(set) var diagnostics: [[String: JSONValue]] = []
    @ObservationIgnored private var activeMicrophone: CalibrationMicrophone?
    @ObservationIgnored private var activePlayer: CalibrationProbePlayer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingMicrophoneUID: String?
    @ObservationIgnored private var pendingLayout: RoomLayout?
    private static let routeKey = "homepod-flow.calibration.previous-output"
    private static let key = "homepod-flow.acoustic-calibration.v1"
    private static let volumeKey = "homepod-flow.calibration.test-volume"
    private static let probeKindKey = "homepod-flow.calibration.probe-kind"
    private static let microphoneKey = "homepod-flow.calibration.microphone"
    static let volumeRange = 1.0...100.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.volumeKey) as? Double, stored.isFinite {
            testVolume = min(Self.volumeRange.upperBound, max(Self.volumeRange.lowerBound, stored)).rounded()
        }
        if let stored = defaults.string(forKey: Self.probeKindKey), let kind = ProbeKind(rawValue: stored) {
            probeKind = kind
        }
        microphones = CalibrationMicrophone.available()
        microphoneUID = defaults.string(forKey: Self.microphoneKey)
        if let microphoneUID, !microphones.contains(where: { $0.id == microphoneUID }) {
            self.microphoneUID = nil
        }
        if microphoneUID == nil, let phone = microphones.first(where: { $0.isContinuity }) {
            // A phone sitting at the listening position hears the room far
            // better than a laptop lid, so prefer it when one is paired.
            self.microphoneUID = phone.id
        }
        currentVolume = testVolume
        if let previous = defaults.string(forKey: Self.routeKey) {
            let route = DefaultOutputRouteService()
            if route.currentDefaultOutputUID() != FlowVirtualDevice.uid || route.restoreDefaultOutput(uid: previous) {
                defaults.removeObject(forKey: Self.routeKey)
            }
        }
        saved = defaults.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode(AcousticCalibrationProfile.self, from: $0)
        }
    }
    func refreshMicrophones() {
        microphones = CalibrationMicrophone.available()
        if microphoneUID == nil, let phone = microphones.first(where: { $0.isContinuity }) {
            microphoneUID = phone.id
        }
    }

    func setMicrophone(_ uid: String?) {
        guard !isBusy else { return }
        microphoneUID = uid
        if let uid { defaults.set(uid, forKey: Self.microphoneKey) }
        else { defaults.removeObject(forKey: Self.microphoneKey) }
        resetPresentation()
    }

    func setProbeKind(_ kind: ProbeKind) {
        guard !isBusy, kind != probeKind else { return }
        probeKind = kind
        defaults.set(kind.rawValue, forKey: Self.probeKindKey)
        resetPresentation()
    }

    func setTestVolume(_ volume: Double) {
        guard !isBusy, volume.isFinite else { return }
        let selected = min(Self.volumeRange.upperBound, max(Self.volumeRange.lowerBound, volume)).rounded()
        guard selected != testVolume else { return }
        testVolume = selected
        defaults.set(selected, forKey: Self.volumeKey)
        // Changing level starts a fresh measurement, including the sequential verification.
        resetPresentation()
    }
    func residuals(for layout: RoomLayout) -> [String: Double]? {
        guard let saved, saved.matches(layout), saved.verification?.passed == true else { return nil }
        return Dictionary(uniqueKeysWithValues: saved.measurements.map { ($0.stableIdentifier, $0.residualMS) })
    }
    func resetPresentation() {
        guard !isBusy else { return }
        candidate = nil; completed = []; errorText = ""; activeDeviceID = nil
        pendingLayout = nil; pendingMicrophoneUID = nil; verifying = false; currentVolume = testVolume; pulseIndex = -1
        diagnostics = []; progress = 0; phase = "准备好，让声音同时抵达。"
    }
    func save(for layout: RoomLayout) {
        guard !isBusy, let candidate, candidate.matches(layout), candidate.verification?.passed == true,
              let data = try? JSONEncoder().encode(candidate) else { return }
        defaults.set(data, forKey: Self.key); saved = candidate
        phase = "校准已自动保存 · 声卡延迟已写入"
    }
    func clear() {
        guard !isBusy else { return }
        saved = nil; candidate = nil; defaults.removeObject(forKey: Self.key)
    }
    func begin(layout: RoomLayout) {
        guard !isBusy, !layout.devices.isEmpty, layout.devices.count <= 8 else { return }
        // A retry preserves completed speakers only for the identical saved room.
        if pendingLayout != layout || errorText.isEmpty { resetPresentation() }
        pendingLayout = layout; errorText = ""; candidate = nil; isBusy = true
        task = Task { await run(layout: layout) }
    }
    func cancel() {
        guard isBusy else { return }
        phase = "正在停止测试…"; activePlayer?.stop(); activeMicrophone?.stop(); task?.cancel()
    }
    func waitUntilFinished() async { await task?.value }
    func shutdown() async { cancel(); await task?.value }

    private func trace(_ message: String) {
        #if DEBUG
        guard let report = Bundle.main.object(forInfoDictionaryKey: "FlowCalibrationE2EReport") as? String else { return }
        let path = URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("calibration-trace.txt")
        let line = Data("\(Date()) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n".utf8)
        if let file = try? FileHandle(forWritingTo: path) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: line); try? file.close()
        } else { try? line.write(to: path) }
        #endif
    }
    private struct Pass {
        var measurements: [[String: JSONValue]]
        var microphoneUID: String
        var nominalMS: Double
        var targetMS: Double
    }


    /// Keeps the last few failed probe recordings plus their measured evidence
    /// so a quiet microphone or a bad room can be diagnosed without another run.
    static func preserveFailure(recording: URL, code: Int, speaker: String,
                                microphone: String, error: Error,
                                firstSampleNS: Double? = nil, injectionNS: Double? = nil,
                                nominalMS: Double? = nil, probeKind: ProbeKind? = nil,
                                probeRate: Double? = nil) {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first?
            .appendingPathComponent("HomePod Flow/Diagnostics", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = directory.appendingPathComponent("failed-probe-\(formatter.string(from: Date()))-\(code)")
        try? FileManager.default.copyItem(at: recording, to: base.appendingPathExtension("f32"))
        try? FileManager.default.copyItem(at: recording.appendingPathExtension("clock.json"),
                                          to: base.appendingPathExtension("clock.json"))
        let metrics = (try? Data(contentsOf: recording.appendingPathExtension("metrics.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var payload: [String: Any] = ["error": String(describing: error), "code": code,
                                      "speaker": speaker, "microphone": microphone,
                                      "metrics": metrics ?? [:], "signal_version": 4]
        payload["first_sample_ns"] = firstSampleNS.map { $0 as Any } ?? NSNull()
        payload["injection_ns"] = injectionNS.map { $0 as Any } ?? NSNull()
        payload["nominal_ms"] = nominalMS.map { $0 as Any } ?? NSNull()
        payload["probe_kind"] = probeKind?.rawValue ?? NSNull()
        payload["probe_rate"] = probeRate.map { $0 as Any } ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: base.appendingPathExtension("json"), options: .atomic)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("failed-probe-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        let bases = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        for stale in bases.dropLast(6) {
            for suffix in ["f32", "clock.json", "json"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stale).\(suffix)"))
            }
        }
    }

    private func measure(worker: SystemRouterService, targets: [(RoomDevice, String)],
                         volume: Double, calibration: [String: Double]? = nil) async throws -> Pass {
        currentVolume = volume; pulseIndex = -1
        let microphone = CalibrationMicrophone(); activeMicrophone = microphone
        guard let player = activePlayer else { throw WorkerFailure.remote("测试输出会话未准备好") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homepod-probe-\(UUID().uuidString).f32")
        var produced = false
        var preserved = false
        defer {
            // Release the Flow HAL client between passes. Leaving the render
            // engine running keeps the device busy, which makes the next
            // pass's guarded latency write return device_busy and fail the
            // whole calibration. start() creates a fresh engine per pass.
            player.stop(); microphone.stop(); activeMicrophone = nil
            emitting = false; pulseIndex = -1
            // Whatever went wrong, keep the capture so the next diagnosis has
            // real audio instead of only a timestamp report.
            if !produced, !preserved, FileManager.default.fileExists(atPath: url.path) {
                Self.preserveFailure(recording: url, code: -1, speaker: targets.first?.0.name ?? "",
                                     microphone: microphoneName,
                                     error: WorkerFailure.remote(errorText.isEmpty ? "测试未完成" : errorText))
            }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("clock.json"))
        }
        trace("microphone start")
        try await microphone.start(preferredUID: microphoneUID); microphoneName = microphone.name
        trace("microphone ready")
        let sid = UUID().uuidString
        var nominalMS: Double?
        var captureOriginNS: Double?
        var playerStarted = false
        worker.onEvent = { [weak self] event in
            if event.session == sid, let report = event.payload["report"]?.object {
                self?.diagnostics.append(report)
            }
            guard event.session == sid, let probe = event.payload["probe"]?.object,
                  let nominal = probe["nominal_probe_ms"]?.number else { return }
            nominalMS = nominal
            captureOriginNS = probe["playback_origin_ns"]?.number ?? captureOriginNS
        }
        let routes: [JSONValue] = targets.enumerated().map { index, target in
            .object(["output_id": .integer(index), "channels": .array([.integer(0), .integer(1)]),
                     "host": .string(target.1)])
        }
        var params: [String: JSONValue] = [
            "session": .string(sid), "library": .string(worker.runtime.library),
            "capture_host": .string(worker.runtime.virtual_capture_host ?? ""), "probe": .bool(true),
            "volume": .number(volume), "mode": .string("cinema"), "routes": .array(routes),
            "input": .object(["backend": .string("virtual_device_v2"),
                "device_uid": .string(FlowVirtualDevice.uid), "layout": .string("7_1"),
                "latency_control": .string(worker.runtime.latency_control ?? "")])]
        if let calibration {
            params["calibration"] = .object(Dictionary(uniqueKeysWithValues: targets.enumerated().map { index, target in
                (String(index), JSONValue.number(calibration[target.0.stableIdentifier ?? ""]!))
            }))
        }
        trace("start worker session volume \(volume)")
        var playbackError: (any Error)?
        let playback = Task {
            do { return try await worker.request("start", params: params, session: sid, timeout: 70) }
            catch { playbackError = error; throw error }
        }
        let commonResidual = max(0, calibration?.values.max() ?? 0)
        var injectionNS: Double?
        var result: WorkerEvent
        do {
            let deadline = Date().addingTimeInterval(55)
            while true {
                try Task.checkCancellation()
                if let playbackError { throw playbackError }
                if player.clockFailed { throw WorkerFailure.remote("测试输出缺少硬件时间戳，请重新测试。") }
                if nominalMS != nil, !playerStarted {
                    trace("start Flow probe renderer")
                    try player.start(channels: targets.count, kind: probeKind); playerStarted = true
                    trace("Flow probe renderer ready")
                }
                if captureOriginNS != nil, !emitting {
                    trace("capture confirmed; arm test tones")
                    player.beginProbe(); emitting = true
                    phase = verifying ? "正在逐台复验 · \(Int(volume))% 音量" : "正在聆听 \(targets[0].0.name) · \(Int(volume))% 音量"
                }
                if let origin = player.injectionNS, let nominalMS {
                    injectionNS = origin
                    let elapsed = (Double(DispatchTime.now().uptimeNanoseconds) - origin) / 1e9
                    // Rings follow expected acoustic arrivals, never callback delivery.
                    let fullCount = pendingLayout?.devices.count ?? targets.count
                    let fraction = min(0.95, max(0, elapsed / (CalibrationSignal.start + CalibrationSignal.duration + 0.8 + (nominalMS + commonResidual) / 1000)))
                    progress = (Double(verifying ? fullCount : completed.count) + fraction) / Double(fullCount + 1)
                    let heard = elapsed - (nominalMS + commonResidual) / 1000
                    pulseIndex = heard >= CalibrationSignal.start && heard < CalibrationSignal.start + CalibrationSignal.duration ? Int((heard - CalibrationSignal.start) / CalibrationSignal.period) : -1
                    if elapsed >= CalibrationSignal.start + CalibrationSignal.duration + (nominalMS + commonResidual) / 1000 + 0.8 { break }
                }
                guard Date() < deadline else { throw WorkerFailure.remote("音箱准备超时，请检查网络后重试。") }
                try await Task.sleep(for: .milliseconds(40))
            }
            trace("tones ended; stop worker")
            player.silence(); emitting = false
            let stop = try await worker.request("stop", params: ["session": .string(sid)], session: sid, timeout: 20)
            guard stop.payload["cleanup_complete"]?.bool == true else { throw WorkerFailure.cleanupUnconfirmed }
            result = try await playback.value
            guard result.payload["cleanup_complete"]?.bool == true else { throw WorkerFailure.cleanupUnconfirmed }
        } catch {
            phase = "正在停止测试并清理音频会话…"
            player.stop(); microphone.stop()
            try? await worker.disconnect(); _ = await playback.result
            throw error
        }
        if var report = result.payload["report"]?.object {
            report["calibration_volume"] = .number(volume)
            report["calibration_injection_ns"] = injectionNS.map(JSONValue.number) ?? .null
            report["calibration_render_lead_ms"] = player.clockLeadMS.map(JSONValue.number) ?? .null
            diagnostics.append(report)
        }
        trace("worker stopped; finish microphone: \(microphone.diagnostics)")
        let recording = try microphone.finish(to: url)
        trace("microphone complete; analyze")
        guard let injectionNS, let nominalMS,
              result.payload["report"]?.object?["probe_version"]?.number == 2 else {
            throw WorkerFailure.remote("缺少完整音频链路的测试时间戳，请重试。")
        }
        let targetMS = ceil(nominalMS + commonResidual)
        var measurements: [[String: JSONValue]] = []
        for index in targets.indices {
            try Task.checkCancellation()
            do {
                let analyzed = try await worker.request("analyze_probe", params: [
                    "recording": .string(url.path), "clock": .string(url.appendingPathExtension("clock.json").path),
                    "sample_rate": .number(recording.rate),
                    "first_sample_ns": .number(recording.firstNS), "presentation_ns": .number(injectionNS),
                    "injection_ns": .number(injectionNS), "code": .integer(index), "signal_version": .integer(4),
                    "diagnostics_path": .string(url.appendingPathExtension("metrics.json").path),
                    "probe_kind": .string(probeKind.rawValue), "probe_rate": .number(player.rate),
                    "nominal_ms": .number(nominalMS), "expected_latency_ms": .number(targetMS)], timeout: 20)
                measurements.append(analyzed.payload)
                diagnostics.append(["analysis": .object(analyzed.payload), "speaker": .string(targets[index].0.name)])
                trace("analysis \(index): \(analyzed.payload)")
            } catch {
                Self.preserveFailure(recording: url, code: index, speaker: targets[index].0.name,
                                     microphone: microphone.name, error: error,
                                     firstSampleNS: recording.firstNS, injectionNS: injectionNS,
                                     nominalMS: nominalMS, probeKind: probeKind,
                                     probeRate: player.rate)
                preserved = true
                throw error
            }
        }
        produced = true
        return Pass(measurements: measurements, microphoneUID: microphone.uid, nominalMS: nominalMS, targetMS: targetMS)
    }

    private func run(layout: RoomLayout) async {
        var service: SystemRouterService?
        var success = false
        var originalTarget: Int?
        let outputRoute = DefaultOutputRouteService()
        // One player object owns the sequential run; its HAL client is opened
        // per pass and released afterwards so latency writes see an idle device.
        activePlayer = CalibrationProbePlayer()
        var previousOutput: String?
        defer {
            activePlayer?.stop(); activePlayer = nil
            isBusy = false; emitting = false; activeDeviceID = nil; verifying = false; task = nil
            // Timing/cleanup diagnostics only; microphone PCM is never retained.
            if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("HomePod Flow/Diagnostics", isDirectory: true) {
                let report: [String: JSONValue] = ["phase": .string(phase), "error": .string(errorText),
                    "volume": .number(testVolume), "microphone": .string(microphoneName),
                    "probe_kind": .string(probeKind.rawValue),
                    "reports": .array(diagnostics.map(JSONValue.object))]
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(report) {
                    try? data.write(to: directory.appendingPathComponent("calibration-last-run.json"), options: .atomic)
                }
            }
        }
        do {
            phase = "正在确认已绑定的音箱…"
            trace("connect service")
            let worker = try SystemRouterService.installed(); service = worker
            try await worker.connect()
            let hello = try await worker.request("hello")
            guard hello.payload["capabilities"]?.object?["acoustic_calibration_v4"]?.bool == true,
                  worker.runtime.virtual_capture_host != nil, worker.runtime.latency_control != nil else {
                throw WorkerFailure.remote("请更新应用与运行环境，完整链路校准需要 Flow 音频组件。")
            }
            guard AudioOccupancyService.shared.isDeviceRunning(uid: FlowVirtualDevice.uid) != true else {
                throw WorkerFailure.remote("请先关闭系统声音及占用 Flow 声卡的播放器，再开始测试。")
            }
            let knownHosts = layout.devices.compactMap(\.host).map(JSONValue.string)
            phase = "正在查找音箱 · 首次连接可能需要稍等片刻…"
            let discovered = try await worker.request("scan", params: ["hosts": .array(knownHosts),
                "expected_identifiers": .array(layout.devices.map { .string($0.stableIdentifier ?? "") }),
                "timeout_seconds": .integer(4)], timeout: 35)
            let values = discovered.payload["devices"]?.array?.compactMap(\.object) ?? []
            diagnostics.append(["discovered_receivers": .array(values.map(JSONValue.object)),
                                "expected_identifiers": .array(layout.devices.map { .string($0.stableIdentifier ?? "") })])
            var targets: [(RoomDevice, String)] = []
            for device in layout.devices {
                guard let identity = device.stableIdentifier, !identity.isEmpty else {
                    throw WorkerFailure.remote("请重新添加音箱以确认设备身份，再进行测试。")
                }
                let matches = values.filter { $0["identifier"]?.string == identity }
                guard matches.count == 1, let host = matches.first?["address"]?.string else {
                    throw WorkerFailure.remote("找不到 \(device.name)，请检查电源和网络。")
                }
                targets.append((device, host))
            }
            let original = try await worker.request("calibration_snapshot", params: ["helper": .string(worker.runtime.latency_control!)])
            originalTarget = original.payload["target_ms"]?.number.map { Int($0) }
            phase = "正在确认麦克风权限…"
            try await CalibrationMicrophone.requirePermission()
            try Task.checkCancellation()
            guard let previous = outputRoute.currentDefaultOutputUID(), previous != FlowVirtualDevice.uid else {
                throw WorkerFailure.remote("请先关闭影院播放并恢复系统输出，再进行校准。")
            }
            trace("receivers resolved; route to cinema")
            defaults.set(previous, forKey: Self.routeKey)
            previousOutput = previous
            guard try outputRoute.setDefaultOutput(uid: FlowVirtualDevice.uid) else {
                throw WorkerFailure.remote("影院模式未能切换系统输出到 Flow")
            }
            trace("cinema output ready; snapshot done")
            var micUID = pendingMicrophoneUID
            var failures: [String] = []
            for (index, target) in targets.enumerated() {
                if completed.contains(where: { $0.id == target.0.id }) { continue }
                activeDeviceID = target.0.id
                progress = Double(index) / Double(targets.count + 1)
                let volume = testVolume
                try Task.checkCancellation()
                phase = "正在准备 \(target.0.name) · \(Int(volume))% 音量"
                do {
                    let pass = try await measure(worker: worker, targets: [target], volume: Double(volume))
                    if let micUID, micUID != pass.microphoneUID {
                        throw WorkerFailure.remote("麦克风发生变化，请重新测试全部音箱。")
                    }
                    micUID = pass.microphoneUID; pendingMicrophoneUID = pass.microphoneUID
                    let p = pass.measurements[0]
                    guard let measured = p["measured_ms"]?.number, let residual = p["residual_ms"]?.number,
                          let spread = p["spread_ms"]?.number, let confidence = p["confidence"]?.number,
                          (p["sample_count"]?.number ?? 0) >= 4,
                          p["version"]?.number == 4,
                          p["matched_duration_seconds"]?.number == CalibrationSignal.duration else {
                        throw WorkerFailure.protocolViolation("测试结果不完整")
                    }
                    let measurement = SpeakerLatencyMeasurement(id: target.0.id,
                        stableIdentifier: target.0.stableIdentifier!, name: target.0.name,
                        measuredMS: measured, nominalMS: pass.nominalMS, residualMS: residual,
                        spreadMS: spread, confidence: confidence, measuredAt: Date(), testVolume: Double(volume),
                        sampleCount: Int(p["sample_count"]?.number ?? 0),
                        driftMSPerSecond: p["drift_ms_per_second"]?.number,
                        windowResidualsMS: p["window_residuals_ms"]?.array?.compactMap(\.number))
                    guard measurement.isValid else { throw WorkerFailure.remote("测量结果超出校准范围，请重试。") }
                    completed.append(measurement)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = error.localizedDescription
                    failures.append("\(target.0.name)：\(reason)")
                    diagnostics.append(["speaker": .string(target.0.name),
                                        "measurement_failed": .string(reason)])
                    if reason.contains("麦克风发生变化") { break }
                }
            }
            if !failures.isEmpty {
                errorText = failures.joined(separator: "；")
                phase = "\(failures.count) 台音箱未完成，请查看各台原因"
                throw WorkerFailure.remote("逐台测量未全部通过：\(errorText)")
            }
            try Task.checkCancellation()
            verifying = true; activeDeviceID = nil
            let residuals = Dictionary(uniqueKeysWithValues: completed.map { ($0.stableIdentifier, $0.residualMS) })
            var verifiedMS: [Double] = []
            var verificationFailures: [String] = []
            var verificationTargetMS: Double = 0
            for (index, target) in targets.enumerated() {
                activeDeviceID = target.0.id
                phase = "正在逐台复验 \(target.0.name) · \(index + 1)/\(targets.count)"
                do {
                    let pass = try await measure(worker: worker, targets: [target], volume: testVolume,
                                                 calibration: residuals)
                    if let micUID, micUID != pass.microphoneUID {
                        throw WorkerFailure.remote("麦克风发生变化，请重新测试全部音箱。")
                    }
                    guard let measured = pass.measurements.first?["measured_ms"]?.number else {
                        throw WorkerFailure.protocolViolation("复验结果不完整")
                    }
                    verificationTargetMS = pass.targetMS
                    verifiedMS.append(measured)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    verificationFailures.append("\(target.0.name)：\(error.localizedDescription)")
                }
            }
            if !verificationFailures.isEmpty {
                completed = []
                errorText = verificationFailures.joined(separator: "；")
                throw WorkerFailure.remote("逐台复验未通过：\(errorText)")
            }
            guard verifiedMS.count == targets.count else { throw WorkerFailure.protocolViolation("复验结果不完整") }
            let verification = CalibrationVerification(measuredMS: verifiedMS, targetMS: verificationTargetMS,
                spreadMS: (verifiedMS.max() ?? 0) - (verifiedMS.min() ?? 0),
                maximumErrorMS: verifiedMS.map { abs($0 - verificationTargetMS) }.max() ?? 999,
                volume: currentVolume, verifiedAt: Date())
            guard verification.passed else {
                // Repeating must remeasure the inputs rather than reuse a suspect group.
                completed = []
                throw WorkerFailure.remote("逐台复验未通过（音箱间 \(Int(verification.spreadMS.rounded())) ms，目标误差 \(Int(verification.maximumErrorMS.rounded())) ms），请重试。")
            }
            activePlayer?.stop()
            phase = "正在写入声卡并保存校准…"
            _ = try await worker.request("calibration_latency", params: [
                "helper": .string(worker.runtime.latency_control!), "target_ms": .integer(Int(verificationTargetMS))], timeout: 20)
            try Task.checkCancellation()
            if let previousOutput, outputRoute.currentDefaultOutputUID() == FlowVirtualDevice.uid {
                guard outputRoute.restoreDefaultOutput(uid: previousOutput) else {
                    throw WorkerFailure.remote("校准完成，但系统输出恢复未确认，请检查声音设置。")
                }
                defaults.removeObject(forKey: Self.routeKey)
            }
            guard let finalMicUID = micUID else { throw WorkerFailure.protocolViolation("麦克风身份缺失") }
            let profile = AcousticCalibrationProfile(layout: layout, microphoneUID: finalMicUID,
                measurements: completed, savedAt: Date(), verification: verification)
            guard profile.matches(layout), let data = try? JSONEncoder().encode(profile) else {
                throw WorkerFailure.protocolViolation("无法保存校准")
            }
            defaults.set(data, forKey: Self.key); saved = profile; candidate = profile
            progress = 1; success = true
            phase = "校准已自动保存 · 声卡延迟已写入"
        } catch is CancellationError {
            trace("cancelled")
            phase = "测试已取消 · 原有校准保持不变"; candidate = nil
        } catch {
            trace("failed: \(error.localizedDescription)")
            errorText = error.localizedDescription
            phase = "这次没有完成，请稍后再试。"; candidate = nil
        }
        activePlayer?.stop(); activeMicrophone?.stop()
        trace("disconnect worker")
        if let service { try? await service.disconnect() }
        trace("worker disconnected")
        if let previousOutput {
            if outputRoute.currentDefaultOutputUID() != FlowVirtualDevice.uid || outputRoute.restoreDefaultOutput(uid: previousOutput) {
                defaults.removeObject(forKey: Self.routeKey)
            } else { errorText += " · 系统默认输出恢复未确认。" }
        }
        if !success, let originalTarget, let service, let helper = service.runtime.latency_control {
            do {
                try await service.connect()
                _ = try await service.request("calibration_latency", params: ["helper": .string(helper), "target_ms": .integer(originalTarget)])
                try await service.disconnect()
            } catch { errorText += " · 原声卡延迟恢复未确认：\(error.localizedDescription)" }
        }
    }
}
