import Foundation

/// No subprocess, microphone, tap, receiver or network operation is used by this executable.
@main struct SystemSessionChecks {
    @MainActor static func main() async throws {
        var policy = SystemSessionRecovery()
        precondition(!policy.desiredEnabled)
        policy.enable()
        for expected in [1.0, 2, 4, 8, 16] {
            precondition(policy.nextDelay(cleanupConfirmed: true, retryable: true, hasStableTargets: true) == expected)
        }
        precondition(policy.nextDelay(cleanupConfirmed: true, retryable: true, hasStableTargets: true) == nil)
        policy.markStable()
        precondition(policy.nextDelay(cleanupConfirmed: true, retryable: true, hasStableTargets: true) == 1)
        let oldIntent = policy.intent; policy.cancel()
        precondition(!policy.desiredEnabled && policy.intent != oldIntent)
        precondition(policy.nextDelay(cleanupConfirmed: true, retryable: true, hasStableTargets: true) == nil)
        policy.enable()
        precondition(policy.nextDelay(cleanupConfirmed: false, retryable: true, hasStableTargets: true) == nil)
        precondition(policy.blocked)
        precondition(policy.nextDelay(cleanupConfirmed: true, retryable: true, hasStableTargets: true) == nil)
        let denied = SystemSessionFailure(payload: ["failure_kind": .string("permission_denied"), "retryable": .bool(true), "cleanup_complete": .bool(true)])
        precondition(!denied.retryable && denied.cleanupConfirmed)
        precondition(!SystemSessionFailure(payload: [:]).retryable)
        precondition(StableReceiverResolution.addresses(for: ["receiver-a"], discovery: ["new-address": "receiver-a"]) == ["new-address"])
        precondition(StableReceiverResolution.addresses(for: ["receiver-a", "receiver-b"], discovery: ["a": "receiver-a"]) == nil)
        precondition(StableReceiverResolution.addresses(for: ["receiver-a"], discovery: ["a": "receiver-a", "b": "receiver-a"]) == nil)

        // A clean transient failure must rediscover and resolve the same identity at its new IP.
        let worker = SilentSystemService()
        let store = SystemAudioStore(serviceFactory: { worker }, retrySleep: { _ in await Task.yield() }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["old-address"]
        let first = Task { await store.start(mode: .synchronized, volume: 25) }
        await until { worker.starts.count == 1 && store.isRunning }
        let firstSession = worker.starts[0].session!
        worker.address = "new-address"
        worker.failCurrent(kind: "network_transient", clean: true)
        await first.value
        await until { worker.starts.count == 2 && store.isRunning }
        precondition(worker.scanCount == 2 && store.desiredEnabled)
        precondition(worker.starts[1].session != firstSession)
        let routes = worker.starts[1].params["routes"]!.array!
        precondition(routes[0].object!["host"]?.string == "new-address")
        // Stop revokes intent before awaiting cleanup. Wake/network events cannot resurrect it.
        await store.stop()
        await until { !store.hasActiveSession }
        store.handleEnvironment(.didWake); store.handleEnvironment(.networkAvailable(true))
        for _ in 0..<20 { await Task.yield() }
        precondition(!store.desiredEnabled && worker.starts.count == 2 && !store.isRunning)
        await store.prepareForTermination()
        precondition(worker.shutdowns == 1 && !store.serviceReady)

        // Permission failures stay stopped despite a worker incorrectly suggesting retryability.
        let permissionWorker = SilentSystemService()
        let permissionStore = SystemAudioStore(serviceFactory: { permissionWorker }, retrySleep: { _ in await Task.yield() }, observesEnvironment: false)
        await permissionStore.connectLocalWorker(); await permissionStore.scanDevices()
        permissionStore.selectedDeviceIDs = ["old-address"]
        let permissionRun = Task { await permissionStore.start(mode: .synchronized, volume: 15) }
        await until { permissionWorker.starts.count == 1 }
        permissionWorker.failCurrent(kind: "permission_denied", clean: true)
        await permissionRun.value
        permissionStore.handleEnvironment(.didWake)
        for _ in 0..<20 { await Task.yield() }
        precondition(permissionWorker.starts.count == 1 && !permissionStore.recoveryPending)
        await permissionStore.prepareForTermination()

        // Unconfirmed cleanup forbids a new start, even with a stable identity and retryable flag.
        let uncertain = SilentSystemService()
        let unsafe = SystemAudioStore(serviceFactory: { uncertain }, retrySleep: { _ in await Task.yield() }, observesEnvironment: false)
        await unsafe.connectLocalWorker(); await unsafe.scanDevices(); unsafe.selectedDeviceIDs = ["old-address"]
        let unsafeRun = Task { await unsafe.start(mode: .synchronized, volume: 15) }
        await until { uncertain.starts.count == 1 }
        uncertain.failCurrent(kind: "network_transient", clean: false)
        await unsafeRun.value
        precondition(unsafe.cleanupRequiresAttention && !unsafe.isRunning)
        await unsafe.start(mode: .synchronized, volume: 15)
        precondition(uncertain.starts.count == 1)
        await unsafe.prepareForTermination()
        print("System session checks passed: bounded policy, identity/address change, clean recovery, explicit stop/quit, permission and uncertain cleanup")
    }

    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Timed out waiting for silent state transition")
    }
}

@MainActor private final class SilentSystemService: SystemAudioRouting {
    let runtime = SystemAudioRuntime(python: "/not-executed", project: "/not-executed", library: "/not-loaded", capture_host: "/not-executed")
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var address = "old-address"
    var starts: [(params: [String: JSONValue], session: String?)] = []
    var scanCount = 0
    var shutdowns = 0
    private var pending: CheckedContinuation<WorkerEvent, any Error>?
    private var sid: String?
    func connect() async throws {}
    func request(_ command: String, params: [String: JSONValue], session: String?, timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan":
            scanCount += 1
            return event("result", session: nil, payload: ["devices": .array([.object([
                "name": .string("Arbitrary name"), "address": .string(address),
                "model": .string("HomePodMini"), "identifier": .string("receiver-a")])])])
        case "start":
            starts.append((params, session)); sid = session
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                onEvent?(event("state", session: session, payload: ["state": .string("streaming")]))
            }
        case "stop":
            finishCurrent()
            return event("result", session: session, payload: ["state": .string("stopped"), "cleanup_complete": .bool(true)])
        default: throw WorkerFailure.remote("Unexpected fake command")
        }
    }
    func failCurrent(kind: String, clean: Bool) {
        let error = event("error", session: sid, payload: ["code": .string("operation_failed"), "message": .string(kind),
            "failure_kind": .string(kind), "retryable": .bool(true), "cleanup_complete": .bool(clean)])
        onEvent?(error)
        let old = pending; pending = nil
        old?.resume(throwing: WorkerFailure.remote(kind))
    }
    private func finishCurrent() {
        guard let pending else { return }; self.pending = nil
        pending.resume(returning: event("result", session: sid, payload: ["state": .string("stopped"), "cleanup_complete": .bool(true),
            "report": .object(["cleanup_complete": .bool(true), "input_closed": .bool(true), "hub_stopped": .bool(true)])]))
    }
    func disconnect() async throws { shutdowns += 1; finishCurrent() }
    func abortProtocol(_ message: String) { onFailure?(message) }
    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let values: [String: JSONValue] = ["v": .integer(1), "id": .string("silent-check"), "event": .string(kind),
            "session": session.map(JSONValue.string) ?? .null, "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(values))
    }
}
