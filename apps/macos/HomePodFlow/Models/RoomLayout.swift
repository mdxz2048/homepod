import Foundation

enum PlaybackMode: String, Codable, CaseIterable, Identifiable {
    case cinema, synchronized
    var id: Self { self }
    var title: String { self == .cinema ? "影院模式" : "同步播放" }
}

enum SpeakerKind: String, Codable, CaseIterable { case homePod, mini }
enum SpeakerRole: String, Codable, CaseIterable, Identifiable {
    case front, rearLeft, rearRight
    var id: Self { self }
    var title: String {
        switch self {
        case .front: "前方"
        case .rearLeft: "左后方"
        case .rearRight: "右后方"
        }
    }
}

struct RoomPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var clamped: Self { .init(x: Self.unit(x), y: Self.unit(y)) }
    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}

struct RoomDevice: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var position: RoomPoint
    var kind: SpeakerKind
    var role: SpeakerRole
    var host: String? = nil
    var stableIdentifier: String? = nil
}

struct RoomLayout: Codable, Equatable {
    var devices: [RoomDevice]
    var listener: RoomPoint
    static var empty: Self { .init(devices: [], listener: .init(x: 0.5, y: 0.83)) }
    static var demo: Self {
        .init(devices: [
            .init(name: "示例 HomePod", position: .init(x: 0.5, y: 0.29), kind: .homePod, role: .front),
            .init(name: "示例左 mini", position: .init(x: 0.2, y: 0.73), kind: .mini, role: .rearLeft),
            .init(name: "示例右 mini", position: .init(x: 0.8, y: 0.73), kind: .mini, role: .rearRight)
        ], listener: .init(x: 0.5, y: 0.83))
    }
    var normalized: Self {
        var result = self
        var seen = Set<UUID>()
        result.devices = devices.prefix(16).compactMap { device in
            guard seen.insert(device.id).inserted else { return nil }
            if let identifier = device.stableIdentifier {
                guard !identifier.isEmpty, identifier.count <= 1024 else { return nil }
            }
            var copy = device
            copy.name = String(copy.name.prefix(80))
            copy.position = copy.position.clamped
            return copy
        }
        result.listener = listener.clamped
        return result
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case layout, audio, playback, general, about
    var id: Self { self }
    var title: String {
        switch self {
        case .layout: "空间布局"
        case .audio: "音频处理"
        case .playback: "播放偏好"
        case .general: "通用设置"
        case .about: "关于"
        }
    }
    var icon: String {
        switch self {
        case .layout: "square.grid.2x2"
        case .audio: "waveform"
        case .playback: "play.circle"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}
