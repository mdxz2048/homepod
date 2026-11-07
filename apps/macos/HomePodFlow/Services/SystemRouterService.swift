import Foundation

struct SystemAudioRuntime: Codable, Sendable {
    let python: String
    let project: String
    let library: String
    var capture_host: String
    var virtual_capture_host: String? = nil
    var latency_control: String? = nil
    var latency_ms: Double? = nil
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
        if let path = latency_control {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw WorkerFailure.unavailable("音画延迟校准工具未安装或不可执行")
            }
        }
        if let value = latency_ms {
            guard value.isFinite, (0...3000).contains(value) else {
                throw WorkerFailure.unavailable("音画延迟校准配置超出 0…3000 ms")
            }
        }
    }
}

/// Exact identity of the capture hosts embedded inside HomePod Flow.app/Contents/Helpers.
/// Kept here, not in generic configuration, so packaging and loading share one source of truth.
extension SystemAudioRuntime {
    enum PackagedHost {
        static let helpersDirectory = "Helpers"
        static let tapApp = "TapCaptureHost.app"
        static let virtualApp = "VirtualCaptureHost.app"
        static let tapExecutable = "tap-capture-host"
        static let virtualExecutable = "virtual-audio-host"
        static let tapBundleIdentifier = "com.homepodflow.tap-capture-host"
        static let virtualBundleIdentifier = "com.homepodflow.virtual-capture-host"
    }

    /// Replaces `capture_host` and `virtual_capture_host` with the embedded helper
    /// executables only when BOTH are present and fully valid. Returns false and leaves
    /// the decoded runtime.json host paths untouched when neither helper exists (legacy
    /// app without embedded helpers). Throws when exactly one helper exists or either
    /// bundle is malformed, so a partially packaged app fails loudly instead of quietly
    /// using stale external host paths. All other config fields are preserved.
    @discardableResult
    mutating func preferEmbeddedCaptureHosts(in helpers: URL) throws -> Bool {
        func executableURL(_ appName: String, _ executableName: String) -> URL {
            helpers.appendingPathComponent(appName)
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(executableName)
        }
        let tap = executableURL(PackagedHost.tapApp, PackagedHost.tapExecutable)
        let virtual = executableURL(PackagedHost.virtualApp, PackagedHost.virtualExecutable)
        let manager = FileManager.default
        let hasTap = manager.fileExists(atPath: helpers.appendingPathComponent(PackagedHost.tapApp).path)
        let hasVirtual = manager.fileExists(atPath: helpers.appendingPathComponent(PackagedHost.virtualApp).path)

        guard hasTap || hasVirtual else { return false }
        guard hasTap && hasVirtual else {
            let missing = hasTap ? PackagedHost.virtualApp : PackagedHost.tapApp
            throw WorkerFailure.unavailable("内置采集组件不完整：缺少 \(missing)，已拒绝使用旧的外部组件")
        }
        try Self.requireValidEmbeddedHost(app: helpers.appendingPathComponent(PackagedHost.tapApp),
                                          executableName: PackagedHost.tapExecutable,
                                          bundleIdentifier: PackagedHost.tapBundleIdentifier,
                                          label: "TapCaptureHost")
        try Self.requireValidEmbeddedHost(app: helpers.appendingPathComponent(PackagedHost.virtualApp),
                                          executableName: PackagedHost.virtualExecutable,
                                          bundleIdentifier: PackagedHost.virtualBundleIdentifier,
                                          label: "VirtualCaptureHost")
        capture_host = tap.path
        virtual_capture_host = virtual.path
        return true
    }

    private static func requireValidEmbeddedHost(app: URL, executableName: String,
                                                 bundleIdentifier: String, label: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 的 App 包不存在")
        }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 缺少可执行文件 \(executableName)")
        }
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 的 Info.plist 无效")
        }
        guard info["CFBundleExecutable"] as? String == executableName else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 的可执行文件名不匹配（期望 \(executableName)）")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 的 Bundle ID 不匹配")
        }
        guard let usage = info["NSAudioCaptureUsageDescription"] as? String, !usage.isEmpty else {
            throw WorkerFailure.unavailable("内置采集组件 \(label) 缺少音频采集用途说明")
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
        var runtime = try JSONDecoder().decode(SystemAudioRuntime.self, from: Data(contentsOf: url))
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent(SystemAudioRuntime.PackagedHost.helpersDirectory)
        try runtime.preferEmbeddedCaptureHosts(in: helpers)
        return SystemRouterService(runtime: runtime)
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
