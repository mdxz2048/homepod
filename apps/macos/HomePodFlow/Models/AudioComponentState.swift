import Foundation

/// The virtual sound card is a system-wide HAL plug-in, not an in-process
/// resource. The App can only install it through the signed installer package;
/// this model keeps the user-visible state separate from CoreAudio probing.
enum AudioComponentState: String, Equatable, Sendable {
    case checking
    case notInstalled
    case installedNeedsReload
    case ready
    case conflict
    case invalid
}

struct AudioComponentBundle: Equatable, Sendable {
    var path: String
    var version: String?
    var executable: String
    var bundleIdentifier: String
    var isValid: Bool
}

struct AudioComponentSnapshot: Equatable, Sendable {
    var state: AudioComponentState
    var message: String
    var driverVersion: String?
    var driverPath: String?
    var deviceUID: String
    var devicePresent: Bool
    var canInstall: Bool

    static func checking(deviceUID: String) -> Self {
        .init(state: .checking,
              message: "正在检查音频组件…",
              driverVersion: nil,
              driverPath: nil,
              deviceUID: deviceUID,
              devicePresent: false,
              canInstall: false)
    }
}

/// Pure state mapping. Keep this free of CoreAudio so it can be compiled and
/// checked on a machine without a HAL device.
enum AudioComponentEvaluator {
    static let expectedBundleIdentifier = "com.homepodflow.audio.driver"
    static let expectedExecutable = "HomePodFlowAudioFamily"

    static func evaluate(bundles: [AudioComponentBundle],
                         devicePresent: Bool,
                         deviceUID: String,
                         installerAvailable: Bool) -> AudioComponentSnapshot {
        if bundles.isEmpty {
            return .init(state: .notInstalled,
                         message: "还没有安装 HomePod Flow 声卡。安装后系统会出现 “HomePod Flow Audio”。",
                         driverVersion: nil,
                         driverPath: nil,
                         deviceUID: deviceUID,
                         devicePresent: false,
                         canInstall: installerAvailable)
        }

        guard bundles.count == 1, let bundle = bundles.first else {
            return .init(state: .conflict,
                         message: "发现多个 HomePod Flow 声卡副本，请重新安装以只保留一个。",
                         driverVersion: nil,
                         driverPath: bundles.first?.path,
                         deviceUID: deviceUID,
                         devicePresent: devicePresent,
                         canInstall: installerAvailable)
        }

        guard bundle.isValid else {
            return .init(state: .invalid,
                         message: "音频组件文件不完整，请重新安装。",
                         driverVersion: bundle.version,
                         driverPath: bundle.path,
                         deviceUID: deviceUID,
                         devicePresent: devicePresent,
                         canInstall: installerAvailable)
        }

        if devicePresent {
            return .init(state: .ready,
                         message: "HomePod Flow Audio 已就绪。",
                         driverVersion: bundle.version,
                         driverPath: bundle.path,
                         deviceUID: deviceUID,
                         devicePresent: true,
                         canInstall: installerAvailable)
        }

        return .init(state: .installedNeedsReload,
                     message: "声卡已安装，但系统尚未加载。macOS 可能因 SIP 拒绝自动重载音频服务；请重新启动 Mac。",
                     driverVersion: bundle.version,
                     driverPath: bundle.path,
                     deviceUID: deviceUID,
                     devicePresent: false,
                     canInstall: installerAvailable)
    }
}
