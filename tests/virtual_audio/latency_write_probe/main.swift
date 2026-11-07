// latency_write_probe — zero-mutation HAL write guard discriminator.
//
// Purpose: determine whether a kAudioHardwareIllegalOperationError on the
// 'hfla' custom property of the exact surround71.v1 device is caused by
//   (a) a transient running client (verified busy),
//   (b) a pending sample-rate configuration change inside the driver
//       (state.ratePending, which is not exposed by any HAL property), or
//   (c) server-side rejection before the driver.
//
// Safety: it only ever writes the CURRENTLY READ hfla value (an effective
// no-op). When idle and not pending this returns noErr and does not bump
// hflr. When the driver guard rejects it, nothing is modified either because
// the guard runs before the mutation. The probe never changes hfla, the
// sample rate, the default device, or any other device.

import CoreAudio
import Foundation

let targetUID = "com.homepodflow.virtual-audio.surround71.v1"
let selHfla: AudioObjectPropertySelector = 0x68666C61      // 'hfla'
let selHflr: AudioObjectPropertySelector = 0x68666C72      // 'hflr'

func fourCC(_ value: OSStatus) -> String {
    var v = UInt32(bitPattern: value)
    let bytes: [UInt8] = [
        UInt8(v & 0xFF),
        UInt8((v >> 8) & 0xFF),
        UInt8((v >> 16) & 0xFF),
        UInt8((v >> 24) & 0xFF),
    ]
    return String(decoding: bytes, as: UTF8.self)
}

func statusName(_ s: OSStatus) -> String {
    let all = "\(fourCC(s))/\(s)"
    switch s {
    case noErr: return "noErr(0)"
    case kAudioHardwareBadObjectError: return "\(all)=kAudioHardwareBadObjectError"
    case kAudioHardwareBadPropertySizeError: return "\(all)=kAudioHardwareBadPropertySizeError"
    case kAudioHardwareIllegalOperationError: return "\(all)=kAudioHardwareIllegalOperationError"
    case kAudioHardwareUnknownPropertyError: return "\(all)=kAudioHardwareUnknownPropertyError"
    default: return all
    }
}

func globalAddress(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: sel,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func readUInt32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
    var address = address
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    guard size == MemoryLayout<UInt32>.size else { throw NSError(domain: "hflctl", code: -2) }
    return value
}

func readFloat64(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Float64 {
    var address = address
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    guard size == MemoryLayout<Float64>.size else { throw NSError(domain: "hflctl", code: -2) }
    return value
}

func readDevices() throws -> [AudioObjectID] {
    var address = globalAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
        throw NSError(domain: "hflctl", code: -3)
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = ids.withUnsafeMutableBufferPointer {
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    return ids
}

func readString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> String {
    var address = globalAddress(sel)
    var size = UInt32(MemoryLayout<CFString?>.size)
    let holder = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
    holder.initialize(to: nil)
    defer { holder.deinitialize(count: 1); holder.deallocate() }
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, holder)
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    guard size == MemoryLayout<CFString?>.size, let raw = holder.pointee else {
        throw NSError(domain: "hflctl", code: -4)
    }
    return raw as String
}

func findDevice() throws -> AudioObjectID {
    for id in try readDevices() {
        if (try? readString(id, kAudioDevicePropertyDeviceUID)) == targetUID {
            return id
        }
    }
    throw NSError(domain: "hflctl", code: -5)
}

func readNumber(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> Int64 {
    var address = globalAddress(sel)
    var raw: CFTypeRef?
    var size = UInt32(MemoryLayout<CFTypeRef?>.size)
    let status = withUnsafeMutablePointer(to: &raw) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { throw NSError(domain: "hflctl", code: Int(status)) }
    guard size == MemoryLayout<CFTypeRef?>.size, let value = raw as? NSNumber else {
        throw NSError(domain: "hflctl", code: -6)
    }
    return value.int64Value
}

func setNoop(_ id: AudioObjectID, frames: Int64) -> (OSStatus, Bool) {
    var address = globalAddress(selHfla)
    var settable = DarwinBoolean(false)
    let settableStatus = AudioObjectIsPropertySettable(id, &address, &settable)
    guard settableStatus == noErr else { return (settableStatus, false) }
    guard settable.boolValue else { return (noErr, false) }

    let number = NSNumber(value: frames)
    let holder = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
    holder.initialize(to: number)
    defer { holder.deinitialize(count: 1); holder.deallocate() }
    let status = AudioObjectSetPropertyData(
        id, &address, 0, nil, UInt32(MemoryLayout<CFTypeRef?>.size), holder)
    return (status, true)
}

func snap(_ id: AudioObjectID) throws -> [String: Int64] {
    let device = try readUInt32(id, globalAddress(kAudioDevicePropertyDeviceIsRunning))
    let somewhere = try readUInt32(
        id, globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere))
    let hfla = try readNumber(id, selHfla)
    let hflr = try readNumber(id, selHflr)
    let rate = try readFloat64(id, globalAddress(kAudioDevicePropertyNominalSampleRate))
    return ["running": Int64(device),
            "running_somewhere": Int64(somewhere),
            "hfla": hfla,
            "hflr": hflr,
            "rate": Int64(rate)]
}

let id: AudioObjectID
do { id = try findDevice() } catch {
    print("{\"ok\":false,\"error\":\"find_device_failed \(error)\"}")
    exit(1)
}

let initial: [String: Int64]
do { initial = try snap(id) } catch {
    print("{\"ok\":false,\"error\":\"initial_snapshot_failed \(error)\"}")
    exit(1)
}
var rows: [[String: Any]] = []

for i in 0..<3 {
    let pre: [String: Int64]
    do { pre = try snap(id) } catch {
        print("{\"ok\":false,\"error\":\"pre_snapshot_failed attempt=\(i) \(error)\"}")
        exit(1)
    }
    let cur = pre["hfla"] ?? 0
    let revBefore = pre["hflr"] ?? -1
    let (status, setTried) = setNoop(id, frames: cur)
    let post: [String: Int64]
    do { post = try snap(id) } catch {
        print("{\"ok\":false,\"error\":\"post_snapshot_failed attempt=\(i) \(error)\"}")
        exit(1)
    }
    rows.append([
        "attempt": i,
        "pre": pre,
        "set_tried": setTried,
        "set_status": statusName(status),
        "set_status_code": Int(status),
        "post": post,
        "hfla_unchanged": post["hfla"] == cur,
        "hflr_unchanged": post["hflr"] == revBefore,
    ])
}

let output: [String: Any] = [
    "ok": true,
    "uid": targetUID,
    "device_id": Int(id),
    "note": "set writes the currently read hfla value only (effective no-op); never changes state",
    "initial": initial,
    "attempts": rows,
]
let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
