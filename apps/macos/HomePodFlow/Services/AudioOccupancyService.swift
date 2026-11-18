import Foundation
import CoreAudio
import Darwin
#if canImport(AppKit)
import AppKit
#endif

struct AudioProcessUsage: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let displayName: String
    var id: pid_t { pid }
}

/// Finds the processes that are actually rendering output to a specific Core
/// Audio device and can gracefully terminate them before cinema mode writes
/// its presented latency. Only public Core Audio process properties are read.
@MainActor
final class AudioOccupancyService {
    static let shared = AudioOccupancyService()

    private let system = AudioObjectID(kAudioObjectSystemObject)

    func processesUsing(deviceUID: String) -> [AudioProcessUsage] {
        guard let target = deviceID(forUID: deviceUID),
              let processes = objectArray(system, selector: kAudioHardwarePropertyProcessObjectList) else {
            return []
        }
        let ownPID = getpid()
        var seen = Set<pid_t>()
        var result: [AudioProcessUsage] = []
        for process in processes {
            guard let pid = processPID(process), pid > 1, pid != ownPID,
                  seen.insert(pid).inserted,
                  processIsRunningOutput(process),
                  outputDevices(of: process).contains(target) else { continue }
            let bundle = processBundleIdentifier(process)
            guard !isInternal(pid: pid, bundle: bundle) else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? processName(pid)
                ?? bundle
                ?? "PID \(pid)"
            result.append(AudioProcessUsage(pid: pid, bundleIdentifier: bundle, displayName: name))
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// A device can remain "running somewhere" briefly after the last client
    /// quits. Wait for both the client list and the device IO flag to clear.
    func waitUntilIdle(deviceUID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if processesUsing(deviceUID: deviceUID).isEmpty,
               isDeviceRunning(uid: deviceUID) != true {
                return true
            }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Graceful first: NSRunningApplication.terminate() asks the app to quit
    /// and lets it show its own save prompt; helpers fall back to SIGTERM.
    @discardableResult
    func terminate(_ usages: [AudioProcessUsage]) -> [AudioProcessUsage] {
        for usage in usages {
            if let app = NSRunningApplication(processIdentifier: usage.pid) {
                _ = app.terminate()
            } else {
                _ = kill(usage.pid, SIGTERM)
            }
        }
        return usages
    }

    func isDeviceRunning(uid: String) -> Bool? {
        guard let device = deviceID(forUID: uid) else { return nil }
        var address = property(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    // MARK: - Core Audio primitives

    private func deviceID(forUID uid: String) -> AudioObjectID? {
        guard let devices = objectArray(system, selector: kAudioHardwarePropertyDevices) else { return nil }
        return devices.first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    private func processPID(_ process: AudioObjectID) -> pid_t? {
        var address = property(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func processIsRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = property(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func outputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        objectArray(process, selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput) ?? []
    }

    private func processBundleIdentifier(_ process: AudioObjectID) -> String? {
        guard let raw = stringProperty(process, selector: kAudioProcessPropertyBundleID) else { return nil }
        return raw.isEmpty ? nil : raw
    }

    private func isInternal(pid: pid_t, bundle: String?) -> Bool {
        if let bundle {
            if bundle.hasPrefix("com.homepodflow.") { return true }
            if bundle == "com.apple.audio.coreaudiod" { return true }
        }
        let name = processName(pid) ?? ""
        return ["system-worker", "tap-capture-host", "virtual-audio-host", "HomePod Flow"].contains(name)
    }

    private func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_name(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func objectArray(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = property(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? values : nil
    }

    private func stringProperty(_ object: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
