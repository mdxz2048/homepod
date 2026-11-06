import Foundation

enum RouterResult: Equatable {
    case simulated(String)
    case unsupported(String)
    case failed(String)
    var message: String {
        switch self {
        case .simulated(let message), .unsupported(let message), .failed(let message): message
        }
    }
}

/// UI depends on this boundary. A future worker adapter must report confirmed
/// transport state separately; demo success is never a real connection event.
@MainActor protocol RouterService {
    var isDemo: Bool { get }
    func setRunning(_ running: Bool) -> RouterResult
    func testSound() -> RouterResult
}

@MainActor final class DemoRouterService: RouterService {
    let isDemo = true
    func setRunning(_ running: Bool) -> RouterResult {
        .simulated(running ? "演示已开启 · 未接管音频" : "演示已停止 · 未连接音箱")
    }
    func testSound() -> RouterResult {
        .unsupported("界面演示不会播放声音；真实测试需接入音频服务。")
    }
}
