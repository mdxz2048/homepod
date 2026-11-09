import Foundation
import CoreAudio

/// No CoreAudio device, worker subprocess, receiver, tap or network operation
/// is touched by this executable: the store is driven by fakes backed by an
/// in-memory hardware table.
@main struct DefaultOutputRouteChecks {
    @MainActor static func main() async throws {
        try assertServiceUIDLookupReadbackAndRestore()
        await assertSwitchBeforeStartAndRestoreBeforeStop()
        await assertStopDuringPreStartRoutingRestoresOutput()
        await assertStartRequiresPublishedSwitch()
        await assertStopWaitsForPublishedRestore()
        await assertLegacyCaptureNeverSwitches()
        await assertManualUserSelectionIsPreserved()
        await assertPreviousAlreadyFlowIsNotDisturbed()
        await assertSwitchFailureStopsOwnedSession()
        await assertStartupErrorRestoresBeforeRecoveryDecision()
        print("DefaultOutputRouteChecks: UID lookup/set/read-back/restore, route-before-start, restore-before-stop, legacy exclusion, manual selection preservation and fail-safe stop passed")
    }

    // MARK: Service (fake CoreAudio hardware)

    @MainActor private static func assertServiceUIDLookupReadbackAndRestore() throws {
        let hardware = FakeHardware(defaultID: 1, uids: [1: "built-in", 2: FlowVirtualDevice.uid, 3: "hdmi"])
        let service = DefaultOutputRouteService(hardware: hardware)
        precondition(service.currentDefaultOutputUID() == "built-in")
        hardware.runningIDs = [1]
        precondition(service.isDeviceRunning(uid: "built-in") == true)
        precondition(service.isDeviceRunning(uid: FlowVirtualDevice.uid) == false)
        let didSetFlow = try service.setDefaultOutput(uid: FlowVirtualDevice.uid)
        precondition(didSetFlow)
        precondition(hardware.defaultID == 2)
        precondition(service.currentDefaultOutputUID() == FlowVirtualDevice.uid)
        precondition(service.isDeviceRunning(uid: "missing") == nil)

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

    @MainActor private static func assertSwitchBeforeStartAndRestoreBeforeStop() async {
        let log = OrderLog()
        let ctl = FakeDefaultOutputController(current: "built-in", log: log)
        ctl.running = ["built-in"]
        let worker = RoutingWorker(virtual: true, log: log)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false, defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { log.values.contains("start") }
        precondition(worker.starts == 1)
        precondition(log.values == ["set:\(FlowVirtualDevice.uid)", "start"])
        let sid = worker.startSession!

        worker.emit("preparing", session: sid)
        worker.emit("capturing", session: sid)
        precondition(ctl.setCalls == [FlowVirtualDevice.uid] && ctl.current == FlowVirtualDevice.uid)
        worker.emit("capturing", session: sid)
        worker.emit("streaming", session: sid)
        precondition(ctl.setCalls.count == 1, "repeated live states must not re-route")
        precondition(store.isRunning)

        await store.stop(); await run.value
        precondition(ctl.restoreCalls == ["built-in"] && ctl.current == "built-in")
        precondition(Array(log.values.suffix(2)) == ["restore:built-in", "stop"],
                      "the Mac output must be restored before the worker stop command")
        precondition(!store.hasActiveSession && !store.isRunning)
        await store.prepareForTermination()
        precondition(worker.shutdowns == 1)
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

    @MainActor private static func assertStopDuringPreStartRoutingRestoresOutput() async {
        let gate = SettleGate()
        let ctl = FakeDefaultOutputController(current: "built-in")
        // Keep the route unpublished so the store is genuinely still waiting
        // when the stop arrives; that is the window this check covers.
        ctl.publishDelayReads = 2
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker },
                                     routeSettleSleep: { _ in await gate.wait() },
                                     observesEnvironment: false,
                                     defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices(); store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { ctl.setCalls == [FlowVirtualDevice.uid] }
        store.requestStop()
        gate.open()
        await run.value
        precondition(worker.starts == 0 && worker.stops == 0)
        precondition(ctl.current == "built-in" && ctl.restoreCalls == ["built-in"])
        precondition(!store.desiredEnabled && !store.hasActiveSession && !store.isBusy)
        await store.prepareForTermination()
    }

    /// A setter that returns noErr is not proof the system applied the route.
    /// Without a published change the switch must fail and capture stays closed.
    @MainActor private static func assertStartRequiresPublishedSwitch() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        ctl.publishDelayReads = .max
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false,
                                     defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        await store.start(mode: .synchronized, volume: 15)
        precondition(worker.starts == 0,
                     "capture must not start before the switch is published")
        precondition(!store.hasActiveSession && !store.desiredEnabled)
        precondition(store.statusText.contains("未在限定时间内切换"), store.statusText)
        await store.prepareForTermination()
    }

    /// The mirror case: turning the switch off must not report success before
    /// the Mac is really back on its own output.
    @MainActor private static func assertStopWaitsForPublishedRestore() async {
        let ctl = FakeDefaultOutputController(current: "built-in")
        let worker = RoutingWorker(virtual: true)
        let store = SystemAudioStore(serviceFactory: { worker }, observesEnvironment: false,
                                     defaultOutput: ctl)
        await store.connectLocalWorker(); await store.scanDevices()
        store.selectedDeviceIDs = ["receiver"]
        let run = Task { await store.start(mode: .synchronized, volume: 15) }
        await until { worker.starts == 1 }
        worker.emit("capturing", session: worker.startSession!)
        ctl.publishDelayReads = .max
        await store.stop(); await run.value
        precondition(ctl.restoreCalls == ["built-in"])
        precondition(worker.stops == 1)
        precondition(store.statusText.contains("未在限定时间内切回"), store.statusText)
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
        await run.value
        precondition(worker.starts == 0 && worker.stops == 0,
                     "a failed pre-start route must never open capture")
        precondition(ctl.current == "built-in")
        precondition(!store.hasActiveSession && !store.desiredEnabled)
        precondition(store.statusText.contains("默认输出切换"))
        precondition(!store.cleanupRequiresAttention)
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

@MainActor private final class OrderLog {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor private final class SettleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor private final class FakeDefaultOutputController: DefaultOutputControlling {
    var current: String?
    var running: Set<String> = []
    var setCalls: [String] = []
    var restoreCalls: [String] = []
    var failOnSet: Error?
    /// Number of reads the system takes before a write becomes visible.
    /// `Int.max` models a route that never publishes (Core Audio refused it).
    var publishDelayReads = 0
    private var pendingUID: String?
    private var pendingReads = 0
    private let log: OrderLog?
    private let known: Set<String> = ["built-in", FlowVirtualDevice.uid, "hdmi"]

    init(current: String?, log: OrderLog? = nil) {
        self.current = current
        self.log = log
    }

    func currentDefaultOutputUID() -> String? {
        if let pending = pendingUID {
            pendingReads += 1
            if pendingReads >= publishDelayReads {
                current = pending
                pendingUID = nil
                pendingReads = 0
            }
        }
        return current
    }

    func isDeviceRunning(uid: String) -> Bool? { running.contains(uid) }

    func setDefaultOutput(uid: String) throws -> Bool {
        setCalls.append(uid)
        log?.append("set:\(uid)")
        if let failOnSet { throw failOnSet }
        guard known.contains(uid) else { return false }
        if let old = current, running.contains(old) {
            running.remove(old)
            running.insert(uid)
        }
        publish(uid)
        return true
    }

    func restoreDefaultOutput(uid: String) -> Bool {
        restoreCalls.append(uid)
        log?.append("restore:\(uid)")
        guard known.contains(uid) else { return false }
        if let old = current, running.contains(old) {
            running.remove(old)
            running.insert(uid)
        }
        publish(uid)
        return true
    }

    private func publish(_ uid: String) {
        if publishDelayReads > 0 {
            pendingUID = uid
            pendingReads = 0
        } else {
            current = uid
        }
    }
}

@MainActor private final class FakeHardware: AudioHardwareAccessing {
    var defaultID: AudioObjectID
    var uids: [AudioObjectID: String]
    var streamCounts: [AudioObjectID: Int?]
    var runningIDs: Set<AudioObjectID> = []
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

    func isRunning(_ device: AudioObjectID) -> Bool? {
        runningIDs.contains(device)
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
    private let log: OrderLog?

    init(virtual: Bool, log: OrderLog? = nil) {
        runtime = .init(python: "/python", project: "/project", library: "/core",
                        capture_host: "/legacy", virtual_capture_host: virtual ? "/virtual" : nil)
        self.log = log
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
            log?.append("start")
            starts += 1; startSession = session
            return try await withCheckedThrowingContinuation { startContinuation = $0 }
        case "stop":
            log?.append("stop")
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
