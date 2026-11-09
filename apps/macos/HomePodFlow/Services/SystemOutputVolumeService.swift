import Foundation
import CoreAudio

/// Store-facing control surface for the Flow virtual device's hardware volume.
/// The driver intentionally does not attenuate captured audio; the app maps
/// these values to the AirPlay group so macOS volume keys have one authority.
@MainActor protocol SystemOutputVolumeControlling: AnyObject {
    @discardableResult func startObserving(_ handler: @escaping @MainActor () -> Void) -> Bool
    func stopObserving()
    func readState() -> (volume: Float, muted: Bool)?
    @discardableResult func setVolume(_ value: Float) -> Bool
    @discardableResult func setMuted(_ muted: Bool) -> Bool
}

/// Reads and writes the master output volume on the Flow HAL device.
///
/// macOS only hands the volume keys, Control Center and the mute key to a
/// device that publishes real Core Audio *control* objects: a device-level
/// `kAudioDevicePropertyVolumeScalar` alone is not enough for the media keys.
/// The driver therefore exposes a level control and a mute control per device;
/// this service resolves those controls (falling back to the device-level
/// properties for older driver builds) and mirrors their value into the app.
/// The device is resolved by UID so hotplug/re-enumeration does not leave a
/// stale AudioObjectID behind.
@MainActor final class SystemOutputVolumeService: SystemOutputVolumeControlling {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct Target {
        let volumeObject: AudioObjectID
        let muteObject: AudioObjectID
        let volumeAddress: AudioObjectPropertyAddress
        let muteAddress: AudioObjectPropertyAddress
    }

    private let uid: String
    private let queue = DispatchQueue(label: "HomePodFlow.SystemOutputVolume.events")
    private var listeners: [Listener] = []
    private var target: Target?

    init(uid: String = FlowVirtualDevice.uid) { self.uid = uid }

    func startObserving(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard listeners.isEmpty else { return true }
        guard let target = resolveTarget() else { return false }
        var added: [Listener] = []
        for entry in [(target.volumeObject, target.volumeAddress),
                      (target.muteObject, target.muteAddress)] {
            var address = entry.1
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in handler() }
            }
            guard AudioObjectAddPropertyListenerBlock(entry.0, &address, queue, block) == noErr
            else {
                for listener in added {
                    var address = listener.address
                    _ = AudioObjectRemovePropertyListenerBlock(
                        listener.object, &address, queue, listener.block)
                }
                return false
            }
            added.append(Listener(object: entry.0, address: address, block: block))
        }
        self.target = target
        listeners = added
        return true
    }

    func stopObserving() {
        for listener in listeners {
            var address = listener.address
            _ = AudioObjectRemovePropertyListenerBlock(
                listener.object, &address, queue, listener.block)
        }
        listeners.removeAll()
        target = nil
    }

    func readState() -> (volume: Float, muted: Bool)? {
        guard let target = resolveTarget(),
              let volume = readFloat(target.volumeObject, target.volumeAddress) else { return nil }
        let muted = readUInt32(target.muteObject, target.muteAddress).map { $0 != 0 } ?? false
        return (min(1, max(0, volume)), muted)
    }

    func setVolume(_ value: Float) -> Bool {
        guard value.isFinite, let target = resolveTarget() else { return false }
        var volume = min(1, max(0, value))
        var address = target.volumeAddress
        let status = AudioObjectSetPropertyData(target.volumeObject, &address, 0, nil,
                                                UInt32(MemoryLayout<Float>.size), &volume)
        return status == noErr && readFloat(target.volumeObject, target.volumeAddress)
            .map { abs($0 - volume) < 0.0001 } == true
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard let target = resolveTarget() else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = target.muteAddress
        let status = AudioObjectSetPropertyData(target.muteObject, &address, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    /// Resolves the control objects, falling back to device-level properties
    /// when the installed driver predates the control surface.
    private func resolveTarget() -> Target? {
        guard let device = deviceID() else { return nil }
        var volumeControl: AudioObjectID?
        var muteControl: AudioObjectID?
        for control in controls(on: device) {
            switch classID(of: control) {
            case kAudioVolumeControlClassID: volumeControl = control
            case kAudioMuteControlClassID: muteControl = control
            default: break
            }
        }
        if let volumeControl, let muteControl {
            return Target(
                volumeObject: volumeControl,
                muteObject: muteControl,
                volumeAddress: .init(mSelector: kAudioLevelControlPropertyScalarValue,
                                     mScope: kAudioObjectPropertyScopeGlobal,
                                     mElement: kAudioObjectPropertyElementMain),
                muteAddress: .init(mSelector: kAudioBooleanControlPropertyValue,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain))
        }
        return Target(
            volumeObject: device,
            muteObject: device,
            volumeAddress: .init(mSelector: kAudioDevicePropertyVolumeScalar,
                                 mScope: kAudioObjectPropertyScopeOutput,
                                 mElement: kAudioObjectPropertyElementMain),
            muteAddress: .init(mSelector: kAudioDevicePropertyMute,
                               mScope: kAudioObjectPropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain))
    }

    private func controls(on device: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard ids.withUnsafeMutableBufferPointer({ buffer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer.baseAddress!)
        }) == noErr else { return [] }
        return ids
    }

    private func classID(of object: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private func readFloat(_ object: AudioObjectID,
                           _ address: AudioObjectPropertyAddress) -> Float? {
        var value: Float = 0
        var address = address
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readUInt32(_ object: AudioObjectID,
                            _ address: AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var address = address
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func deviceID() -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard devices.withUnsafeMutableBufferPointer({ buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }) == noErr else { return nil }
        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var raw: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &raw) { pointer in
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
            }
            if status == noErr, let value = raw?.takeRetainedValue(), (value as String) == uid {
                return device
            }
        }
        return nil
    }
}

/// Hermetic checks and Demo stores never touch a real output device.
@MainActor final class SilentSystemOutputVolumeController: SystemOutputVolumeControlling {
    func startObserving(_ handler: @escaping @MainActor () -> Void) -> Bool { true }
    func stopObserving() {}
    func readState() -> (volume: Float, muted: Bool)? { nil }
    func setVolume(_ value: Float) -> Bool { true }
    func setMuted(_ muted: Bool) -> Bool { true }
}
