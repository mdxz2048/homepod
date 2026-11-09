import Foundation
import CoreAudio
import Observation
#if canImport(AppKit)
import AppKit
#endif

protocol AudioComponentInspecting: Sendable {
    func inspect(installerAvailable: Bool) -> AudioComponentSnapshot
}

struct LiveAudioComponentInspector: AudioComponentInspecting {
    static let halDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)

    func inspect(installerAvailable: Bool) -> AudioComponentSnapshot {
        let bundles = Self.flowBundles()
        let present = Self.devicePresent(uid: FlowVirtualDevice.uid)
        return AudioComponentEvaluator.evaluate(bundles: bundles,
                                                devicePresent: present,
                                                deviceUID: FlowVirtualDevice.uid,
                                                installerAvailable: installerAvailable)
    }

    private static func flowBundles() -> [AudioComponentBundle] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: halDirectory,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "driver" else { return nil }
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  identifier == AudioComponentEvaluator.expectedBundleIdentifier else { return nil }
            let executable = plist["CFBundleExecutable"] as? String ?? ""
            let version = plist["CFBundleShortVersionString"] as? String
            let executableURL = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
            let valid = executable == AudioComponentEvaluator.expectedExecutable
                && manager.isExecutableFile(atPath: executableURL.path)
            return AudioComponentBundle(path: url.path,
                                        version: version,
                                        executable: executable,
                                        bundleIdentifier: identifier,
                                        isValid: valid)
        }
    }

    private static func devicePresent(uid: String) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let readStatus = devices.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard readStatus == noErr else { return false }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &valueSize, pointer)
            }
            if status == noErr, let raw = value?.takeRetainedValue(), (raw as String) == uid { return true }
        }
        return false
    }
}

/// Store-facing component status and installer entry point. It never performs a
/// privileged write itself: the signed installer package owns the HAL file
/// replacement, backup, and coreaudiod reload.
@Observable @MainActor final class AudioComponentService {
    private(set) var snapshot: AudioComponentSnapshot
    private(set) var lastActionMessage = ""

    @ObservationIgnored private let inspector: any AudioComponentInspecting
    @ObservationIgnored private let installerURL: URL?

    init(inspector: any AudioComponentInspecting = LiveAudioComponentInspector(),
         installerURL: URL? = AudioComponentService.locateInstaller()) {
        self.inspector = inspector
        self.installerURL = installerURL
        self.snapshot = .checking(deviceUID: FlowVirtualDevice.uid)
    }

    var isReady: Bool { snapshot.state == .ready }
    var allowsStart: Bool { snapshot.state == .ready }
    var installerName: String? { installerURL?.lastPathComponent }
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func refresh() {
        snapshot = inspector.inspect(installerAvailable: installerURL != nil)
    }

    @discardableResult
    func install() -> Bool {
        guard let installerURL else {
            lastActionMessage = "未找到安装包。请重新打开 HomePod Flow 安装镜像，运行 “Install HomePod Flow.pkg”。"
            return false
        }
        lastActionMessage = ""
        #if canImport(AppKit)
        return NSWorkspace.shared.open(installerURL)
        #else
        return false
        #endif
    }

    func openSoundSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func openInstallLog() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/homepodflow-install.log"))
        #endif
    }

    nonisolated static func locateInstaller() -> URL? {
        let manager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["HOMEPODFLOW_INSTALLER_PKG"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if manager.fileExists(atPath: url.path) { return url }
        }
        if let url = Bundle.main.url(forResource: "Install HomePod Flow", withExtension: "pkg") {
            return url
        }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Install HomePod Flow.pkg")
        if manager.fileExists(atPath: sibling.path) { return sibling }

        func installer(in directory: URL) -> URL? {
            let direct = directory.appendingPathComponent("Install HomePod Flow.pkg")
            if manager.fileExists(atPath: direct.path) { return direct }
            guard let items = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return nil }
            let candidates = items
                .filter { $0.lastPathComponent.hasPrefix("HomePodFlow-") }
                .map { $0.appendingPathComponent("Install HomePod Flow.pkg") }
                .filter { manager.fileExists(atPath: $0.path) }
            return candidates.max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }
        }

        var directories: [URL] = [
            URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]
        for searchPath in [FileManager.SearchPathDirectory.downloadsDirectory,
                           .desktopDirectory, .applicationDirectory] {
            if let url = manager.urls(for: searchPath, in: .userDomainMask).first {
                directories.append(url)
            }
        }
        for directory in directories {
            if let found = installer(in: directory) { return found }
        }
        return nil
    }
}
