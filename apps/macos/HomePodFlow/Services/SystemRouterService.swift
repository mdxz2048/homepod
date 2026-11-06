import Foundation

struct SystemAudioRuntime: Codable, Sendable {
    let python: String
    let project: String
    let library: String
    let capture_host: String
    var virtual_capture_host: String? = nil
    func validate() throws {
        try WorkerRuntime(python: python, project: project, library: library).validate()
        guard capture_host.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: capture_host) else {
            throw WorkerFailure.unavailable("系统音频采集组件未安装")
        }
        if let path = virtual_capture_host {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw WorkerFailure.unavailable("Flow 虚拟声卡采集组件未安装")
            }
        }
    }
}

/// An owned service process; the store can be checked with a deterministic, silent backend.
@MainActor protocol SystemAudioRouting: AnyObject {
    var runtime: SystemAudioRuntime { get }
    var onEvent: ((WorkerEvent) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var supportsRealtimeVolume: Bool { get }
    var supportsVirtualInput: Bool { get }
    func connect() async throws
    func request(_ command: String, params: [String: JSONValue], session: String?, timeout: Double?) async throws -> WorkerEvent
    func disconnect() async throws
    func abortProtocol(_ message: String)
}
extension SystemAudioRouting {
    var supportsRealtimeVolume: Bool { false }
    var supportsVirtualInput: Bool { false }
}

@MainActor final class SystemRouterService: SystemAudioRouting {
    let runtime: SystemAudioRuntime
    let client = ManagedWorkerClient()
    private(set) var supportsRealtimeVolume = false
    private(set) var supportsVirtualInput = false
    init(runtime: SystemAudioRuntime) { self.runtime = runtime }
    var onEvent: ((WorkerEvent) -> Void)? {
        get { client.onEvent }
        set { client.onEvent = newValue }
    }
    var onFailure: ((String) -> Void)? {
        get { client.onFailure }
        set { client.onFailure = newValue }
    }
    static func installed() throws -> SystemRouterService {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WorkerFailure.unavailable("无法定位本机运行环境")
        }
        let url = support.appendingPathComponent("HomePod Flow/runtime.json")
        return SystemRouterService(runtime: try JSONDecoder().decode(SystemAudioRuntime.self, from: Data(contentsOf: url)))
    }
    func connect() async throws {
        try runtime.validate()
        try client.launch(executable: URL(fileURLWithPath: runtime.python),
            arguments: ["-u", "-m", "adapters.system_worker"], directory: URL(fileURLWithPath: runtime.project))
        do {
            let hello = try await client.request("hello")
            guard hello.payload["protocol_version"]?.number == 1,
                  hello.payload["core_abi_version"]?.number == 1,
                  hello.payload["capabilities"]?.object?["system_audio"]?.bool == true else {
                throw WorkerFailure.protocolViolation("System-audio service version/capability mismatch")
            }
            supportsRealtimeVolume = hello.payload["capabilities"]?.object?["realtime_volume"]?.bool == true
            supportsVirtualInput = hello.payload["capabilities"]?.object?["virtual_device_v2"]?.bool == true
        } catch { try? await client.shutdown(); throw error }
    }
    func request(_ command: String, params: [String: JSONValue] = [:],
                 session: String? = nil, timeout: Double? = 15) async throws -> WorkerEvent {
        try await client.request(command, params: params, session: session, timeout: timeout)
    }
    func disconnect() async throws { try await client.shutdown() }
    func abortProtocol(_ message: String) { client.abortProtocol(message) }
}
