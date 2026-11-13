import Foundation

@main struct SystemVirtualInputChecks {
    @MainActor static func main() async throws {
        // Old/new runtime JSON is still decoded correctly by the shared struct.
        let old = Data(#"{"python":"/python","project":"/project","library":"/core","capture_host":"/legacy"}"#.utf8)
        let decodedOld = try JSONDecoder().decode(SystemAudioRuntime.self, from: old)
        precondition(decodedOld.virtual_capture_host == nil)
        precondition(decodedOld.worker_executable == nil)
        let new = Data(#"{"python":"/python","project":"/project","library":"/core","capture_host":"/legacy","virtual_capture_host":"/virtual"}"#.utf8)
        let decodedNew = try JSONDecoder().decode(SystemAudioRuntime.self, from: new)
        precondition(decodedNew.virtual_capture_host == "/virtual")
        let bundled = Data(#"{"python":"/worker","project":"/project","library":"/core","capture_host":"/legacy","worker_executable":"/worker"}"#.utf8)
        let decodedBundled = try JSONDecoder().decode(SystemAudioRuntime.self, from: bundled)
        precondition(decodedBundled.worker_executable == "/worker")

        // Cross-component contract: capability gate, capture-host selection, v1 unchanged request.
        for (configured, supported) in [(false, false), (true, false), (true, true)] {
            let service = VirtualInputService(configured: configured, supported: supported)
            let store = SystemAudioStore(serviceFactory: { service }, observesEnvironment: false)
            await store.connectLocalWorker(); await store.scanDevices()
            store.selectedDeviceIDs = ["receiver"]
            await store.start(mode: .synchronized, volume: 15)
            if configured && !supported {
                precondition(service.startParameters == nil && !store.desiredEnabled)
                precondition(!store.cleanupRequiresAttention)
            } else {
                let params = service.startParameters!
                precondition(params["capture_host"]?.string == (configured ? "/virtual" : "/legacy"))
                let routes = params["routes"]!.array!
                precondition(routes.allSatisfy { $0.object?["role"] == nil })
                if configured {
                    precondition(params["input"]?.object?["backend"]?.string == "virtual_device_v2")
                    precondition(params["input"]?.object?["device_uid"]?.string == "com.homepodflow.virtual-audio.surround71.v1")
                    precondition(params["input"]?.object?["layout"]?.string == "7_1")
                } else { precondition(params["input"] == nil) }
                precondition(!store.cleanupRequiresAttention)
            }
            await store.prepareForTermination()
            precondition(service.shutdowns == 1)
        }

        // actual_mode state payload drives truthful, non-implementation status wording.
        try await assertStreamingStatus(actualMode: "stereo_downmix", configured: true, mode: .cinema) { text in
            precondition(text.contains("下混"))
            precondition(!text.contains("5.1") && !text.contains("7.1"))
            precondition(!text.contains("声道分配") && !text.contains("离散") && !text.contains("原生"))
        }
        try await assertStreamingStatus(actualMode: "channel_distribution", configured: true, mode: .synchronized) { text in
            precondition(text.contains("声道"))
            precondition(!text.contains("5.1") && !text.contains("7.1") && !text.contains("原生"))
        }
        try await assertStreamingStatus(actualMode: "same_stereo", configured: false, mode: .synchronized) { text in
            precondition(text.contains("立体声"))
            precondition(!text.contains("8 声道") && !text.contains("下混"))
        }
        print("SystemVirtualInputChecks: runtime decode, v2 request/capability gate, role-free downmix and truthful status wording passed")
    }

    @MainActor private static func assertStreamingStatus(actualMode: String, configured: Bool, mode: PlaybackMode,
                                                        verify: (String) -> Void) async throws {
        let service = StreamingVirtualInputService(actualMode: actualMode, configured: configured)
        let store = SystemAudioStore(serviceFactory: { service }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: mode, volume: 18) }
        await until { store.isRunning }
        verify(store.statusText)
        await store.stop(); await run.value
        precondition(!store.cleanupRequiresAttention && !store.hasActiveSession && !store.isRunning)
        await store.prepareForTermination()
        precondition(service.shutdowns == 1)
    }

    @MainActor private static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Timed out waiting for virtual-input streaming state")
    }
}

@MainActor private final class VirtualInputService: SystemAudioRouting {
    let runtime: SystemAudioRuntime
    let supportsVirtualInput: Bool
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var startParameters: [String: JSONValue]?
    var shutdowns = 0
    init(configured: Bool, supported: Bool) {
        runtime = .init(python: "/python", project: "/project", library: "/core", capture_host: "/legacy",
                        virtual_capture_host: configured ? "/virtual" : nil)
        supportsVirtualInput = supported
    }
    func connect() async throws { }
    func request(_ command: String, params: [String: JSONValue], session: String?, timeout: Double?) async throws -> WorkerEvent {
        let payload: [String: Any]
        if command == "scan" {
            payload = ["devices": [["name": "Test", "address": "receiver", "model": "AudioAccessory5,1"]]]
        } else {
            if command == "start" { startParameters = params }
            payload = ["state": "stopped", "cleanup_complete": true,
                       "report": ["cleanup_complete": true, "input_closed": true, "hub_stopped": true]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "id": NSNull(), "event": "result",
            "session": session.map { $0 as Any } ?? NSNull(), "payload": payload])
        return try JSONDecoder().decode(WorkerEvent.self, from: data)
    }
    func disconnect() async throws { shutdowns += 1 }
    func abortProtocol(_ message: String) { preconditionFailure(message) }
}

@MainActor private final class StreamingVirtualInputService: SystemAudioRouting {
    let runtime: SystemAudioRuntime
    let supportsVirtualInput: Bool
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var startParameters: [String: JSONValue]?
    var shutdowns = 0
    private let actualMode: String
    private var startSession: String?
    private var startContinuation: CheckedContinuation<WorkerEvent, any Error>?
    init(actualMode: String, configured: Bool) {
        self.actualMode = actualMode
        supportsVirtualInput = configured
        runtime = .init(python: "/python", project: "/project", library: "/core", capture_host: "/legacy",
                        virtual_capture_host: configured ? "/virtual" : nil)
    }
    func connect() async throws { }
    func request(_ command: String, params: [String: JSONValue], session: String?, timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan":
            return event("result", session: nil, payload: ["devices": .array([.object([
                "name": .string("Test receiver"), "address": .string("receiver"), "model": .string("HomePod")])])])
        case "start":
            startParameters = params; startSession = session
            onEvent?(event("state", session: session, payload: ["state": .string("streaming"), "actual_mode": .string(actualMode)]))
            return try await withCheckedThrowingContinuation { startContinuation = $0 }
        case "stop":
            finishStart()
            return event("result", session: session, payload: ["state": .string("stopped"), "cleanup_complete": .bool(true)])
        default:
            throw WorkerFailure.remote("Unexpected virtual-input command")
        }
    }
    func disconnect() async throws { shutdowns += 1; finishStart() }
    func abortProtocol(_ message: String) { onFailure?(message) }
    private func finishStart() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: event("result", session: startSession, payload: [
            "state": .string("stopped"), "cleanup_complete": .bool(true),
            "report": .object(["cleanup_complete": .bool(true), "input_closed": .bool(true), "hub_stopped": .bool(true)])]))
    }
    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let values: [String: JSONValue] = ["v": .integer(1), "id": .string("virtual-input-check"), "event": .string(kind),
            "session": session.map(JSONValue.string) ?? .null, "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(values))
    }
}
