import Foundation
import CoreAudio
import HALInputConstants

/// Public HAL property access only; construction is inert. No IOProc, tap, AU,
/// default-device write, installation, or permission prompt is created here.
@MainActor
public final class HALVirtualDeviceBackend: VirtualDeviceBackend {
    public init() {}
    private let latencySelector: AudioObjectPropertySelector = 0x68666c61 // hfla
    private let revisionSelector: AudioObjectPropertySelector = 0x68666c72 // hflr

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var result = value
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr else { throw InputFailure.hal(operation: "read \(selector) on \(id)", status: status) }
        guard size == MemoryLayout<T>.size else { throw InputFailure.invalidProperty("scalar size") }
        return result
    }
    private func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ zero: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
        guard status == noErr else { throw InputFailure.hal(operation: "size \(selector)", status: status) }
        let stride = MemoryLayout<T>.stride
        guard size <= 65_536, Int(size) % stride == 0 else { throw InputFailure.invalidProperty("array size") }
        if size == 0 { return [] }
        var values = [T](repeating: zero, count: Int(size) / stride)
        let capacity = size
        status = values.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw InputFailure.hal(operation: "read array \(selector)", status: status) }
        guard size <= capacity, Int(size) % stride == 0 else { throw InputFailure.invalidProperty("array changed size") }
        return Array(values.prefix(Int(size) / stride))
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        let holder = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        holder.initialize(to: nil)
        defer { holder.deinitialize(count: 1); holder.deallocate() }
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, holder)
        guard status == noErr else { throw InputFailure.hal(operation: "string \(selector)", status: status) }
        guard size == MemoryLayout<CFString?>.size, let raw = holder.pointee else {
            throw InputFailure.invalidProperty("missing string")
        }
        return raw as String
    }
    /// HAL custom properties are marshalled as CFPropertyList. Reading and
    /// writing raw UInt32/UInt64 into a custom selector is silently invisible
    /// to clients because coreaudiod only forwards CFString/CFPropertyList.
    private func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> NSNumber {
        var a = address(selector)
        var raw: CFTypeRef?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        let status = withUnsafeMutablePointer(to: &raw) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr else { throw InputFailure.hal(operation: "read custom \(selector) on \(id)", status: status) }
        guard size == MemoryLayout<CFTypeRef?>.size, let value = raw as? NSNumber else {
            throw InputFailure.invalidProperty("custom property type")
        }
        return value
    }
    private func deviceID() throws -> AudioObjectID {
        let ids: [UInt32] = try array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, UInt32(0))
        // A disappearing unrelated device must not turn an absent project driver into fake readiness.
        let matches = ids.filter { (try? string($0, kAudioDevicePropertyDeviceUID)) == VirtualIdentity.deviceUID }
        guard matches.count == 1 else {
            if matches.isEmpty { throw InputFailure.driverUnavailable }
            throw InputFailure.invalidProperty("duplicate project UID")
        }
        return matches[0]
    }
    private func validate(_ format: AudioStreamBasicDescription, rate: Double) throws {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags == flags,
              format.mSampleRate == rate, format.mChannelsPerFrame == 2,
              format.mBitsPerChannel == 32, format.mFramesPerPacket == 1,
              format.mBytesPerFrame == 8, format.mBytesPerPacket == 8 else {
            throw InputFailure.unsupportedFormat("driver ASBD differs from stereo Float32 contract")
        }
    }
    public func discover() throws -> DiscoveredVirtualDevice {
        let id = try deviceID()
        guard try string(id, kAudioDevicePropertyModelUID) == VirtualIdentity.modelUID else {
            throw InputFailure.invalidProperty("model UID")
        }
        let alive = try read(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
        guard alive == 1 else { throw InputFailure.driverUnavailable }
        let beforeRevision = try number(id, revisionSelector).uint64Value
        let rate = try read(id, kAudioDevicePropertyNominalSampleRate, Double(0))
        guard rate == 44_100 || rate == 48_000 else { throw InputFailure.unsupportedFormat("sample rate") }
        let outputs: [UInt32] = try array(id, kAudioDevicePropertyStreams, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        let inputs: [UInt32] = try array(id, kAudioDevicePropertyStreams, UInt32(0), scope: kAudioObjectPropertyScopeInput)
        guard outputs.count == 1, inputs.isEmpty else { throw InputFailure.unsupportedFormat("not output-only single stream") }
        let stream = outputs[0]
        guard try read(stream, kAudioStreamPropertyDirection, UInt32(9)) == 0,
              try read(stream, kAudioStreamPropertyStartingChannel, UInt32(0)) == 1,
              try read(stream, kAudioStreamPropertyIsActive, UInt32(0)) == 1 else {
            throw InputFailure.invalidProperty("stream direction/start/active")
        }
        try validate(read(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()), rate: rate)
        try validate(read(stream, kAudioStreamPropertyPhysicalFormat, AudioStreamBasicDescription()), rate: rate)
        let rateRanges = try array(id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange())
        guard rateRanges.count == 2, rateRanges.allSatisfy({ $0.mMinimum == $0.mMaximum }),
              rateRanges.map(\.mMinimum).sorted() == [44_100, 48_000] else {
            throw InputFailure.unsupportedFormat("advertised rate set")
        }
        let physical = try array(stream, kAudioStreamPropertyAvailablePhysicalFormats, AudioStreamRangedDescription())
        let virtual = try array(stream, kAudioStreamPropertyAvailableVirtualFormats, AudioStreamRangedDescription())
        for list in [physical, virtual] {
            guard list.count == 2, list.map({ $0.mSampleRateRange.mMinimum }).sorted() == [44_100, 48_000] else {
                throw InputFailure.unsupportedFormat("advertised stream formats")
            }
            for item in list {
                guard item.mSampleRateRange.mMinimum == item.mSampleRateRange.mMaximum else {
                    throw InputFailure.unsupportedFormat("non-discrete format")
                }
                try validate(item.mFormat, rate: item.mSampleRateRange.mMinimum)
            }
        }
        let stereo = try array(id, kAudioDevicePropertyPreferredChannelsForStereo, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        guard stereo == [1, 2] else { throw InputFailure.unsupportedFormat("stereo channel labels") }
        // Driver's stereo tag has no channel-description payload. Read exact tag/bitmap/count header.
        let layout = try array(id, kAudioDevicePropertyPreferredChannelLayout, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        guard layout.count == 3, layout[0] == kAudioChannelLayoutTag_Stereo, layout[1] == 0, layout[2] == 0 else {
            throw InputFailure.unsupportedFormat("channel layout")
        }
        let frames = try read(stream, kAudioStreamPropertyLatency, UInt32(0))
        let outputFrames = try read(stream, kAudioStreamPropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        let controlValue = try number(id, latencySelector)
        guard controlValue.uint64Value <= UInt32.max else { throw InputFailure.invalidProperty("latency control range") }
        let controlFrames = controlValue.uint32Value
        guard frames == outputFrames, frames == controlFrames, Double(frames) <= 10 * rate else {
            throw InputFailure.invalidProperty("latency scopes/control mismatch")
        }
        let deviceLatency = try read(id, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        let safety = try read(id, kAudioDevicePropertySafetyOffset, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        let buffer = try read(id, kAudioDevicePropertyBufferFrameSize, UInt32(0))
        let period = try read(id, flow_input_zero_timestamp_period_selector(), UInt32(0))
        let range = try read(id, kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange())
        // coreaudiod owns kAudioDevicePropertyBufferFrameSize for HAL devices:
        // on the target Mac it exposes 15...4096 even when the driver answers
        // 512...512, and a client set to 256/1024/4096 is reflected on read.
        // The sink accepts the host-provided IO frame count, so validate the
        // actual value against the host range rather than claiming 512-only.
        guard deviceLatency == 0, safety == 0, buffer >= 16, buffer <= 4_096, period == 16_384,
              range.mMinimum <= Double(buffer), Double(buffer) <= range.mMaximum else {
            throw InputFailure.invalidProperty("clock/budget capability")
        }
        let runningValue = try read(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0))
        guard runningValue <= 1 else { throw InputFailure.invalidProperty("running flag") }
        let afterRevision = try number(id, revisionSelector).uint64Value
        guard beforeRevision > 0, beforeRevision == afterRevision else { throw InputFailure.latencyRevisionChanged }
        guard try string(id, kAudioDevicePropertyDeviceUID) == VirtualIdentity.deviceUID else { throw InputFailure.driverUnavailable }
        let format = try InputFormat(sampleRate: rate, packing: .interleaved, channelCount: 2,
                                     labels: [.FL, .FR], layoutAuthority: "device", layoutVerified: true)
        let latency = LatencyDescriptor(revision: afterRevision, reportedFrames: frames,
                                        sampleRate: rate, calibration: .uncalibrated)
        return DiscoveredVirtualDevice(descriptor: InputDescriptor(deviceUID: VirtualIdentity.deviceUID,
            capturedFormat: format, latency: latency), running: runningValue == 1,
            availableSampleRates: [44_100, 48_000], deviceLatencyFrames: deviceLatency,
            safetyOffsetFrames: safety, bufferFrames: buffer, zeroTimestampPeriod: period)
    }

    public func setLatencyFrames(_ frames: UInt32) throws {
        let id = try deviceID()
        var a = address(latencySelector)
        var settable = DarwinBoolean(false)
        var status = AudioObjectIsPropertySettable(id, &a, &settable)
        guard status == noErr else { throw InputFailure.hal(operation: "latency settable", status: status) }
        guard settable.boolValue else { throw InputFailure.invalidProperty("latency read-only") }
        // The HAL expects a pointer to a CFPropertyListRef, not the object
        // pointer itself. Use an explicit holder so Swift cannot bridge or
        // copy the optional object reference behind our back.
        let holder = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        holder.initialize(to: NSNumber(value: frames))
        defer { holder.deinitialize(count: 1); holder.deallocate() }
        status = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<CFTypeRef?>.size), holder)
        if status == kAudioHardwareIllegalOperationError { throw InputFailure.deviceBusy }
        guard status == noErr else { throw InputFailure.hal(operation: "set latency", status: status) }
    }
}
