import Foundation

/// The App no longer preflights or writes the Core Audio latency. It forwards
/// the configured helper path once and renders the worker-published outcome.
@main struct LatencyControlChecks {
    @MainActor static func main() async {
        verify(fromWorker: [
            "status": .string("applied"), "target_ms": .integer(2000),
            "reported_ms": .number(2000), "revision": .integer(8),
            "old_ms": .number(0), "revision_before": .integer(7),
            "expected_revision": .integer(8), "write_attempted": .bool(true),
            "device_is_running": .bool(false),
        ], kind: .applied, applied: true, textContains: "已应用 2000 ms")

        verify(fromWorker: [
            "status": .string("unchanged"), "target_ms": .integer(2000),
            "reported_ms": .number(2000), "revision": .integer(7),
            "write_attempted": .bool(false), "device_is_running": .bool(false),
        ], kind: .reported, applied: false, textContains: "未写入")

        verify(fromWorker: [
            "status": .string("pending"), "target_ms": .integer(2000),
            "reported_ms": .number(0), "revision": .integer(7),
            "write_attempted": .bool(false), "device_is_running": .bool(true),
            "pending_reason": .string("device is running for another client"),
        ], kind: .deferredPending, applied: false, textContains: "延后")

        await assertStoreSendsHelperPathWithoutLocalPreflight()
        await assertStoreRendersWorkerLatencyState()
        print("LatencyControlChecks: worker latency-state mapping and store forwarding passed")
    }

    @MainActor private static func verify(fromWorker payload: [String: JSONValue],
                                          kind: LatencyControlOutcomeKind,
                                          applied: Bool, textContains: String) {
        guard let state = LatencyControlState.fromWorker(payload) else {
            preconditionFailure("worker latency state did not parse")
        }
        precondition(state.kind == kind)
        precondition(state.applied == applied)
        precondition(state.estimatedMS == 2000)
        precondition(state.statusText.contains(textContains))
    }

    @MainActor private static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Timed out waiting for latency state")
    }

    @MainActor private static func assertStoreSendsHelperPathWithoutLocalPreflight() async {
        let service = LatencyPathStoreService()
        let store = SystemAudioStore(serviceFactory: { service }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        await store.start(mode: .synchronized, volume: 15)
        let input = service.startParameters?["input"]?.object
        precondition(input?["backend"]?.string == "virtual_device_v2")
        precondition(input?["latency_control"]?.string == "/hflctl")
        precondition(input?["latency_report"] == nil)
        precondition(!store.cleanupRequiresAttention)
        await store.prepareForTermination()
        precondition(service.shutdowns == 1)
        precondition(service.commands == ["scan", "start"])
    }

    @MainActor private static func assertStoreRendersWorkerLatencyState() async {
        let latency: [String: JSONValue] = [
            "state": .string("streaming"), "actual_mode": .string("same_stereo"),
            "latency_state": .object([
                "status": .string("applied"), "target_ms": .integer(2000),
                "reported_ms": .number(2000), "old_ms": .number(0),
                "revision_before": .integer(7), "revision": .integer(8),
                "expected_revision": .integer(8), "write_attempted": .bool(true),
                "device_is_running": .bool(false),
            ]),
        ]
        let service = LatencyStateStoreService(latency: latency)
        let store = SystemAudioStore(serviceFactory: { service }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { store.latencyState?.kind == .applied }
        precondition(store.latencyState?.kind == .applied)
        precondition(store.latencyStatusText.contains("已应用 2000 ms"))
        await store.stop(); await run.value
        precondition(service.shutdowns == 0)
        await store.prepareForTermination()
        precondition(service.shutdowns == 1)
    }
}

@MainActor private final class LatencyPathStoreService: SystemAudioRouting {
    let runtime = SystemAudioRuntime(python: "/python", project: "/project", library: "/core",
                                     capture_host: "/legacy", virtual_capture_host: "/virtual",
                                     latency_control: "/hflctl")
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    let supportsRealtimeVolume = false
    let supportsVirtualInput = true
    var startParameters: [String: JSONValue]?
    var shutdowns = 0
    var commands: [String] = []
    func connect() async throws { }
    func request(_ command: String, params: [String: JSONValue], session: String?,
                 timeout: Double?) async throws -> WorkerEvent {
        commands.append(command)
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
            throw WorkerFailure.remote("Unexpected latency path command")
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

@MainActor private final class LatencyStateStoreService: SystemAudioRouting {
    let runtime = SystemAudioRuntime(python: "/python", project: "/project", library: "/core",
                                     capture_host: "/legacy", virtual_capture_host: "/virtual",
                                     latency_control: "/hflctl")
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    let supportsRealtimeVolume = false
    let supportsVirtualInput = true
    var shutdowns = 0
    private let latency: [String: JSONValue]
    private var startSession: String?
    private var continuation: CheckedContinuation<WorkerEvent, any Error>?
    init(latency: [String: JSONValue]) { self.latency = latency }
    func connect() async throws { }
    func request(_ command: String, params: [String: JSONValue], session: String?,
                 timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan":
            return event("result", session: nil, payload: ["devices": .array([
                .object(["name": .string("Receiver"), "address": .string("receiver"),
                         "model": .string("HomePod")])])])
        case "start":
            startSession = session
            onEvent?(event("state", session: session, payload: latency))
            return try await withCheckedThrowingContinuation { continuation = $0 }
        case "stop":
            finish()
            return event("result", session: session, payload: ["cleanup_complete": .bool(true)])
        default:
            throw WorkerFailure.remote("Unexpected latency state command")
        }
    }
    func disconnect() async throws { shutdowns += 1; finish() }
    func abortProtocol(_ message: String) { onFailure?(message) }
    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: event("result", session: startSession, payload: [
            "state": .string("stopped"), "cleanup_complete": .bool(true),
            "report": .object(["cleanup_complete": .bool(true), "input_closed": .bool(true),
                               "hub_stopped": .bool(true)])]))
    }
    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let values: [String: JSONValue] = ["v": .integer(1), "id": .string("latency-state-check"),
            "event": .string(kind), "session": session.map(JSONValue.string) ?? .null,
            "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(values))
    }
}
