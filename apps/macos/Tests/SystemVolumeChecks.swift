import Foundation

@main struct SystemVolumeChecks {
    @MainActor static func main() async throws {
        let backend = VolumeCheckService()
        let store = SystemAudioStore(serviceFactory: { backend }, observesEnvironment: false)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let first = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { backend.startCount == 1 }
        store.setVolume(20); store.setVolume(30)
        for _ in 0..<20 { await Task.yield() }
        precondition(backend.volumes.isEmpty && store.volumeUpdating)
        backend.streaming()
        await until { backend.volumes.count == 1 }
        precondition(backend.volumes[0].value == 30)
        store.setVolume(40); store.setVolume(50); store.setVolume(60)
        precondition(backend.volumes.count == 1)
        backend.acknowledge()
        await until { backend.volumes.count == 2 }
        precondition(backend.volumes[1].value == 60 && backend.maximumInFlight == 1)
        backend.acknowledge()
        await until { !store.volumeUpdating }
        precondition(store.appliedVolumePercent == 60 && store.volumeStatus.isEmpty)

        store.setVolume(70)
        await until { backend.volumes.count == 3 }
        store.setVolume(80) // A pending value must not survive Stop.
        let oldSession = backend.volumes[2].session
        await store.stop(); await first.value
        precondition(!store.desiredEnabled && store.appliedVolumePercent == nil)
        let second = Task { await store.start(mode: .synchronized, volume: 25) }
        await until { backend.startCount == 2 }
        backend.streaming(); store.setVolume(90)
        for _ in 0..<20 { await Task.yield() }
        precondition(backend.volumes.count == 3) // Old actual request still owns the only slot.
        backend.acknowledge() // Old ACK cannot confirm 70 for the new session.
        await until { backend.volumes.count == 4 }
        precondition(backend.volumes[3].session != oldSession && backend.volumes[3].value == 90)
        precondition(store.appliedVolumePercent == nil && store.volumeUpdating)
        backend.acknowledge()
        await until { !store.volumeUpdating }
        precondition(store.appliedVolumePercent == 90 && backend.maximumInFlight == 1)
        store.setVolume(95)
        await until { backend.volumes.count == 5 }
        backend.rejectVolume()
        await until { !store.volumeUpdating }
        precondition(store.volumeStatus.contains("失败") && store.appliedVolumePercent == 90)
        await store.stop(); await second.value; await store.prepareForTermination()
        print("PASS: preparing latest volume, one in-flight/one latest pending, Stop cancellation, old ACK/new session isolation, failure preserves last confirmed volume")
    }
    @MainActor private static func until(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        preconditionFailure("Silent volume transition timed out")
    }
}

@MainActor private final class VolumeCheckService: SystemAudioRouting {
    let runtime = SystemAudioRuntime(python: "/unused", project: "/unused", library: "/unused", capture_host: "/unused")
    let supportsRealtimeVolume = true
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var startCount = 0
    var volumes: [(session: String, value: Double)] = []
    var maximumInFlight = 0
    private var inFlight = 0
    private var sid: String?
    private var start: CheckedContinuation<WorkerEvent, any Error>?
    private var volume: CheckedContinuation<WorkerEvent, any Error>?
    func connect() async throws {}
    func request(_ command: String, params: [String: JSONValue], session: String?, timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan": return event("result", session: nil, payload: ["devices": .array([.object([
            "name": .string("Receiver"), "address": .string("receiver"), "model": .string("HomePod"), "identifier": .string("stable-receiver")])])])
        case "start":
            startCount += 1; sid = session
            return try await withCheckedThrowingContinuation { start = $0 }
        case "set_volume":
            precondition(volume == nil && timeout == 20)
            volumes.append((session!, params["volume"]!.number!)); inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            return try await withCheckedThrowingContinuation { volume = $0 }
        case "stop":
            finishStart()
            return event("result", session: session, payload: ["state": .string("stopped"), "cleanup_complete": .bool(true)])
        default: throw WorkerFailure.remote("Unexpected silent command")
        }
    }
    func streaming() { onEvent?(event("state", session: sid, payload: ["state": .string("streaming")])) }
    func acknowledge() {
        let pending = volume!; volume = nil; inFlight -= 1
        let sent = volumes.last!
        pending.resume(returning: event("result", session: sent.session, payload: ["state": .string("volume_applied"),
            "volume_percent": .number(sent.value), "applied_outputs": .integer(1)]))
    }
    func rejectVolume() {
        let pending = volume!; volume = nil; inFlight -= 1
        pending.resume(throwing: WorkerFailure.remote("receiver rejected volume"))
    }
    private func finishStart() {
        guard let start else { return }; self.start = nil
        start.resume(returning: event("result", session: sid, payload: ["state": .string("stopped"), "cleanup_complete": .bool(true),
            "report": .object(["cleanup_complete": .bool(true), "input_closed": .bool(true), "hub_stopped": .bool(true)])]))
    }
    func disconnect() async throws { finishStart() }
    func abortProtocol(_ message: String) { onFailure?(message) }
    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let value: [String: JSONValue] = ["v": .integer(1), "id": .string("silent-volume"), "event": .string(kind),
            "session": session.map(JSONValue.string) ?? .null, "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(value))
    }
}
