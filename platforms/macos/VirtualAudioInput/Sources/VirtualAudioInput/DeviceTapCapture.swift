import Foundation
import CoreAudio
import AudioToolbox
import CaptureRing

/// Format of a device-tap capture stream. Channel labels are intentionally not
/// guessed here; the layout contract supplies them separately.
public struct DeviceTapDescriptor: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let streamIndex: UInt32
    public let sampleRate: Double
    public let channels: UInt32
    public let bytesPerFrame: UInt32
    public let formatFlags: UInt32
}

public struct CapturedPCMBlock: Sendable {
    public let frames: Int
    public let channels: Int
    public let samples: [Float]
    public let hostTime: UInt64
    public let sampleTime: Double
    public let timestampFlags: UInt32
    public let callbackSequence: UInt64
    public let droppedBefore: UInt64
    public let nowHostTime: UInt64
    public let nowSampleTime: Double
    public let nowFlags: UInt32
}

/// Non-capturing HAL callback: copies into the preallocated SPSC ring and
/// zeroes the aggregate output. No allocation, lock, log, file or network.
private let deviceTapIOProc: AudioDeviceIOProc = { _, now, input, inputTime, output, _, context in
    guard let context else { return noErr }
    capture_ring_push(OpaquePointer(context), input, inputTime, now)
    _ = capture_zero_output(output)
    return noErr
}

/// Generic output-device tap source. It intentionally supports 2...8 channels
/// and interleaved Float32, so a future 5.1/7.1 virtual device can use the same
/// transport without changing the capture layer. Layout/label policy belongs to
/// the multichannel contract, not this class.
public final class DeviceTapCapture: @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    private var target: DeviceTapDescriptor?
    private var started = false
    private let control = NSLock()

    public init() {}

    public func start(deviceUID: String = VirtualIdentity.deviceUID) throws -> DeviceTapDescriptor {
        control.lock()
        defer { control.unlock() }
        guard !started, tap == kAudioObjectUnknown, aggregate == kAudioObjectUnknown, ring == nil else {
            throw InputFailure.invalidProperty("capture already started")
        }

        let device = try deviceID(forUID: deviceUID)
        let stream = try firstOutputStream(device)
        let format = try readFormat(stream, kAudioStreamPropertyVirtualFormat)
        try validate(format)
        let channels = format.mChannelsPerFrame
        let clockUID = try captureClockUID(excluding: deviceUID)

        let description = CATapDescription(__excludingProcesses: [], andDeviceUID: deviceUID, withStream: 0)
        description.name = "HomePod Flow device tap"
        description.isPrivate = true
        description.isMixdown = false
        description.isMono = false
        description.muteBehavior = CATapMuteBehavior.unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        if createdTap != kAudioObjectUnknown { tap = createdTap }
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            cleanupBestEffort()
            throw InputFailure.hal(operation: "create device tap", status: tapStatus)
        }
        guard let tapUID = stringProperty(tap, kAudioTapPropertyUID) else {
            cleanupBestEffort()
            throw InputFailure.invalidProperty("tap UID")
        }
        let tapFormat = try readFormat(tap, kAudioTapPropertyFormat)
        guard tapFormat.mSampleRate == format.mSampleRate,
              tapFormat.mChannelsPerFrame == channels,
              tapFormat.mBytesPerFrame == format.mBytesPerFrame else {
            cleanupBestEffort()
            throw InputFailure.unsupportedFormat("tap format differs from device stream")
        }

        guard let createdRing = capture_ring_create(16, 4_096, 1, channels, format.mBytesPerFrame) else {
            cleanupBestEffort()
            throw InputFailure.invalidProperty("capture ring allocation")
        }
        ring = createdRing

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HomePod Flow private device tap",
            kAudioAggregateDeviceUIDKey: "com.homepodflow.virtual-capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                               kAudioSubTapDriftCompensationKey: true]]
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary,
                                                                 &createdAggregate)
        if createdAggregate != kAudioObjectUnknown { aggregate = createdAggregate }
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            cleanupBestEffort()
            throw InputFailure.hal(operation: "create capture aggregate", status: aggregateStatus)
        }

        var createdIO: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(aggregate, deviceTapIOProc,
                                                 UnsafeMutableRawPointer(createdRing), &createdIO)
        if let createdIO { io = createdIO }
        guard ioStatus == noErr, io != nil else {
            cleanupBestEffort()
            throw InputFailure.hal(operation: "install capture IOProc", status: ioStatus)
        }
        let startStatus = AudioDeviceStart(aggregate, io)
        guard startStatus == noErr else {
            cleanupBestEffort()
            throw InputFailure.hal(operation: "start capture", status: startStatus)
        }
        started = true
        let descriptor = DeviceTapDescriptor(deviceUID: deviceUID, streamIndex: 0,
                                             sampleRate: format.mSampleRate, channels: channels,
                                             bytesPerFrame: format.mBytesPerFrame, formatFlags: format.mFormatFlags)
        target = descriptor
        return descriptor
    }

    /// Returns nil when no complete block is queued. The caller owns the copied
    /// samples; malformed layouts, ring faults and overflow are fail-closed.
    public func readBlock() throws -> CapturedPCMBlock? {
        control.lock()
        defer { control.unlock() }
        guard let ring, let target else { throw InputFailure.invalidProperty("capture not started") }
        if capture_ring_fault(ring) != 0 { throw InputFailure.invalidProperty("capture ring fault") }
        let channels = Int(target.channels)
        let capacity = 4_096 * channels * MemoryLayout<Float>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<Float>.alignment)
        defer { raw.deallocate() }
        var metadata = CaptureRingMetadata()
        var lengths = [UInt32](repeating: 0, count: 32)
        var bufferChannels = [UInt32](repeating: 0, count: 32)
        let result = lengths.withUnsafeMutableBufferPointer { lengthBuffer in
            bufferChannels.withUnsafeMutableBufferPointer { channelBuffer in
                capture_ring_pop(ring, raw, capacity, &metadata,
                                 lengthBuffer.baseAddress, channelBuffer.baseAddress)
            }
        }
        if result == 0 { return nil }
        guard result > 0, metadata.buffer_count == 1,
              bufferChannels[0] == target.channels,
              Int(metadata.frames) * channels * MemoryLayout<Float>.size == Int(metadata.total_bytes),
              lengths[0] == metadata.total_bytes else {
            throw InputFailure.invalidProperty("captured block layout")
        }
        let pointer = raw.assumingMemoryBound(to: Float.self)
        let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(metadata.frames) * channels))
        return CapturedPCMBlock(frames: Int(metadata.frames), channels: channels, samples: samples,
                                hostTime: metadata.host_time, sampleTime: metadata.sample_time,
                                timestampFlags: metadata.timestamp_flags,
                                callbackSequence: metadata.callback_sequence,
                                droppedBefore: metadata.dropped_before,
                                nowHostTime: metadata.now_host_time,
                                nowSampleTime: metadata.now_sample_time,
                                nowFlags: metadata.now_timestamp_flags)
    }

    public func stop() throws {
        control.lock()
        defer { control.unlock() }
        var firstError: Error?
        if started, aggregate != kAudioObjectUnknown, let io {
            let status = AudioDeviceStop(aggregate, io)
            if status != noErr { firstError = InputFailure.hal(operation: "stop capture", status: status) }
            started = false
        }
        if aggregate != kAudioObjectUnknown, let io {
            let status = AudioDeviceDestroyIOProcID(aggregate, io)
            if status == noErr { self.io = nil }
            else if firstError == nil { firstError = InputFailure.hal(operation: "destroy IOProc", status: status) }
        }
        if aggregate != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status == noErr { aggregate = kAudioObjectUnknown }
            else if firstError == nil { firstError = InputFailure.hal(operation: "destroy aggregate", status: status) }
        }
        if tap != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status == noErr { tap = kAudioObjectUnknown }
            else if firstError == nil { firstError = InputFailure.hal(operation: "destroy tap", status: status) }
        }
        if let ring {
            capture_ring_destroy(ring)
            self.ring = nil
        }
        target = nil
        if let firstError { throw firstError }
    }

    deinit { try? stop() }

    private func cleanupBestEffort() {
        if started, aggregate != kAudioObjectUnknown, let io {
            _ = AudioDeviceStop(aggregate, io)
            started = false
        }
        if aggregate != kAudioObjectUnknown, let io {
            _ = AudioDeviceDestroyIOProcID(aggregate, io)
            self.io = nil
        }
        if aggregate != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
        if let ring {
            capture_ring_destroy(ring)
            self.ring = nil
        }
        target = nil
    }

    private func validate(_ format: AudioStreamBasicDescription) throws {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags == flags,
              format.mChannelsPerFrame >= 2, format.mChannelsPerFrame <= 8,
              (format.mSampleRate == 44_100 || format.mSampleRate == 48_000),
              format.mBitsPerChannel == 32, format.mFramesPerPacket == 1,
              format.mBytesPerFrame == 4 * format.mChannelsPerFrame,
              format.mBytesPerPacket == format.mBytesPerFrame else {
            throw InputFailure.unsupportedFormat("device tap requires interleaved Float32 stereo..8ch at 44.1/48k")
        }
    }

    private func deviceID(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { throw InputFailure.driverUnavailable }
        return device
    }

    private func firstOutputStream(_ device: AudioObjectID) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr, size == UInt32(MemoryLayout<AudioObjectID>.size) else {
            throw InputFailure.invalidProperty("single output stream")
        }
        var stream = AudioObjectID(kAudioObjectUnknown)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &stream)
        guard status == noErr, stream != kAudioObjectUnknown else {
            throw InputFailure.invalidProperty("output stream")
        }
        return stream
    }

    private func readFormat(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &format)
        guard status == noErr, size == MemoryLayout<AudioStreamBasicDescription>.size else {
            throw InputFailure.hal(operation: "read format \(selector)", status: status)
        }
        return format
    }

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        let holder = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        holder.initialize(to: nil)
        defer { holder.deinitialize(count: 1); holder.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, holder)
        return status == noErr ? holder.pointee as String? : nil
    }

    private func captureClockUID(excluding targetUID: String) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        if status == noErr, device != kAudioObjectUnknown,
           let uid = stringProperty(device, kAudioDevicePropertyDeviceUID), uid != targetUID {
            return uid
        }
        // Never use the tapped sink as its own clock. Fall back to the built-in
        // output only when it exists; otherwise fail instead of guessing.
        if let builtIn = try? deviceID(forUID: "BuiltInSpeakerDevice"),
           let uid = stringProperty(builtIn, kAudioDevicePropertyDeviceUID), uid != targetUID {
            return uid
        }
        throw InputFailure.invalidProperty("no independent capture clock")
    }
}
