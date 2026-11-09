import Foundation

enum PlaybackMode: String, Codable, CaseIterable, Identifiable {
    case cinema, synchronized
    var id: Self { self }
    var title: String { self == .cinema ? "影院模式" : "同步播放" }
}

enum SpeakerForm: Equatable { case homePod, mini }

/// Persisted in the saved layout, so the two original raw values (`homePod`
/// and `mini`) must keep decoding for preferences written by older builds.
enum SpeakerKind: String, Codable, CaseIterable, Identifiable {
    case homePod
    case homePodMidnight
    case mini
    case miniMidnight
    case miniYellow
    case miniOrange
    case miniBlue
    case miniGreen
    case miniPink

    var id: Self { self }

    var form: SpeakerForm {
        switch self {
        case .homePod, .homePodMidnight: .homePod
        case .mini, .miniMidnight, .miniYellow, .miniOrange, .miniBlue, .miniGreen,
             .miniPink: .mini
        }
    }

    var displayName: String {
        switch self {
        case .homePod: "HomePod · 白色"
        case .homePodMidnight: "HomePod · 午夜色"
        case .mini: "HomePod mini · 白色"
        case .miniMidnight: "HomePod mini · 午夜色"
        case .miniYellow: "HomePod mini · 黄色"
        case .miniOrange: "HomePod mini · 橙色"
        case .miniBlue: "HomePod mini · 蓝色"
        case .miniGreen: "HomePod mini · 绿色"
        case .miniPink: "HomePod mini · 粉色"
        }
    }

    static let homePodChoices: [SpeakerKind] = [.homePod, .homePodMidnight]
    static let miniChoices: [SpeakerKind] = [.mini, .miniMidnight, .miniYellow, .miniOrange,
                                             .miniBlue, .miniGreen, .miniPink]
    static let menuChoices: [SpeakerKind] = homePodChoices + miniChoices
}

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
            .init(name: "示例 HomePod", position: .init(x: 0.5, y: 0.29), kind: .homePodMidnight, role: .front),
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
