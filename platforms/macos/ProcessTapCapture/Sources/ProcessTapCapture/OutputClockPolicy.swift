import Foundation
import CoreAudio

struct OutputClockDescriptor: Sendable, Equatable {
    let deviceID: AudioObjectID
    let uid: String
    let inputStreamCount: Int
    let outputStreamCount: Int
    let alive: Bool
}

enum OutputClockPolicy {
    static func validate(_ value: OutputClockDescriptor) throws {
        guard value.deviceID != kAudioObjectUnknown, !value.uid.isEmpty, value.uid.count <= 1024,
              value.alive, (1...32).contains(value.outputStreamCount) else {
            throw CaptureError.invalidConfiguration("Default output clock is missing, dead or unsupported")
        }
        guard value.inputStreamCount == 0 else {
            throw CaptureError.invalidConfiguration("Output clock device has hardware input streams; this capture slice refuses implicit hardware input")
        }
    }
    static func validateUnchanged(_ value: OutputClockDescriptor, expected: OutputClockDescriptor) throws {
        try validate(value)
        guard value == expected else { throw CaptureError.invalidConfiguration("Default output clock changed; rebuild capture explicitly") }
    }
}

/// Read-only HAL access; no default-device, volume or mute writes.
enum OutputClockLookup {
    static func current() throws -> OutputClockDescriptor {
        var device: AudioObjectID = kAudioObjectUnknown
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "Read default output clock")
        guard device != kAudioObjectUnknown else { throw CaptureError.invalidConfiguration("No default output clock device") }
        var uid: CFString = "" as CFString
        address = property(kAudioDevicePropertyDeviceUID)
        size = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        try check(uidStatus, "Read output clock UID")
        var alive: UInt32 = 0
        address = property(kAudioDevicePropertyDeviceIsAlive)
        size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive), "Read output clock availability")
        let value = OutputClockDescriptor(deviceID: device, uid: uid as String,
            inputStreamCount: try streamCount(device, scope: kAudioDevicePropertyScopeInput),
            outputStreamCount: try streamCount(device, scope: kAudioDevicePropertyScopeOutput), alive: alive == 1)
        try OutputClockPolicy.validate(value)
        return value
    }
    private static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = property(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Read output clock stream topology")
        guard size % UInt32(MemoryLayout<AudioStreamID>.stride) == 0 else { throw CaptureError.unsupportedFormat }
        return Int(size) / MemoryLayout<AudioStreamID>.stride
    }
    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureError.osStatus(operation, status) }
    }
}
