import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

struct WorkerRequest: Encodable, Sendable {
    let v = 1
    let id: String
    let command: String
    let params: [String: JSONValue]
}

struct WorkerEvent: Decodable, Sendable {
    let v: Int
    let id: String?
    let event: String
    let session: String?
    let payload: [String: JSONValue]
    enum CodingKeys: String, CodingKey { case v, id, event, session, payload }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        guard container.contains(.id), container.contains(.session) else {
            throw WorkerFailure.protocolViolation("Missing id/session")
        }
        id = try container.decodeIfPresent(String.self, forKey: .id)
        event = try container.decode(String.self, forKey: .event)
        session = try container.decodeIfPresent(String.self, forKey: .session)
        payload = try container.decode([String: JSONValue].self, forKey: .payload)
        guard v == 1, ["accepted", "state", "result", "error"].contains(event) else {
            throw WorkerFailure.protocolViolation("Unsupported protocol version/event")
        }
    }
}

enum WorkerFailure: LocalizedError, Sendable {
    case unavailable(String), protocolViolation(String), timeout(String), exited(Int32), remote(String), cleanupUnconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "音频服务不可用：\(message)"
        case .protocolViolation(let message): "音频服务协议错误：\(message)"
        case .timeout(let command): "音频服务请求超时：\(command)，清理结果未确认"
        case .exited(let code): "音频服务退出（\(code)），未自动重启；清理结果未确认"
        case .remote(let message): message
        case .cleanupUnconfirmed: "音频服务已中断，未能确认音箱会话已清理"
        }
    }
}

struct WorkerRuntime: Codable, Sendable {
    let python: String
    let project: String
    let library: String
    func validate() throws {
        let manager = FileManager.default
        guard [python, project, library].allSatisfy({ $0.hasPrefix("/") }),
              manager.isExecutableFile(atPath: python),
              manager.fileExists(atPath: library) else {
            throw WorkerFailure.unavailable("本机运行环境未安装或路径无效")
        }
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: project, isDirectory: &directory), directory.boolValue else {
            throw WorkerFailure.unavailable("本机服务目录不存在")
        }
    }
}

struct DiscoveredDevice: Identifiable, Sendable, Equatable {
    var id: String { host }
    let name: String
    let host: String
    let model: String
    let identifier: String?
    init(name: String, host: String, model: String = "", identifier: String? = nil) {
        self.name = name; self.host = host; self.model = model
        self.identifier = identifier
    }
}
struct DeviceRouteSelection: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let host: String
    var isSelected = false
    var leftChannel = 0
    var rightChannel = 1
}
struct AudioInfo: Sendable, Equatable {
    let sampleRate: Int
    let channels: Int
    var sourceChannels: Int { channels }
    let frames: Int
    let durationSeconds: Double
}
