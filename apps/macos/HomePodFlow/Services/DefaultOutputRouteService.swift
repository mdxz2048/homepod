import Foundation
import CoreAudio

/// Exact DeviceUID the managed virtual capture device publishes. Shared by the
/// worker `start` descriptor and the default-output router so a typo cannot drift.
enum FlowVirtualDevice {
    static let uid = "com.homepodflow.virtual-audio.surround71.v1"
}

/// Store-facing side-effect boundary for the macOS *MEDIA* default output only.
/// Every call is synchronous and deliberately cheap: the fake in silent checks
/// never touches a real device.
@MainActor protocol DefaultOutputControlling: AnyObject {
    /// UID of the current default output device, or nil when unavailable.
    func currentDefaultOutputUID() -> String?
    /// Whether Core Audio currently reports the device as running somewhere
    /// (any client has live IO). nil means the property is unavailable.
    /// Used only to observe the asynchronous effect of a route change; it
    /// never gates the default-output write itself.
    func isDeviceRunning(uid: String) -> Bool?
    /// Sets the default output by UID and verifies with a read-back.
    /// Returns true when the read-back confirms the requested UID became default.
    func setDefaultOutput(uid: String) throws -> Bool
    /// Restores the default output by UID. Returns false when the UID is no
    /// longer present (hotplug) or the write was not confirmed.
    func restoreDefaultOutput(uid: String) -> Bool
}

enum DefaultOutputRouteError: Error, LocalizedError, Equatable {
    case currentOutputUnavailable
    case deviceUIDMissing(String)
    case noOutputCapability(String)
    case setFailed(Int32)
    case readbackUnverified
    case switchNotConfirmed(String)

    var errorDescription: String? {
        switch self {
        case .currentOutputUnavailable: "无法读取当前默认输出，请确认 Mac 已连接可用的输出设备"
        case .deviceUIDMissing(let uid): "默认输出设备不存在：\(uid)"
        case .noOutputCapability(let uid): "目标设备无输出能力：\(uid)"
        case .setFailed(let status): "写入默认输出失败（\(status)）"
        case .readbackUnverified: "默认输出回读校验未通过"
        case .switchNotConfirmed(let uid):
            "Mac 默认输出未在限定时间内切换到 \(uid)，请稍后重试"
        }
    }
}

/// Minimal CoreAudio primitives, so routing decisions can be checked against a
/// fake hardware table instead of a live Mac.
@MainActor protocol AudioHardwareAccessing: AnyObject {
    var defaultOutputDevice: AudioObjectID? { get }
    func setDefaultOutputDevice(_ device: AudioObjectID) throws
    func deviceUIDMap() -> [AudioObjectID: String]
    func outputStreamCount(_ device: AudioObjectID) -> Int?
    func isRunning(_ device: AudioObjectID) -> Bool?
}

/// Production CoreAudio access. UID lookup never reads friendly device names,
/// and only the `kAudioHardwarePropertyDefaultOutputDevice` selector is written,
/// so default input and alert output stay untouched.
@MainActor private final class CoreAudioHardwareAccess: AudioHardwareAccessing {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    var defaultOutputDevice: AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(system, &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw DefaultOutputRouteError.setFailed(status) }
    }

    func deviceUIDMap() -> [AudioObjectID: String] {
        var result: [AudioObjectID: String] = [:]
        for device in allDevices() {
            if let uid = deviceUID(device) { result[device] = uid }
        }
        return result
    }

    func outputStreamCount(_ device: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    func isRunning(_ device: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr ? running != 0 : nil
    }

    private func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? devices : []
    }

    private func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// Routes only the macOS MEDIA default output. Previous state is represented
/// by UID rather than an AudioObjectID so a restore survives re-enumeration.
@MainActor final class DefaultOutputRouteService: DefaultOutputControlling {
    private let flowUID: String
    private let hardware: any AudioHardwareAccessing

    init(flowUID: String = FlowVirtualDevice.uid, hardware: (any AudioHardwareAccessing)? = nil) {
        self.flowUID = flowUID
        self.hardware = hardware ?? CoreAudioHardwareAccess()
    }

    func currentDefaultOutputUID() -> String? {
        guard let device = hardware.defaultOutputDevice else { return nil }
        return hardware.deviceUIDMap()[device]
    }

    func isDeviceRunning(uid: String) -> Bool? {
        guard let device = device(byUID: uid) else { return nil }
        return hardware.isRunning(device)
    }

    func setDefaultOutput(uid: String) throws -> Bool {
        guard let device = device(byUID: uid) else { throw DefaultOutputRouteError.deviceUIDMissing(uid) }
        guard let streams = hardware.outputStreamCount(device), streams > 0 else {
            throw DefaultOutputRouteError.noOutputCapability(uid)
        }
        try hardware.setDefaultOutputDevice(device)
        return hardware.defaultOutputDevice == device
    }

    func restoreDefaultOutput(uid: String) -> Bool {
        guard let device = device(byUID: uid) else { return false }
        do { try hardware.setDefaultOutputDevice(device) } catch { return false }
        return hardware.defaultOutputDevice == device
    }

    private func device(byUID uid: String) -> AudioObjectID? {
        hardware.deviceUIDMap().first(where: { $0.value == uid })?.key
    }
}
