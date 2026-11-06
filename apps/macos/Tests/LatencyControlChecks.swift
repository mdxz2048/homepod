import Foundation

@main struct LatencyControlChecks {
    @MainActor static func main() async {
        precondition(LatencyEstimate.defaultMilliseconds == 2000)
        precondition(LatencyEstimate.resolve(configuredMS: nil) == 2000)
        precondition(LatencyEstimate.resolve(configuredMS: .infinity) == 2000)
        precondition(LatencyEstimate.resolve(configuredMS: -5) == 0)
        precondition(LatencyEstimate.resolve(configuredMS: 9999) == 3000)
        precondition(LatencyEstimate.defaultMilliseconds
            == LatencyEstimate.observedSamples * 1000 / LatencyEstimate.observedSampleRate + LatencyEstimate.preparationMS)

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 88200)))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            precondition(result.state.kind == .reported)
            precondition(result.state.applied == false)
            precondition(result.verified != nil && result.verified?.hflaMS == 2000)
            precondition(result.state.statusText.contains("未写入"))
            precondition(runner.invocations.count == 1)
            precondition(runner.invocations[0].arguments == ["status"])
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0, running: true)))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            precondition(result.state.kind == .deferredPending)
            precondition(result.verified == nil)
            precondition(result.state.pendingReason != nil)
            precondition(runner.invocations.count == 1)
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0)))
            runner.append(status: applyObject(applied: true, target: snapshot(frames: 88200)))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            precondition(result.state.kind == .applied)
            precondition(result.verified != nil)
            precondition(result.state.statusText.contains("已回读验证"))
            precondition(runner.invocations.count == 2)
            precondition(runner.invocations[1].arguments == ["set-ms", "2000", "--expect-revision", "7"])
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0, uid: "com.other.device")))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            if case .invalid = result.state.kind {} else { preconditionFailure("wrong-device status must be invalid") }
            precondition(result.verified == nil)
            precondition(runner.invocations.count == 1)
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0, scopesMatch: false)))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            if case .invalid = result.state.kind {} else { preconditionFailure("scope mismatch must be invalid") }
            precondition(runner.invocations.count == 1)
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0)))
            runner.append(status: ["ok": false, "error": ["kind": "device_busy", "message": "in use"]])
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            let result = await service.prepare()
            precondition(result.state.kind == .deferredPending)
            precondition(result.verified == nil)
            precondition(runner.invocations.count == 2)
        }

        await assertScripted { runner in
            runner.append(status: statusObject(device: snapshot(frames: 0)))
            let service = LatencyControlService(executablePath: "/hflctl", configuredMS: 2000, runner: runner)
            _ = await service.prepare()
            let report = VerifiedLatencyReport(nominalRate: 44100, hflaFrames: 88200, hflaMS: 2000,
                                              revision: 7, deviceRunning: false)
            precondition(report.workerObject["verified"] == .bool(true))
            precondition(report.workerObject["uid"] == .string("com.homepodflow.virtual-audio.surround71.v1"))
            precondition(report.workerObject["hfla_frames"] == .integer(88200))
            precondition(report.workerObject["stream_latency_global_frames"] == .integer(88200))
        }

        await assertStorePassesVerifiedReport()
        await assertStoreSkipsDeferredReport()
        print("LatencyControlChecks: estimate formula, verified/busy/invalid report paths, bounded helper contract and store wiring passed")
    }

    @MainActor private static func assertScripted(_ body: (ScriptedLatencyRunner) async -> Void) async {
        let runner = ScriptedLatencyRunner()
        await body(runner)
    }

    @MainActor private static func assertStorePassesVerifiedReport() async {
        let service = LatencyStoreService()
        let verified = VerifiedLatencyReport(nominalRate: 44100, hflaFrames: 88200, hflaMS: 2000,
                                             revision: 7, deviceRunning: false)
        let controller = FixedLatencyPreparing(LatencyControlPreparation(
            state: LatencyControlState(kind: .reported, estimatedMS: 2000, reportedMS: 2000,
                                       revision: 7, applied: false, statusText: "已验证"), verified: verified))
        let store = SystemAudioStore(serviceFactory: { service },
            latencyFactory: { _ in controller }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        await store.start(mode: .synchronized, volume: 15)
        precondition(controller.prepareCalls == 2)
        let input = service.startParameters?["input"]?.object
        precondition(input?["latency_report"]?.object?["verified"] == .bool(true))
        precondition(input?["latency_report"]?.object?["hfla_ms"] == .number(2000))
        precondition(!store.cleanupRequiresAttention)
        await store.prepareForTermination()
        precondition(service.shutdowns == 1)
    }

    @MainActor private static func assertStoreSkipsDeferredReport() async {
        let service = LatencyStoreService()
        let controller = FixedLatencyPreparing(LatencyControlPreparation(
            state: LatencyControlState(kind: .deferredPending, estimatedMS: 2000, reportedMS: nil,
                                       revision: nil, applied: false, statusText: "已延后",
                                       pendingReason: "占用中"), verified: nil))
        let store = SystemAudioStore(serviceFactory: { service },
            latencyFactory: { _ in controller }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        await store.start(mode: .synchronized, volume: 15)
        let input = service.startParameters?["input"]?.object
        precondition(input?["latency_report"] == nil)
        precondition(store.latencyState?.kind == .deferredPending)
        await store.prepareForTermination()
    }
}

@MainActor final class FixedLatencyPreparing: LatencyControlPreparing {
    let preparation: LatencyControlPreparation
    var prepareCalls = 0
    var enabled: Bool { true }
    init(_ preparation: LatencyControlPreparation) { self.preparation = preparation }
    func prepare() async -> LatencyControlPreparation {
        prepareCalls += 1
        return preparation
    }
}

@MainActor final class ScriptedLatencyRunner: LatencyControlRunning {
    struct Response { let exitCode: Int32; let stdout: Data; let stderr: Data }
    private var responses: [Response] = []
    private(set) var invocations: [(executable: String, arguments: [String])] = []
    func append(status object: [String: Any], exitCode: Int32 = 0) {
        responses.append(Response(exitCode: exitCode, stdout: jsonData(object), stderr: Data()))
    }
    func run(executable: String, arguments: [String],
             timeout: TimeInterval) async throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        invocations.append((executable, arguments))
        guard !responses.isEmpty else { return (0, Data(), Data()) }
        let next = responses.removeFirst()
        return (next.exitCode, next.stdout, next.stderr)
    }
    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private func snapshot(frames: Int, uid: String = LatencyControlService.deviceUID,
                      running: Bool = false, scopesMatch: Bool = true,
                      controlMatch: Bool = true) -> [String: Any] {
    [
        "uid": uid,
        "model_uid": LatencyControlService.modelUID,
        "alive": true,
        "channels": 8,
        "nominal_rate": 44100.0,
        "hfla_frames": frames,
        "hfla_ms": Double(frames) * 1000.0 / 44100.0,
        "hflr": 7,
        "stream_latency_global_frames": frames,
        "stream_latency_output_frames": frames,
        "latency_scopes_match": scopesMatch,
        "control_scope_match": controlMatch,
        "device_is_running": running,
        "device_is_running_somewhere": false,
    ]
}

private func statusObject(device: [String: Any]) -> [String: Any] {
    ["ok": true, "command": "status", "device": device]
}

private func applyObject(applied: Bool, target: [String: Any]) -> [String: Any] {
    ["ok": true, "command": "set-ms", "applied": applied, "after": target,
     "verified": ["hfla_frames": true, "stream_latency_global": true,
                  "stream_latency_output": true, "revision": true]]
}

@MainActor private final class LatencyStoreService: SystemAudioRouting {
    let runtime = SystemAudioRuntime(python: "/python", project: "/project", library: "/core",
        capture_host: "/legacy", virtual_capture_host: "/virtual")
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    let supportsRealtimeVolume = false
    let supportsVirtualInput = true
    var startParameters: [String: JSONValue]?
    var shutdowns = 0
    func connect() async throws { }
    func request(_ command: String, params: [String: JSONValue], session: String?,
                 timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan":
            return event("result", session: nil, payload: ["devices": .array([
                .object(["name": .string("Receiver"), "address": .string("receiver"),
                         "model": .string("HomePod")])])])
        case "start":
            startParameters = params
            return event("result", session: session, payload: [
                "state": .string("stopped"), "cleanup_complete": .bool(true),
                "report": .object(["cleanup_complete": .bool(true),
                                   "input_closed": .bool(true), "hub_stopped": .bool(true)])])
        default:
            throw WorkerFailure.remote("Unexpected latency store command")
        }
    }
    func disconnect() async throws { shutdowns += 1 }
    func abortProtocol(_ message: String) { onFailure?(message) }
    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let values: [String: JSONValue] = ["v": .integer(1), "id": .string("latency-check"),
            "event": .string(kind), "session": session.map(JSONValue.string) ?? .null,
            "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(values))
    }
}
