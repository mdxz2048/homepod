import Foundation

/// A transport-specific adapter kept separate from the synchronous Demo service.
/// No UI object imports C++ or Python; Python hooks live in this owned child.
@MainActor final class WorkerRouterService {
    let runtime: WorkerRuntime
    let client = ManagedWorkerClient()
    init(runtime: WorkerRuntime) { self.runtime = runtime }
    func connect() async throws {
        try runtime.validate()
        try client.launch(executable: URL(fileURLWithPath: runtime.python),
                          arguments: ["-u", "-m", "adapters.worker"],
                          directory: URL(fileURLWithPath: runtime.project))
        do {
            let hello = try await client.request("hello")
            guard hello.payload["protocol_version"]?.number == 1,
                  hello.payload["core_abi_version"]?.number == 1 else {
                throw WorkerFailure.protocolViolation("Worker/core version mismatch")
            }
        } catch {
            try? await client.shutdown()
            throw error
        }
    }
    func request(_ command: String, params: [String: JSONValue] = [:],
                 session: String? = nil, timeout: Double = 15) async throws -> WorkerEvent {
        try await client.request(command, params: params, session: session, timeout: timeout)
    }
    func disconnect() async throws { try await client.shutdown() }
}
