
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Renders silence into one virtual output device so that its IO keeps running
/// while the capture host taps it. Silence is written, never audible content,
/// and only into the device named on the command line.
private let renderSilence: AURenderCallback = { _, _, _, _, _, ioData in
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
    return noErr
}

private func deviceID(forUID uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var uidRef: CFString = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uidRef) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown else { return nil }
    return device
}

/// Without an explicit UID this targets whatever macOS is currently using as
/// the default output device, which is what music mode taps.
private func defaultOutputDeviceID() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            0, nil, &size, &device)
    guard status == noErr, device != kAudioObjectUnknown else { return nil }
    return device
}

let requested = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let resolved = requested.flatMap(deviceID(forUID:)) ?? defaultOutputDeviceID()
guard let device = resolved else { exit(3) }

var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                     componentSubType: kAudioUnitSubType_HALOutput,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple,
                                                     componentFlags: 0,
                                                     componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &componentDescription) else { exit(4) }
var unit: AudioUnit?
guard AudioComponentInstanceNew(component, &unit) == noErr, let audioUnit = unit else { exit(5) }

var deviceValue = device
var configured = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceValue,
                                      UInt32(MemoryLayout<AudioObjectID>.size)) == noErr
var enableOutput: UInt32 = 1
configured = configured &&
    AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                         &enableOutput, UInt32(MemoryLayout<UInt32>.size)) == noErr
var disableInput: UInt32 = 0
configured = configured &&
    AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                         &disableInput, UInt32(MemoryLayout<UInt32>.size)) == noErr
// The virtual device runs 8ch/48k. Rendering with the HAL default of 2ch/44.1k
// would make the unit reconfigure the device instead of driving it as-is.
var format = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
configured = configured &&
    AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                         &format, &formatSize) == noErr
configured = configured &&
    AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                         &format, formatSize) == noErr
var callback = AURenderCallbackStruct(inputProc: renderSilence, inputProcRefCon: nil)
configured = configured &&
    AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                         &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
configured = configured && AudioUnitInitialize(audioUnit) == noErr
guard configured, AudioOutputUnitStart(audioUnit) == noErr else {
    AudioUnitUninitialize(audioUnit)
    AudioComponentInstanceDispose(audioUnit)
    exit(6)
}

FileHandle.standardOutput.write(Data("ready\n".utf8))

// The owner keeps our stdin open for as long as the capture session lives.
// EOF (owner exit or explicit shutdown) is the single shutdown signal.
var sink: UInt8 = 0
while true {
    let count = read(STDIN_FILENO, &sink, 1)
    if count < 0, errno == EINTR { continue }
    if count <= 0 { break }
}

AudioOutputUnitStop(audioUnit)
AudioUnitUninitialize(audioUnit)
AudioComponentInstanceDispose(audioUnit)
exit(0)
