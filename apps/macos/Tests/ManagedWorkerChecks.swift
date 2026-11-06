import Foundation

/// Exercises a real child process/OS pipes. The fixture deliberately violates
/// framing and timing, rather than reimplementing the client's parser.
@main struct ManagedWorkerChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass Python executable path") }
        let python = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        func launch(_ mode: String, client: ManagedWorkerClient = ManagedWorkerClient()) throws -> ManagedWorkerClient {
            try client.launch(executable: python, arguments: ["-u", script.path, mode], directory: directory)
            return client
        }

        let fragmented = try launch("fragment")
        let hello = try await fragmented.request("hello")
        precondition(hello.payload["ok"]?.bool == true)
        _ = try await fragmented.request("scan")
        try await Task.sleep(for: .milliseconds(50))
        precondition(fragmented.stderrTail.count <= 8192 && !fragmented.stderrTail.isEmpty)
        try await fragmented.shutdown()
        print("PASS: fragmented stdout, bounded stderr, graceful shutdown")

        for mode in ["bad-json", "oversize", "exit", "timeout"] {
            let client = try launch(mode)
            var failed = false
            do { _ = try await client.request("hello", timeout: 0.3) }
            catch {
                failed = true
                switch mode {
                case "exit":
                    guard case WorkerFailure.exited(let status) = error, status == 7 else {
                        preconditionFailure("Exit must be detected as exit(7), not timeout: \(error)")
                    }
                case "timeout":
                    guard case WorkerFailure.timeout = error else {
                        preconditionFailure("Expected explicit request timeout: \(error)")
                    }
                default:
                    guard case WorkerFailure.protocolViolation = error else {
                        preconditionFailure("Expected framing/protocol failure: \(error)")
                    }
                }
            }
            precondition(failed, "\(mode) must fail, never report successful state")
            // Explicit reconnect is allowed; stale termination/read callbacks
            // from the previous process must not poison this new generation.
            _ = try launch("fragment", client: client)
            let result = try await client.request("hello")
            precondition(result.payload["ok"]?.bool == true)
            try await client.shutdown()
        }
        print("PASS: malformed/oversize/exit/timeout failures and stale-process isolation")

        let sessionClient = try launch("sessions")
        var states: [String] = []
        sessionClient.onEvent = { event in
            if event.event == "state", let state = event.payload["state"]?.string { states.append(state) }
        }
        // Encoding/size rejection must not reserve the active session.
        do {
            _ = try await sessionClient.request("start", params: ["padding": .string(String(repeating: "x", count: 70000))],
                                                session: UUID().uuidString)
            preconditionFailure("Oversized request was accepted")
        } catch { }
        for _ in 0..<2 {
            let session = UUID().uuidString
            let start = Task { try await sessionClient.request("start", params: ["session": .string(session)], session: session) }
            try await Task.sleep(for: .milliseconds(100))
            let stop = try await sessionClient.request("stop", params: ["session": .string(session)], session: session)
            let done = try await start.value
            precondition(stop.payload["cleanup_complete"]?.bool == true)
            precondition(done.payload["state"]?.string == "stopped")
        }
        precondition(states == ["preparing", "stopped", "preparing", "stopped"], "Stale session event changed state")
        try await sessionClient.shutdown()
        print("PASS: session filtering, start/stop terminal race, repeated session, oversized-request rollback")
    }

    static let fixture = #"""
import sys, json, time, os
mode = sys.argv[1]
active = None
previous = None
def emit(r, event='result', payload=None, session=None):
    data = json.dumps(dict(v=1, id=r['id'], event=event, session=session, payload=payload or {})) + '\n'
    if mode == 'fragment':
        for i in range(0, len(data), 7):
            sys.stdout.write(data[i:i+7]); sys.stdout.flush(); time.sleep(.001)
    else:
        sys.stdout.write(data); sys.stdout.flush()
for line in sys.stdin:
    r = json.loads(line)
    command = r['command']
    if command == 'shutdown':
        emit(r, payload=dict(state='shutdown', cleanup_complete=True)); break
    if mode == 'bad-json':
        print('{bad-json}', flush=True); continue
    if mode == 'oversize':
        print('x' * 65536, flush=True); continue
    if mode == 'exit':
        os._exit(7)
    if mode == 'timeout':
        time.sleep(10); continue
    if command == 'hello':
        emit(r, payload=dict(ok=True))
    elif command == 'scan':
        sys.stderr.write('diagnostic ' * 2000); sys.stderr.flush()
        emit(r, payload=dict(devices=[]))
    elif command == 'start':
        active = r
        session = r['params']['session']
        if previous:
            emit(previous, 'state', dict(state='obsolete'), previous['params']['session'])
        emit(r, 'state', dict(state='wrong-session'), '00000000-0000-0000-0000-000000000000')
        emit(r, 'accepted', {}, session)
        emit(r, 'state', dict(state='preparing'), session)
    elif command == 'stop':
        session = active['params']['session']
        emit(active, 'state', dict(state='stopped'), session)
        emit(active, payload=dict(state='stopped', cleanup_complete=True), session=session)
        emit(r, payload=dict(state='stopped', cleanup_complete=True), session=session)
        previous, active = active, None
"""#
}
