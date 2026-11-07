import Foundation
import CoreAudio

/// No CoreAudio device, worker subprocess, receiver, tap or network operation
/// is touched by this executable: the store is driven by fakes backed by an
/// in-memory hardware table.
@main struct DefaultOutputRouteChecks {
    @MainActor static func main() async throws {
        try assertServiceUIDLookupReadbackAndRestore()
        await assertSwitchOnceOnCapturingThenRestoreOnStop()
        await assertStreamingFallbackWhenCapturingNeverArrives()
        await assertLegacyCaptureNeverSwitches()
        await assertManualUserSelectionIsPreserved()
        await assertPreviousAlreadyFlowIsNotDisturbed()
        await assertSwitchFailureStopsOwnedSession()
        await assertStartupErrorRestoresBeforeRecoveryDecision()
        print("DefaultOutputRouteChecks: UID lookup/set/read-back/restore, single live switch, legacy exclusion, manual selection preservation and fail-safe stop passed")
    }

    // MARK: Service (fake CoreAudio hardware)

    @MainActor private static func assertServiceUIDLookupReadbackAndRestore() throws {
        let hardware = FakeHardware(defaultID: 1, uids: [1: "built-in", 2: FlowVirtualDevice.uid, 3: "hdmi"])
        let service = DefaultOutputRouteService(hardware: hardware)
        precondition(service.currentDefaultOutputUID() == "built-in")
        let didSetFlow = try service.setDefaultOutput(uid: FlowVirtualDevice.uid)
        precondition(didSetFlow)
        precondition(hardware.defaultID == 2)
        precondition(service.currentDefaultOutputUID() == FlowVirtualDevice.uid)

        // Restore resolves by UID, so a re-enumerated device ID still works.
        hardware.uids = [10: "built-in", 2: FlowVirtualDevice.uid]
        precondition(service.restoreDefaultOutput(uid: "built-in"))
        precondition(hardware.defaultID == 10)
        precondition(!service.restoreDefaultOutput(uid: "gone-after-hotplug"))

        do {
            _ = try service.setDefaultOutput(uid: "missing")
            preconditionFailure("missing UID must be rejected")
        } catch {
            precondition(error.localizedDescription.contains("不存在"))
        }

        let noOutput = FakeHardware(defaultID: 1, uids: [1: "built-in", 2: FlowVirtualDevice.uid],
                                    streamCounts: [2: 0])
        let noOutputService = DefaultOutputRouteService(hardware: noOutput)
        do {
            _ = try noOutputService.setDefaultOutput(uid: FlowVirtualDevice.uid)
            preconditionFailure("zero-output device must be rejected")
        } catch {
            precondition(error.localizedDescription.contains("无输出能力"))
        }

        let failing = FakeHardware(defaultID: 1, uids: [1: "built-in", 2: FlowVirtualDevice.uid])
        failing.setShouldFail = true
        let failingService = DefaultOutputRouteService(hardware: failing)
        do {
            _ = try failingService.setDefaultOutput(uid: FlowVirtualDevice.uid)
            preconditionFailure("hardware write failure must surface")
        } catch {
            precondition(error.localizedDescription.contains("写入默认输出失败"))
        }
    }

    // MARK: Store lifecycle (fake controller + fake worker)

    @MainActor private static func assertSwitchOnceOnCapturingThenRestoreOnStop() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        let sid = worker.startSession!

        worker.emit("preparing", session: sid)
        precondition(ctl.setCalls.isEmpty)
        worker.emit("capturing", session: sid)
        precondition(ctl.setCalls == [FlowVirtualDevice.uid] && ctl.current == FlowVirtualDevice.uid)
        worker.emit("capturing", session: sid)
        worker.emit("streaming", session: sid)
        precondition(ctl.setCalls.count == 1, "repeated live states must not re-route")
        precondition(store.isRunning)

        await store.stop(); await run.value
        precondition(ctl.restoreCalls == ["built-in"] && ctl.current == "built-in")
        precondition(!store.hasActiveSession && !store.isRunning)
        await store.prepareForTermination()
        precondition(worker.shutdowns == 1)
    }

    @MainActor private static func assertStreamingFallbackWhenCapturingNeverArrives() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("streaming", session: worker.startSession!)
        await until { ctl.setCalls == [FlowVirtualDevice.uid] }
        precondition(store.isRunning)
        await store.stop(); await run.value
        precondition(ctl.restoreCalls == ["built-in"])
        await store.prepareForTermination()
    }

    @MainActor private static func assertLegacyCaptureNeverSwitches() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: false)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        worker.emit("streaming", session: worker.startSession!)
        precondition(ctl.setCalls.isEmpty && ctl.restoreCalls.isEmpty)
        precondition(store.isRunning)
        await store.stop(); await run.value
        await store.prepareForTermination()
    }

    @MainActor private static func assertManualUserSelectionIsPreserved() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        precondition(ctl.current == FlowVirtualDevice.uid)
        ctl.current = "hdmi" // Manual user switch away from Flow mid-session.
        await store.stop(); await run.value
        precondition(ctl.restoreCalls.isEmpty && ctl.current == "hdmi")
        await store.prepareForTermination()
    }

    @MainActor private static func assertPreviousAlreadyFlowIsNotDisturbed() async {
        let ctl = FakeDefaultOutputController(current: FlowVirtualDevice.uid)
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        precondition(ctl.setCalls.isEmpty && ctl.current == FlowVirtualDevice.uid)
        await store.stop(); await run.value
        precondition(ctl.restoreCalls.isEmpty && ctl.current == FlowVirtualDevice.uid)
        await store.prepareForTermination()
    }

    @MainActor private static func assertSwitchFailureStopsOwnedSession() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        ctl.failOnSet = DefaultOutputRouteError.readbackUnverified
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        await until { worker.stops == 1 && !store.hasActiveSession && !store.desiredEnabled }
        await run.value
        precondition(store.statusText.contains("默认输出切换"))
        precondition(!store.cleanupRequiresAttention, "a clean owned-session stop must not look like an uncertain cleanup")
        await store.prepareForTermination()
    }

    @MainActor private static func assertStartupErrorRestoresBeforeRecoveryDecision() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, retrySleep: { _ in await Task.yield() },
                                     observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        precondition(ctl.current == FlowVirtualDevice.uid)
        worker.fail(kind: "permission_denied", clean: true)
        await run.value
        precondition(ctl.restoreCalls == ["built-in"] && ctl.current == "built-in")
        precondition(!store.hasActiveSession)
        await store.prepareForTermination()
    }

    @MainActor private static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Timed out waiting for default-output state transition")
    }
}

@MainActor private final class FakeDefaultOutputController: DefaultOutputControlling {
    var current: String?
    var setCalls: [String] = []
    var restoreCalls: [String] = []
    var failOnSet: Error?
    private let known: Set<String> = ["built-in", FlowVirtualDevice.uid, "hdmi"]

    init(current: String?) { self.current = current }

    func currentDefaultOutputUID() -> String? { current }

    func setDefaultOutput(uid: String) throws -> Bool {
        setCalls.append(uid)
        if let failOnSet { throw failOnSet }
        guard known.contains(uid) else { return false }
        current = uid
        return true
    }

    func restoreDefaultOutput(uid: String) -> Bool {
        restoreCalls.append(uid)
        guard known.contains(uid) else { return false }
        current = uid
        return true
    }
}

@MainActor private final class FakeHardware: AudioHardwareAccessing {
    var defaultID: AudioObjectID
    var uids: [AudioObjectID: String]
    var streamCounts: [AudioObjectID: Int?]
    var setShouldFail = false

    init(defaultID: AudioObjectID, uids: [AudioObjectID: String],
         streamCounts: [AudioObjectID: Int?] = [:]) {
        self.defaultID = defaultID
        self.uids = uids
        self.streamCounts = streamCounts
    }

    var defaultOutputDevice: AudioObjectID? {
        guard uids[defaultID] != nil else { return nil }
        return defaultID
    }

    func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        if setShouldFail { throw DefaultOutputRouteError.setFailed(-536870174) }
        defaultID = device
    }

    func deviceUIDMap() -> [AudioObjectID: String] { uids }

    func outputStreamCount(_ device: AudioObjectID) -> Int? {
        streamCounts[device] ?? 2
    }
}

@MainActor private final class RoutingWorker: SystemAudioRouting {
    let runtime: SystemAudioRuntime
    let supportsVirtualInput = true
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts = 0
    var stops = 0
    var shutdowns = 0
    var startSession: String?
    private var startContinuation: CheckedContinuation<WorkerEvent, any Error>?

    init(virtual: Bool) {
        runtime = .init(python: "/python", project: "/project", library: "/core",
                        capture_host: "/legacy", virtual_capture_host: virtual ? "/virtual" : nil)
    }

    func connect() async throws {}

    func request(_ command: String, params: [String: JSONValue], session: String?,
                 timeout: Double?) async throws -> WorkerEvent {
        switch command {
        case "scan":
            return event("result", session: nil, payload: ["devices": .array([
                .object(["name": .string("Receiver"), "address": .string("receiver"),
                         "model": .string("HomePod")])])])
        case "start":
            starts += 1; startSession = session
            return try await withCheckedThrowingContinuation { startContinuation = $0 }
        case "stop":
            stops += 1; finishStart()
            return event("result", session: session, payload: ["state": .string("stopped"),
                "cleanup_complete": .bool(true)])
        default:
            throw WorkerFailure.remote("Unexpected default-output routing command")
        }
    }

    func emit(_ phase: String, session: String?) {
        onEvent?(event("state", session: session, payload: [
            "state": .string(phase), "actual_mode": .string("same_stereo")]))
    }

    func fail(kind: String, clean: Bool) {
        onEvent?(event("error", session: startSession, payload: [
            "code": .string("operation_failed"), "message": .string(kind),
            "failure_kind": .string(kind), "retryable": .bool(true),
            "cleanup_complete": .bool(clean)]))
        let old = startContinuation; startContinuation = nil
        old?.resume(throwing: WorkerFailure.remote(kind))
    }

    func disconnect() async throws { shutdowns += 1; finishStart() }
    func abortProtocol(_ message: String) { onFailure?(message) }

    private func finishStart() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: event("result", session: startSession, payload: [
            "state": .string("stopped"), "cleanup_complete": .bool(true),
            "report": .object(["cleanup_complete": .bool(true),
                               "input_closed": .bool(true), "hub_stopped": .bool(true)])]))
    }

    private func event(_ kind: String, session: String?, payload: [String: JSONValue]) -> WorkerEvent {
        let values: [String: JSONValue] = ["v": .integer(1), "id": .string("default-output-check"),
            "event": .string(kind), "session": session.map(JSONValue.string) ?? .null,
            "payload": .object(payload)]
        return try! JSONDecoder().decode(WorkerEvent.self, from: JSONEncoder().encode(values))
    }
}
