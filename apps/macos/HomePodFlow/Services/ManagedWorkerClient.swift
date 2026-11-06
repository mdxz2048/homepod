import Foundation
import Darwin

/// One owned process. All state is confined to the main actor; readability
/// handlers only pass immutable bytes back here. No shell or global patching.
@MainActor final class ManagedWorkerClient {
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var stderrTail = Data()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var generation = UUID()
    private var buffer = Data()
    private var activeSession: String?
    private var expectsExit = false
    private var pending: [String: Pending] = [:]
    private var contexts: [String: String] = [:]
    private struct Pending {
        let command: String
        let expectedSession: String?
        let continuation: CheckedContinuation<WorkerEvent, any Error>
        let timeout: Task<Void, Never>?
    }

    func launch(executable: URL, arguments: [String], directory: URL) throws {
        guard process == nil else { throw WorkerFailure.unavailable("服务进程已存在") }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        generation = UUID()
        let token = generation
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = stderr.fileHandleForReading
        buffer.removeAll(); stderrTail.removeAll(); activeSession = nil; contexts.removeAll(); expectsExit = false
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data, generation: token) }
        }
        errorOutput?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receiveStderr(data, generation: token) }
        }
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor in
                // Drain queued stdout callbacks before treating outstanding
                // requests as failed; shutdown emits its reply just before exit.
                try? await Task.sleep(for: .milliseconds(80))
                self?.terminated(status, generation: token)
            }
        }
        process = child
        do { try child.run() }
        catch { releaseHandles(); process = nil; throw error }
    }

    func request(_ command: String, params: [String: JSONValue] = [:],
                 session: String? = nil, timeout seconds: Double? = 15) async throws -> WorkerEvent {
        guard let process, process.isRunning, let input else {
            throw WorkerFailure.unavailable("服务未连接")
        }
        if let seconds {
            guard seconds.isFinite, seconds > 0, seconds <= 7200 else {
                throw WorkerFailure.protocolViolation("Invalid request deadline")
            }
        } else if command != "start" {
            throw WorkerFailure.protocolViolation("Only live start may wait without a natural deadline")
        }
        if command == "start", activeSession != nil || session == nil {
            throw WorkerFailure.unavailable("已有活动会话或缺少会话标识")
        }
        let id = UUID().uuidString
        let request = WorkerRequest(id: id, command: command, params: params)
        var bytes = try JSONEncoder().encode(request)
        bytes.append(10)
        guard bytes.count <= 65536 else { throw WorkerFailure.protocolViolation("Request exceeds 64 KiB") }
        if command == "start" { activeSession = session }
        let token = generation
        if command == "shutdown" { expectsExit = true }
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask: Task<Void, Never>? = seconds.map { deadline in
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(deadline)) }
                    catch { return }
                    guard let self, self.generation == token, self.pending[id] != nil else { return }
                    self.fail(WorkerFailure.timeout(command))
                }
            }
            pending[id] = Pending(command: command, expectedSession: session,
                                  continuation: continuation, timeout: timeoutTask)
            if let session { contexts[id] = session }
            do { try input.write(contentsOf: bytes) }
            catch { fail(error) }
        }
    }

    func shutdown() async throws {
        guard let owned = process else { return }
        do {
            let reply = try await request("shutdown", timeout: 15)
            guard reply.payload["cleanup_complete"]?.bool == true else { throw WorkerFailure.cleanupUnconfirmed }
            let deadline = Date().addingTimeInterval(2)
            while owned.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            if owned.isRunning { throw WorkerFailure.cleanupUnconfirmed }
            guard owned.terminationStatus == 0 else { throw WorkerFailure.exited(owned.terminationStatus) }
            invalidate(error: nil, force: false)
        } catch {
            invalidate(error: error, force: true)
            let deadline = Date().addingTimeInterval(1)
            while owned.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            if owned.isRunning { Darwin.kill(owned.processIdentifier, SIGKILL) }
            throw error
        }
    }
    func abortProtocol(_ message: String) { fail(WorkerFailure.protocolViolation(message)) }

    private func receive(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        guard !data.isEmpty else { output?.readabilityHandler = nil; return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, line.count + 1 <= 65536 else {
                fail(WorkerFailure.protocolViolation("Invalid stdout line size")); return
            }
            do {
                let event = try JSONDecoder().decode(WorkerEvent.self, from: line)
                handle(event)
            } catch { fail(WorkerFailure.protocolViolation("Malformed stdout JSONL")); return }
        }
        if buffer.count > 65536 { fail(WorkerFailure.protocolViolation("Unterminated stdout exceeds 64 KiB")) }
    }
    private func receiveStderr(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        if data.isEmpty { errorOutput?.readabilityHandler = nil; return }
        stderrTail.append(data)
        if stderrTail.count > 8192 { stderrTail = Data(stderrTail.suffix(8192)) }
    }
    private func handle(_ event: WorkerEvent) {
        guard let id = event.id else {
            // Null-id protocol errors are diagnostics, never state transitions.
            if event.event == "error" { onEvent?(event) }
            return
        }
        guard let request = pending[id] else { return }
        guard request.expectedSession == event.session else { return }
        if let session = event.session {
            guard contexts[id] == session else { return }
            if request.command == "start", activeSession != session { return }
        }
        onEvent?(event)
        guard event.event == "result" || event.event == "error" else { return }
        pending.removeValue(forKey: id)
        request.timeout?.cancel()
        contexts.removeValue(forKey: id)
        if request.command == "start" { activeSession = nil }
        if event.event == "error" {
            request.continuation.resume(throwing: WorkerFailure.remote(
                event.payload["message"]?.string ?? event.payload["code"]?.string ?? "音频服务拒绝请求"))
            if ["cleanup_failed", "worker_poisoned"].contains(event.payload["code"]?.string ?? "")
                || event.payload["cleanup_complete"]?.bool == false {
                fail(WorkerFailure.cleanupUnconfirmed)
            }
        } else { request.continuation.resume(returning: event) }
    }
    private func terminated(_ status: Int32, generation token: UUID) {
        guard token == generation else { return }
        if !buffer.isEmpty { fail(WorkerFailure.protocolViolation("Process exited with incomplete stdout line")); return }
        if !pending.isEmpty { fail(WorkerFailure.exited(status)); return }
        releaseHandles(); process = nil
        if !expectsExit || status != 0 { onFailure?(WorkerFailure.exited(status).localizedDescription) }
    }
    private func fail(_ error: any Error) { invalidate(error: error, force: true) }
    private func invalidate(error: (any Error)?, force: Bool) {
        let owned = process
        generation = UUID()
        process = nil; activeSession = nil
        let requests = pending.values
        pending.removeAll(); contexts.removeAll(); buffer.removeAll()
        for request in requests {
            request.timeout?.cancel()
            request.continuation.resume(throwing: error ?? WorkerFailure.unavailable("服务已断开"))
        }
        releaseHandles()
        if force, let owned, owned.isRunning {
            owned.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if owned.isRunning { Darwin.kill(owned.processIdentifier, SIGKILL) }
            }
        }
        if let error { onFailure?(error.localizedDescription) }
    }
    private func releaseHandles() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errorOutput?.close()
        input = nil; output = nil; errorOutput = nil
    }
}
