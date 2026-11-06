// Read-only device/stream latency snapshot. Creates an output AudioUnit for
// property queries, never starts it, changes system output, or captures audio.
import Foundation
import CoreAudio
import AudioToolbox

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope, _ initial: T) -> (T, OSStatus) {
    var value = initial, property = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
    }
    return (value, status)
}
func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
    var property = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr else { return [] }
    guard size > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = values.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? values : []
}
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    let (value, status): (CFString?, OSStatus) = scalar(id, selector, kAudioObjectPropertyScopeGlobal, nil)
    return status == noErr ? (value.map { $0 as String } ?? "") : ""
}
let global = kAudioObjectPropertyScopeGlobal, output = kAudioObjectPropertyScopeOutput
let (defaultID, defaultStatus) = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, global, AudioObjectID(0))
var results: [[String: Any]] = []
for device in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, global) {
    let streams = ids(device, kAudioDevicePropertyStreams, output)
    guard !streams.isEmpty else { continue }
    let (rate, rateStatus) = scalar(device, kAudioDevicePropertyNominalSampleRate, global, Float64(0))
    let (latency, latencyStatus) = scalar(device, kAudioDevicePropertyLatency, output, UInt32(0))
    let (safety, safetyStatus) = scalar(device, kAudioDevicePropertySafetyOffset, output, UInt32(0))
    let (buffer, bufferStatus) = scalar(device, kAudioDevicePropertyBufferFrameSize, global, UInt32(0))
    var row: [String: Any] = ["id": device, "name": string(device, kAudioObjectPropertyName),
        "uid": string(device, kAudioDevicePropertyDeviceUID), "default_output": defaultStatus == noErr && defaultID == device,
        "sample_rate": rate, "rate_status": rateStatus, "device_latency_frames": latency,
        "device_latency_status": latencyStatus, "safety_offset_frames": safety, "safety_status": safetyStatus,
        "buffer_frames": buffer, "buffer_status": bufferStatus]
    var streamRows: [[String: Any]] = []
    for stream in streams {
        let (frames, status) = scalar(stream, kAudioStreamPropertyLatency, output, UInt32(0))
        let (globalFrames, globalStatus) = scalar(stream, kAudioStreamPropertyLatency, global, UInt32(0))
        streamRows.append(["id": stream, "latency_frames_output_scope": frames, "output_scope_status": status,
                           "latency_frames_global_scope": globalFrames, "global_scope_status": globalStatus])
    }
    row["streams"] = streamRows
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    if let component = AudioComponentFindNext(nil, &description) {
        var unit: AudioUnit?
        let create = AudioComponentInstanceNew(component, &unit)
        row["audio_unit_create_status"] = create
        if let unit {
            defer { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
            var target = device
            let bind = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &target, UInt32(MemoryLayout.size(ofValue: target)))
            let initialize = bind == noErr ? AudioUnitInitialize(unit) : bind
            var seconds: Float64 = 0, size = UInt32(MemoryLayout<Float64>.size)
            let query = initialize == noErr ? AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                kAudioUnitScope_Global, 0, &seconds, &size) : initialize
            row["audio_unit_bind_status"] = bind; row["audio_unit_initialize_status"] = initialize
            row["audio_unit_latency_status"] = query
            if query == noErr { row["audio_unit_latency_ms"] = seconds * 1000 }
            if rateStatus == noErr && rate > 0 {
                if latencyStatus == noErr { row["device_latency_ms"] = Double(latency) * 1000 / rate }
                if safetyStatus == noErr { row["safety_offset_ms"] = Double(safety) * 1000 / rate }
                if bufferStatus == noErr { row["buffer_ms"] = Double(buffer) * 1000 / rate }
                if query == noErr && latencyStatus == noErr,
                   let first = streamRows.first, first["output_scope_status"] as? OSStatus == noErr,
                   let streamFrames = first["latency_frames_output_scope"] as? UInt32 {
                    row["chromium_style_static_latency_ms"] = seconds * 1000 + (Double(latency) + Double(streamFrames)) * 1000 / rate
                }
            }
        }
    }
    results.append(row)
}
let document: [String: Any] = ["timestamp_utc": ISO8601DateFormatter().string(from: Date()),
    "devices": results, "audio_started": false, "default_output_changed": false,
    "acoustic_measured": false,
    "note": "System-reported components. Static sum follows current Chromium source; excludes callback hostTime lead and browser queues. Not a measurement of browser A/V offset or acoustic end-to-end delay."]
let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
