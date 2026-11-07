import Foundation

/// Worker-published latency outcome. The worker now owns the single
/// authoritative write (negotiated AirPlay latency plus the shared 500 ms
/// preparation), so the App only maps its verified report into display state.
/// No process spawn, await race, or fixed estimate lives on the App side.

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

    /// Parse the ``latency_state`` object published by the system worker on the
    /// existing ``state`` event surface. Playback can continue if latency
    /// compensation is unavailable.
    static func fromWorker(_ object: [String: JSONValue]) -> LatencyControlState? {
        guard let status = object["status"]?.string else { return nil }
        guard let milliseconds = object["target_ms"]?.number,
              let target = Int(exactly: milliseconds) else { return nil }
        let reported = object["reported_ms"]?.number
        let revision: UInt64? = {
            if let raw = object["revision"] {
                if case .integer(let value) = raw { return UInt64(exactly: value) }
                if let value = raw.number { return UInt64(exactly: value) }
            }
            return nil
        }()
        let pending = object["pending_reason"]?.string
        switch status {
        case "applied":
            return LatencyControlState(
                kind: .applied, estimatedMS: target, reportedMS: reported,
                revision: revision, applied: true,
                statusText: "音画延迟已应用 \(target) ms · 已回读验证"
                    + " · 如其他客户端正在播放，请重新打开其旧输出",
                pendingReason: nil)
        case "unchanged":
            return LatencyControlState(
                kind: .reported, estimatedMS: target, reportedMS: reported,
                revision: revision, applied: false,
                statusText: "音画延迟 \(target) ms 已读取 · 与协商值一致，未写入",
                pendingReason: nil)
        case "pending":
            return LatencyControlState(
                kind: .deferredPending, estimatedMS: target, reportedMS: reported,
                revision: revision, applied: false,
                statusText: "音画延迟写入已延后 · 设备空闲后重新启用系统音频",
                pendingReason: pending)
        case "failure":
            return LatencyControlState(
                kind: .invalid(object["detail"]?.string ?? "写入未验证"),
                estimatedMS: target, reportedMS: reported, revision: revision,
                applied: false,
                statusText: "音画延迟写入未验证 · \(object["detail"]?.string ?? "未知错误")",
                pendingReason: nil)
        default:
            return nil
        }
    }
}
