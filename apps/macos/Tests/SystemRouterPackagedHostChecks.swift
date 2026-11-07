import Foundation

/// Regression check for bundled capture-host resolution in SystemRouterService:
/// - both embedded helpers present -> prefer them, keep every other config field;
/// - neither helper present -> legacy external host paths remain;
/// - exactly one helper / malformed bundle -> throw instead of stale fallback.
@main struct SystemRouterPackagedHostChecks {
    static func main() {
        do {
            try verifyEmbeddedPreferenceKeepsConfig()
            try verifyLegacyFallbackWhenNoHelpers()
            try verifyPartialBundleFails()
            try verifyMalformedBundleFails()
            print("SystemRouterPackagedHostChecks: bundled / legacy / partial path resolution passed")
        } catch {
            preconditionFailure("SystemRouterPackagedHostChecks failed: \(error)")
        }
    }

    private static func fixtureRuntime() throws -> SystemAudioRuntime {
        let json = """
        {
          "python": "/usr/bin/python3",
          "project": "/Applications/HomePod Flow/runtime",
          "library": "/Applications/HomePod Flow/runtime/libcore.dylib",
          "capture_host": "/external/helpers/TapCaptureHost.app/Contents/MacOS/tap-capture-host",
          "virtual_capture_host": "/external/helpers/VirtualCaptureHost.app/Contents/MacOS/virtual-audio-host",
          "latency_control": "/external/helpers/hflctl",
          "latency_ms": 120
        }
        """
        return try JSONDecoder().decode(SystemAudioRuntime.self, from: Data(json.utf8))
    }

    private static func helpersDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SystemRouterPackagedHostChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeHost(in helpers: URL, appName: String, executableName: String,
                                 bundleIdentifier: String) throws -> URL {
        let app = helpers.appendingPathComponent(appName)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let executable = macos.appendingPathComponent(executableName)
        FileManager.default.createFile(atPath: executable.path,
                                       contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "NSAudioCaptureUsageDescription": "测试用音频采集用途说明",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return executable
    }

    private static func verifyEmbeddedPreferenceKeepsConfig() throws {
        let helpers = try helpersDirectory()
        let tap = try makeHost(in: helpers, appName: "TapCaptureHost.app",
                               executableName: "tap-capture-host",
                               bundleIdentifier: "com.homepodflow.tap-capture-host")
        let virtual = try makeHost(in: helpers, appName: "VirtualCaptureHost.app",
                                   executableName: "virtual-audio-host",
                                   bundleIdentifier: "com.homepodflow.virtual-capture-host")
        var runtime = try fixtureRuntime()
        let usedEmbedded = try runtime.preferEmbeddedCaptureHosts(in: helpers)
        precondition(usedEmbedded == true)
        precondition(runtime.capture_host == tap.path)
        precondition(runtime.virtual_capture_host == virtual.path)
        precondition(runtime.latency_control == "/external/helpers/hflctl")
        precondition(runtime.latency_ms == 120)
        precondition(runtime.python == "/usr/bin/python3")
        precondition(runtime.project == "/Applications/HomePod Flow/runtime")
        precondition(runtime.library == "/Applications/HomePod Flow/runtime/libcore.dylib")
    }

    private static func verifyLegacyFallbackWhenNoHelpers() throws {
        let helpers = try helpersDirectory()
        var runtime = try fixtureRuntime()
        let usedEmbedded = try runtime.preferEmbeddedCaptureHosts(in: helpers)
        precondition(usedEmbedded == false)
        precondition(runtime.capture_host == "/external/helpers/TapCaptureHost.app/Contents/MacOS/tap-capture-host")
        precondition(runtime.virtual_capture_host == "/external/helpers/VirtualCaptureHost.app/Contents/MacOS/virtual-audio-host")
        precondition(runtime.latency_control == "/external/helpers/hflctl")
        precondition(runtime.latency_ms == 120)
    }

    private static func verifyPartialBundleFails() throws {
        let helpers = try helpersDirectory()
        _ = try makeHost(in: helpers, appName: "TapCaptureHost.app",
                         executableName: "tap-capture-host",
                         bundleIdentifier: "com.homepodflow.tap-capture-host")
        var runtime = try fixtureRuntime()
        do {
            _ = try runtime.preferEmbeddedCaptureHosts(in: helpers)
            preconditionFailure("expected partial bundle to throw")
        } catch {
            precondition((error.localizedDescription).contains("不完整"))
        }
        precondition(runtime.capture_host == "/external/helpers/TapCaptureHost.app/Contents/MacOS/tap-capture-host")
        precondition(runtime.virtual_capture_host == "/external/helpers/VirtualCaptureHost.app/Contents/MacOS/virtual-audio-host")
    }

    private static func verifyMalformedBundleFails() throws {
        let helpers = try helpersDirectory()
        let app = try makeHost(in: helpers, appName: "TapCaptureHost.app",
                               executableName: "tap-capture-host",
                               bundleIdentifier: "com.homepodflow.tap-capture-host")
        _ = try makeHost(in: helpers, appName: "VirtualCaptureHost.app",
                         executableName: "virtual-audio-host",
                         bundleIdentifier: "com.homepodflow.virtual-capture-host")
        // Corrupt the tap host identity while keeping its executable present.
        let infoURL = app.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let badInfo: [String: Any] = [
            "CFBundleIdentifier": "com.homepodflow.tap-capture-host",
            "CFBundleExecutable": "other-name",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "NSAudioCaptureUsageDescription": "测试用音频采集用途说明",
        ]
        try PropertyListSerialization.data(fromPropertyList: badInfo, format: .xml, options: 0)
            .write(to: infoURL)
        var runtime = try fixtureRuntime()
        do {
            _ = try runtime.preferEmbeddedCaptureHosts(in: helpers)
            preconditionFailure("expected malformed bundle to throw")
        } catch {
            precondition((error.localizedDescription).contains("可执行文件名不匹配"))
        }
    }
}
