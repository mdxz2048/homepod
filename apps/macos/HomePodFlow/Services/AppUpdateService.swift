import Foundation
import Observation

/// Signed feed + complete pkg upgrade. No system mutation happens before the
/// downloaded package passes both the pinned feed signature and SHA256 checks.
@Observable @MainActor final class AppUpdateService {
    private(set) var release: AppUpdateRelease?
    private(set) var status = "尚未检查更新"
    private(set) var checking = false
    private(set) var isInstalling = false
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var installer: Process?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let feedURL: URL?
    @ObservationIgnored private let publicKey: Data?
    let currentVersion: String
    let currentBuild: Int

    init(bundle: Bundle = .main) {
        feedURL = (bundle.object(forInfoDictionaryKey: "FlowUpdateFeedURL") as? String).flatMap(URL.init(string:))
        publicKey = (bundle.object(forInfoDictionaryKey: "FlowUpdatePublicKey") as? String).flatMap { Data(base64Encoded: $0) }
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    func checkIfNeeded() async {
        guard lastCheck.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        await check()
    }

    func check() async {
        guard !checking, !isInstalling else { return }
        guard let feedURL, feedURL.scheme == "https", let publicKey else {
            status = "此构建未配置更新地址"; return
        }
        checking = true; status = "正在检查更新…"
        defer { checking = false; lastCheck = Date() }
        do {
            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url?.scheme == "https" else { throw AppUpdateError.invalid("无法取得版本信息") }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let candidate = try AppUpdateValidation.decode(data, publicKey: publicKey, feedURL: feedURL,
                architecture: architecture, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            if try AppUpdateValidation.isNewer(candidate, currentVersion: currentVersion, currentBuild: currentBuild) {
                release = candidate; status = "发现新版本 \(candidate.version) · 安装后需要重启 Mac"
            } else {
                release = nil; status = "当前已是最新版本"
            }
        } catch { release = nil; status = error.localizedDescription }
    }

    func install(prepare: @MainActor () async throws -> Void) async {
        guard let release, !checking, !isInstalling else { return }
        isInstalling = true
        var directory: URL?
        var launched = false
        defer {
            if !launched {
                isInstalling = false
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        }
        do {
            status = "正在下载 \(release.version)…"
            let (download, response) = try await session.download(from: release.packageURL)
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https" else {
                throw AppUpdateError.invalid("安装包下载失败")
            }
            status = "正在校验安装包…"
            // Hash large packages away from the UI thread.
            try await Task.detached { try AppUpdateValidation.verifyPackage(download, release: release) }.value
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                .appendingPathComponent("com.homepodflow.mac/Updates", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            directory = cache
            let package = cache.appendingPathComponent("HomePodFlow.pkg")
            try FileManager.default.moveItem(at: download, to: package)
            status = "正在停止播放并恢复 Mac 默认输出…"
            try await prepare()
            status = "等待系统授权安装 · 完成后请重新启动 Mac"
            try launchInstaller(package: package, release: release)
            launched = true
            // osascript lives outside the App: it survives preinstall quitting
            // this version, and displays the reboot reminder after installer exits.
        } catch { status = error.localizedDescription }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func launchInstaller(package: URL, release: AppUpdateRelease) throws {
        let quoted = Self.shellQuote(package.path)
        let command = "set -eu; stage=$(/usr/bin/mktemp -d /private/var/tmp/homepodflow-update.XXXXXX); trap '/bin/rm -rf \"$stage\"' EXIT; /bin/chmod 700 \"$stage\"; /bin/cp \(quoted) \"$stage/update.pkg\"; test \"$(/usr/bin/shasum -a 256 \"$stage/update.pkg\" | /usr/bin/awk '{print $1}')\" = \(Self.shellQuote(release.sha256)); /usr/sbin/installer -pkg \"$stage/update.pkg\" -target /; /usr/bin/codesign --verify --deep --strict '/Applications/HomePod Flow.app'; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/HomePod Flow.app/Contents/Info.plist')\" = \(release.build); /bin/rm -rf \(Self.shellQuote(package.deletingLastPathComponent().path))"
        let script = "do shell script \(Self.appleScriptString(command)) with administrator privileges\ndisplay dialog \(Self.appleScriptString("HomePod Flow 已更新。请重新启动 Mac，使新声卡驱动生效。")) buttons {\"知道了\"} default button \"知道了\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let logURL = package.deletingLastPathComponent().appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log; process.standardError = log
        process.terminationHandler = { [weak self] child in
            try? log.close()
            let result = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isInstalling = false
                if result != 0 { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
                self.status = result == 0 ? "更新已安装，请重新启动 Mac" : "安装未完成或授权已取消，可重新点击更新"
            }
        }
        installer = process
        try process.run()
    }
}
