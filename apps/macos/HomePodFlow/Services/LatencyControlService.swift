import Darwin
import Foundation

/// Opt-in product latency calibration: a bounded, shell-free wrapper around the
/// standalone `hflctl` helper. It only reads the exact product 8-channel
/// device, writes when idle, defers when another client owns IO, and passes a
/// verified status transcript back to the worker for plan comparison.

enum LatencyReportError: Error, CustomStringConvertible {
    case unavailable(String)
    case unverified(String)

    var description: String {
        switch self {
        case .unavailable(let message): "延迟校准不可用：\(message)"
        case .unverified(let message): "延迟校准未验证：\(message)"
        }
    }
}

enum LatencyControlOutcomeKind: Equatable {
    case disabled
    case reported
    case applied
    case deferredPending
    case invalid(String)
    case unavailable(String)
}

struct LatencyControlState: Equatable {
    var kind: LatencyControlOutcomeKind
    var estimatedMS: Int
    var reportedMS: Double?
    var revision: UInt64?
    var applied: Bool
    var statusText: String
    var pendingReason: String?
}

struct LatencyControlPreparation {
    let state: LatencyControlState
    let verified: VerifiedLatencyReport?
}

/// Stable, verified report sent to the worker's virtual-input descriptor.
/// It contains only numbers the helper already read back; no acoustic claim.
struct VerifiedLatencyReport: Sendable {
    let nominalRate: Double
    let hflaFrames: Int
    let hflaMS: Double
    let revision: UInt64
    let deviceRunning: Bool

    var workerObject: [String: JSONValue] {
        [
            "verified": .bool(true),
            "tool": .string("hflctl"),
            "command": .string("status"),
            "uid": .string(LatencyControlService.deviceUID),
            "model_uid": .string(LatencyControlService.modelUID),
            "channels": .integer(8),
            "nominal_rate": .number(nominalRate),
            "hfla_frames": .integer(hflaFrames),
            "hfla_ms": .number(hflaMS),
            "hflr": .integer(Int(revision)),
            "stream_latency_global_frames": .integer(hflaFrames),
            "stream_latency_output_frames": .integer(hflaFrames),
            "latency_scopes_match": .bool(true),
            "control_scope_match": .bool(true),
            "device_is_running": .bool(deviceRunning),
        ]
    }
}

enum LatencyEstimate {
    static let observedSamples = 66150
    static let observedSampleRate = 44100
    static let preparationMS = 500
    static let minMS = 0
    static let maxMS = 3000
    /// One explicit formula: previously observed 66150 samples at 44100 Hz,
    /// plus the shared 500 ms preparation budget.
    static let defaultMilliseconds = observedSamples * 1000 / observedSampleRate + preparationMS // 2000

    static func resolve(configuredMS: Double?) -> Int {
        guard let value = configuredMS, value.isFinite else { return defaultMilliseconds }
        return min(max(Int(value.rounded()), minMS), maxMS)
    }
}

@MainActor protocol LatencyControlPreparing: AnyObject {
    var enabled: Bool { get }
    func prepare() async -> LatencyControlPreparation
}

@MainActor protocol LatencyControlRunning: AnyObject {
    func run(executable: String, arguments: [String],
             timeout: TimeInterval) async throws -> (exitCode: Int32, stdout: Data, stderr: Data)
}

@MainActor final class ProcessLatencyRunner: LatencyControlRunning {
    static let maxOutputBytes = 65536

    func run(executable: String, arguments: [String],
             timeout: TimeInterval) async throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LatencyReportError.unavailable("helper 无法启动")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(100))
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let boundedOut = stdout.count > Self.maxOutputBytes ? Data(stdout.prefix(Self.maxOutputBytes)) : stdout
        let boundedErr = stderr.count > Self.maxOutputBytes ? Data(stderr.prefix(Self.maxOutputBytes)) : stderr
        return (process.terminationStatus, boundedOut, boundedErr)
    }
}

@MainActor final class LatencyControlService: LatencyControlPreparing {
    nonisolated static let deviceUID = "com.homepodflow.virtual-audio.surround71.v1"
    nonisolated static let modelUID = "com.homepodflow.virtual-audio.model.surround71.v1"

    private let executable: String
    private let estimatedMS: Int
    private let runner: any LatencyControlRunning

    var enabled: Bool { !executable.isEmpty }

    init(executablePath: String?, configuredMS: Double?, runner: (any LatencyControlRunning)? = nil) {
        self.executable = executablePath ?? ""
        self.estimatedMS = LatencyEstimate.resolve(configuredMS: configuredMS)
        self.runner = runner ?? ProcessLatencyRunner()
    }

    func prepare() async -> LatencyControlPreparation {
        guard enabled else {
            return LatencyControlPreparation(state: LatencyControlState(
                kind: .disabled, estimatedMS: estimatedMS, reportedMS: nil, revision: nil, applied: false,
                statusText: "音画延迟校准未启用 · 使用估算 \(estimatedMS) ms"), verified: nil)
        }

        let status: (Int32, Data, Data)
        do {
            status = try await runner.run(executable: executable, arguments: ["status"], timeout: 5)
        } catch {
            return unavailable("helper 启动失败")
        }
        guard status.0 == 0 else {
            return unavailable(Self.errorDetail(stdout: status.1, stderr: status.2))
        }
        guard let statusObject = try? Self.jsonObject(status.1),
              statusObject["ok"] as? Bool == true,
              statusObject["command"] as? String == "status",
              let device = statusObject["device"] as? [String: Any],
              let verified = try? Self.parseSnapshot(device) else {
            return invalid("设备报告未通过 8 通道/作用域一致性校验")
        }

        if Int(verified.hflaMS.rounded()) == estimatedMS {
            return verifiedResult(verified, applied: false,
                statusText: "音画延迟 \(estimatedMS) ms 已读取 · 与估算一致，未写入")
        }
        if verified.deviceRunning {
            return deferred("设备正被其他客户端占用（如浏览器）")
        }

        let write: (Int32, Data, Data)
        do {
            write = try await runner.run(executable: executable,
                arguments: ["set-ms", String(estimatedMS), "--expect-revision", String(verified.revision)],
                timeout: 8)
        } catch {
            return unavailable("延迟写入请求失败")
        }
        guard write.0 == 0,
              let appliedObject = try? Self.jsonObject(write.1),
              appliedObject["ok"] as? Bool == true,
              let after = appliedObject["after"] as? [String: Any],
              let readback = try? Self.parseSnapshot(after) else {
            if Self.isBusy(write.1) { return deferred("写入时设备被占用（如浏览器）") }
            return invalid(Self.errorDetail(stdout: write.1, stderr: write.2))
        }
        guard Int(readback.hflaMS.rounded()) == estimatedMS else {
            return invalid("写入后回读值与请求不一致")
        }
        if appliedObject["applied"] as? Bool == true {
            return verifiedResult(readback, applied: true,
                statusText: "音画延迟已应用 \(estimatedMS) ms · 已回读验证")
        }
        return verifiedResult(readback, applied: false,
            statusText: "音画延迟 \(estimatedMS) ms 已确认 · 无需写入")
    }

    private func verifiedResult(_ report: VerifiedLatencyReport, applied: Bool,
                                statusText: String) -> LatencyControlPreparation {
        LatencyControlPreparation(state: LatencyControlState(
            kind: applied ? .applied : .reported, estimatedMS: estimatedMS,
            reportedMS: report.hflaMS, revision: report.revision, applied: applied,
            statusText: statusText), verified: report)
    }

    private func deferred(_ reason: String) -> LatencyControlPreparation {
        LatencyControlPreparation(state: LatencyControlState(
            kind: .deferredPending, estimatedMS: estimatedMS, reportedMS: nil, revision: nil, applied: false,
            statusText: "音画延迟写入已延后 · 关闭占用后重新连接本机服务即可",
            pendingReason: reason), verified: nil)
    }

    private func invalid(_ reason: String) -> LatencyControlPreparation {
        LatencyControlPreparation(state: LatencyControlState(
            kind: .invalid(reason), estimatedMS: estimatedMS, reportedMS: nil, revision: nil, applied: false,
            statusText: "音画延迟校准未验证 · \(reason)"), verified: nil)
    }

    private func unavailable(_ reason: String) -> LatencyControlPreparation {
        LatencyControlPreparation(state: LatencyControlState(
            kind: .unavailable(reason), estimatedMS: estimatedMS, reportedMS: nil, revision: nil, applied: false,
            statusText: "音画延迟校准不可用 · \(reason)"), verified: nil)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LatencyReportError.unavailable("输出不是对象")
        }
        return object
    }

    private static func parseSnapshot(_ snapshot: [String: Any]) throws -> VerifiedLatencyReport {
        func bool(_ key: String) -> Bool { (snapshot[key] as? NSNumber)?.boolValue ?? false }
        func number(_ key: String) -> NSNumber? { snapshot[key] as? NSNumber }

        guard snapshot["uid"] as? String == deviceUID,
              snapshot["model_uid"] as? String == modelUID,
              let channels = number("channels"), channels.intValue == 8,
              bool("alive") else {
            throw LatencyReportError.unverified("非产品 8 通道设备或设备未激活")
        }
        guard let rate = number("nominal_rate"),
              (rate.doubleValue == 44100 || rate.doubleValue == 48000),
              let frames = number("hfla_frames"),
              let ms = number("hfla_ms"),
              let revision = number("hflr"), revision.uint64Value >= 1,
              bool("latency_scopes_match"), bool("control_scope_match"),
              let global = number("stream_latency_global_frames"),
              let output = number("stream_latency_output_frames"),
              global.intValue == frames.intValue, output.intValue == frames.intValue else {
            throw LatencyReportError.unverified("作用域/控制值不一致")
        }
        let milliseconds = ms.doubleValue
        let expected = Double(frames.intValue) * 1000.0 / rate.doubleValue
        guard milliseconds.isFinite,
              (Double(LatencyEstimate.minMS)...Double(LatencyEstimate.maxMS)).contains(milliseconds),
              abs(milliseconds - expected) <= 0.51 else {
            throw LatencyReportError.unverified("hfla_ms 与帧数/采样率不符或超出 0…3000ms")
        }
        return VerifiedLatencyReport(nominalRate: rate.doubleValue, hflaFrames: frames.intValue,
            hflaMS: milliseconds, revision: revision.uint64Value,
            deviceRunning: bool("device_is_running") || bool("device_is_running_somewhere"))
    }

    private static func isBusy(_ stdout: Data) -> Bool {
        guard let object = try? jsonObject(stdout),
              let error = object["error"] as? [String: Any] else { return false }
        return error["kind"] as? String == "device_busy"
    }

    private static func errorDetail(stdout: Data, stderr: Data) -> String {
        if let object = try? jsonObject(stdout), let error = object["error"] as? [String: Any] {
            return error["kind"] as? String ?? error["message"] as? String ?? "未知错误"
        }
        let text = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "输出无法解析" : String(text.prefix(120))
    }
}
