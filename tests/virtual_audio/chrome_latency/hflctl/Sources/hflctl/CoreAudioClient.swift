import CoreAudio
import Foundation
import HFLatencyControlCore
import HFLatencyControlSupport

/// The only identity this tool is allowed to touch. There is deliberately no
/// `--uid` override: a latency write must never be redirected to another
/// device, the system default, or an unrelated HAL plug-in.
enum TargetIdentity {
    static let deviceUID = "com.homepodflow.virtual-audio.surround71.v1"
    static let modelUID = "com.homepodflow.virtual-audio.model.surround71.v1"
    static let expectedChannels: UInt32 = 8
}

enum HFLControlError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case duplicateDeviceUID(String, [AudioObjectID])
    case halRead(String, Int32)
    case halWrite(String, Int32)
    case sizeMismatch(String, UInt32, Int)
    case customPropertyType(String)
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case deviceBusy
    case rateChanged(previous: Double, current: Double)
    case commitTimeout(observedFrames: UInt32, requestedFrames: UInt32)
    case writeRejected(String)
    case contractViolation(String)
    case notSettable
    case invalidRequest(String)

    var description: String {
        switch self {
        case .deviceNotFound(let uid): return "device_not_found: \(uid)"
        case .duplicateDeviceUID(let uid, let ids):
            return "duplicate_device_uid: \(uid) matches \(ids)"
        case .halRead(let op, let status):
            return "hal_error: \(op) (status \(status) / 0x\(String(status, radix: 16)))"
        case .halWrite(let op, let status):
            return "hal_error: \(op) (status \(status) / 0x\(String(status, radix: 16)))"
        case .sizeMismatch(let op, let size, let expected):
            return "size_mismatch: \(op) returned \(size) bytes, expected \(expected)"
        case .customPropertyType(let op):
            return "custom_property_type: \(op) did not decode as CFNumber"
        case .revisionMismatch(let expected, let actual):
            return "revision_mismatch: expected hflr \(expected), actual \(actual)"
        case .deviceBusy:
            return "device_busy: a client holds IO or a configuration change is pending"
        case .rateChanged(let previous, let current):
            return "rate_changed: device nominal rate moved from \(previous) to \(current) during the write"
        case .commitTimeout(let observedFrames, let requestedFrames):
            return "commit_timeout: hfla reads \(observedFrames) frames after the bounded wait for \(requestedFrames)"
        case .writeRejected(let status):
            return "write_rejected: host reported \(status) for the configuration transaction"
        case .contractViolation(let detail):
            return "contract_violation: \(detail)"
        case .notSettable:
            return "not_settable: hfla reported read-only"
        case .invalidRequest(let detail):
            return "invalid_request: \(detail)"
        }
    }
}

/// Readonly driver transaction status carried by the `hfls` CFNumber.
enum LatencyPendingStatus: Int32 {
    case idle = 0
    case pending = 1
    case busy = 2
    case rejected = 3

    var label: String {
        switch self {
        case .idle: return "idle"
        case .pending: return "pending"
        case .busy: return "busy"
        case .rejected: return "rejected"
        }
    }
}

/// Snapshot of exactly those properties needed for status and guarded writes.
struct DeviceSnapshot {
    var id: AudioObjectID
    var uid: String
    var modelUID: String
    var isAlive: UInt32
    var isRunning: UInt32
    var isRunningSomewhere: UInt32
    var nominalRate: Double
    var availableRates: [Double]
    var bufferFrames: UInt32
    var bufferRangeMin: Double
    var bufferRangeMax: Double
    var deviceLatencyOutput: UInt32
    var deviceLatencyInput: UInt32
    var safetyOutput: UInt32
    var safetyInput: UInt32
    var zeroTimestampPeriod: UInt32
    var outputStreams: [AudioObjectID]
    var inputStreams: [AudioObjectID]
    var channels: UInt32
    var hflaFrames: UInt32
    var hflr: UInt64
    var pendingStatus: LatencyPendingStatus?
    var latencyGlobal: UInt32
    var latencyOutput: UInt32

    var running: Bool { isRunning == 1 || isRunningSomewhere == 1 }
    var latencyScopesMatch: Bool { latencyGlobal == latencyOutput }
}

enum ApplyResult {
    case noop(before: DeviceSnapshot, after: DeviceSnapshot)
    case applied(before: DeviceSnapshot, after: DeviceSnapshot, requestedFrames: UInt32)
    case rolledBack(before: DeviceSnapshot, observed: DeviceSnapshot, requestedFrames: UInt32, failure: String, restored: DeviceSnapshot)
    case rollbackFailed(before: DeviceSnapshot, observed: DeviceSnapshot, requestedFrames: UInt32, failure: String)
}

final class CoreAudioClient {
    private let latencySelector: AudioObjectPropertySelector = 0x68666C61 // 'hfla'
    private let revisionSelector: AudioObjectPropertySelector = 0x68666C72 // 'hflr'
    private let statusSelector: AudioObjectPropertySelector = 0x68666C73 // 'hfls'

    /// Bounded wait for the host to commit a device configuration transaction.
    /// The commit is asynchronous from the caller's point of view: the driver
    /// publishes the new value only from its PerformDeviceConfigurationChange
    /// callback, so an instant readback is not meaningful.
    static let commitTimeout: TimeInterval = 2.0
    static let pollInterval: TimeInterval = 0.02

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func readScalar<T>(_ id: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               _ zero: T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var result = zero
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw HFLControlError.halRead("read \(selector) scope \(scope) on \(id)", status)
        }
        guard size == MemoryLayout<T>.size else {
            throw HFLControlError.sizeMismatch("read \(selector)", size, MemoryLayout<T>.size)
        }
        return result
    }

    private func readArray<T>(_ id: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              _ zero: T,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
        guard status == noErr else {
            throw HFLControlError.halRead("size \(selector) on \(id)", status)
        }
        let stride = MemoryLayout<T>.stride
        guard size <= 65_536, Int(size) % stride == 0 else {
            throw HFLControlError.contractViolation("unexpected array size for \(selector): \(size)")
        }
        if size == 0 { return [] }
        var values = [T](repeating: zero, count: Int(size) / stride)
        let capacity = size
        status = values.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else {
            throw HFLControlError.halRead("read array \(selector) on \(id)", status)
        }
        guard size <= capacity, Int(size) % stride == 0 else {
            throw HFLControlError.sizeMismatch("array \(selector)", size, Int(capacity))
        }
        return Array(values.prefix(Int(size) / stride))
    }

    private func readString(_ id: AudioObjectID,
                            _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        let holder = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        holder.initialize(to: nil)
        defer { holder.deinitialize(count: 1); holder.deallocate() }
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, holder)
        guard status == noErr else {
            throw HFLControlError.halRead("string \(selector) on \(id)", status)
        }
        guard size == MemoryLayout<CFString?>.size, let raw = holder.pointee else {
            throw HFLControlError.contractViolation("missing CFString for \(selector)")
        }
        return raw as String
    }

    /// Custom latency properties are CFPropertyList/CFNumber. The HAL puts the
    /// CF object pointer itself into the data buffer; a raw UInt32 read from a
    /// custom selector is silently invisible to clients.
    private func readNumber(_ id: AudioObjectID,
                            _ selector: AudioObjectPropertySelector) throws -> NSNumber {
        var a = address(selector)
        var raw: CFTypeRef?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        let status = withUnsafeMutablePointer(to: &raw) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw HFLControlError.halRead("custom \(selector) on \(id)", status)
        }
        guard size == MemoryLayout<CFTypeRef?>.size, let value = raw as? NSNumber else {
            throw HFLControlError.customPropertyType("custom \(selector) on \(id)")
        }
        return value
    }

    private func writeNumber(_ id: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             value: UInt32) throws {
        var a = address(selector)
        var settable = DarwinBoolean(false)
        var status = AudioObjectIsPropertySettable(id, &a, &settable)
        guard status == noErr else {
            throw HFLControlError.halWrite("settability \(selector)", status)
        }
        guard settable.boolValue else { throw HFLControlError.notSettable }

        let holder = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        holder.initialize(to: NSNumber(value: value))
        defer { holder.deinitialize(count: 1); holder.deallocate() }
        status = AudioObjectSetPropertyData(id, &a, 0, nil,
                                            UInt32(MemoryLayout<CFTypeRef?>.size), holder)
        if status == kAudioHardwareIllegalOperationError {
            throw HFLControlError.deviceBusy
        }
        guard status == noErr else {
            throw HFLControlError.halWrite("set \(selector) on \(id)", status)
        }
    }

    func findDevice() throws -> AudioObjectID {
        let uid = TargetIdentity.deviceUID
        let devices: [AudioObjectID] = try readArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices,
            AudioObjectID(0))
        var matches: [AudioObjectID] = []
        for id in devices {
            if (try? readString(id, kAudioDevicePropertyDeviceUID)) == uid {
                matches.append(id)
            }
        }
        guard !matches.isEmpty else { throw HFLControlError.deviceNotFound(uid) }
        guard matches.count == 1 else { throw HFLControlError.duplicateDeviceUID(uid, matches) }
        return matches[0]
    }

    func snapshot(of id: AudioObjectID) throws -> DeviceSnapshot {
        let uid = try readString(id, kAudioDevicePropertyDeviceUID)
        let modelUID = try readString(id, kAudioDevicePropertyModelUID)
        let nominalRate = try readScalar(id, kAudioDevicePropertyNominalSampleRate, Double(0))
        try LatencyMath.validateRate(nominalRate)

        let rateRanges: [AudioValueRange] = try readArray(
            id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange())
        let rates = rateRanges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum)
        guard rates.count == 2, Set(rates).isSubset(of: LatencyMath.allowedSampleRates) else {
            throw HFLControlError.contractViolation("advertised rate set \(rates)")
        }

        let outputs: [AudioObjectID] = try readArray(
            id, kAudioDevicePropertyStreams, AudioObjectID(0), scope: kAudioObjectPropertyScopeOutput)
        let inputs: [AudioObjectID] = try readArray(
            id, kAudioDevicePropertyStreams, AudioObjectID(0), scope: kAudioObjectPropertyScopeInput)
        guard outputs.count == 1, inputs.isEmpty else {
            throw HFLControlError.contractViolation("not an output-only single-stream device")
        }
        let stream = outputs[0]
        let format: AudioStreamBasicDescription = try readScalar(
            stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())

        let bufferRange: AudioValueRange = try readScalar(
            id, kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange())
        let zeroSelector = hfl_zero_timestamp_period_selector()

        let latencyGlobal = try readScalar(stream, kAudioStreamPropertyLatency, UInt32(0))
        let latencyOutput = try readScalar(stream, kAudioStreamPropertyLatency, UInt32(0),
                                           scope: kAudioObjectPropertyScopeOutput)
        let controlValue = try readNumber(id, latencySelector)
        let controlFrames = controlValue.uint32Value
        let revision = try readNumber(id, revisionSelector).uint64Value
        let statusValue = (try? readNumber(id, statusSelector))?.int32Value

        return DeviceSnapshot(
            id: id,
            uid: uid,
            modelUID: modelUID,
            isAlive: try readScalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)),
            isRunning: try readScalar(id, kAudioDevicePropertyDeviceIsRunning, UInt32(0)),
            isRunningSomewhere: try readScalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)),
            nominalRate: nominalRate,
            availableRates: rates.sorted(),
            bufferFrames: try readScalar(id, kAudioDevicePropertyBufferFrameSize, UInt32(0)),
            bufferRangeMin: bufferRange.mMinimum,
            bufferRangeMax: bufferRange.mMaximum,
            deviceLatencyOutput: try readScalar(id, kAudioDevicePropertyLatency, UInt32(0),
                                                scope: kAudioObjectPropertyScopeOutput),
            deviceLatencyInput: try readScalar(id, kAudioDevicePropertyLatency, UInt32(0),
                                               scope: kAudioObjectPropertyScopeInput),
            safetyOutput: try readScalar(id, kAudioDevicePropertySafetyOffset, UInt32(0),
                                         scope: kAudioObjectPropertyScopeOutput),
            safetyInput: try readScalar(id, kAudioDevicePropertySafetyOffset, UInt32(0),
                                        scope: kAudioObjectPropertyScopeInput),
            zeroTimestampPeriod: try readScalar(id, zeroSelector, UInt32(0)),
            outputStreams: outputs,
            inputStreams: inputs,
            channels: format.mChannelsPerFrame,
            hflaFrames: controlFrames,
            hflr: revision,
            pendingStatus: statusValue.flatMap(LatencyPendingStatus.init(rawValue:)),
            latencyGlobal: latencyGlobal,
            latencyOutput: latencyOutput)
    }

    /// Enforce the frozen driver contract for the selected device. Read-only.
    func validateContract(_ snap: DeviceSnapshot) throws {
        guard snap.uid == TargetIdentity.deviceUID else {
            throw HFLControlError.contractViolation("unexpected device UID \(snap.uid)")
        }
        guard snap.modelUID == TargetIdentity.modelUID else {
            throw HFLControlError.contractViolation("unexpected model UID \(snap.modelUID)")
        }
        guard snap.isAlive == 1 else { throw HFLControlError.contractViolation("device not alive") }
        guard snap.channels == TargetIdentity.expectedChannels else {
            throw HFLControlError.contractViolation("expected \(TargetIdentity.expectedChannels) channels, read \(snap.channels)")
        }
        guard snap.hflr >= 1 else { throw HFLControlError.contractViolation("hflr must be >= 1") }
        let ceiling = LatencyMath.maxLatencyFrames(rate: snap.nominalRate)
        guard snap.hflaFrames <= ceiling else {
            throw HFLControlError.contractViolation("hfla exceeds 10*rate")
        }
        guard snap.latencyScopesMatch, snap.latencyGlobal == snap.hflaFrames else {
            throw HFLControlError.contractViolation(
                "stream latency scopes/control mismatch: global \(snap.latencyGlobal), output \(snap.latencyOutput), hfla \(snap.hflaFrames)")
        }
        guard snap.deviceLatencyOutput == 0, snap.deviceLatencyInput == 0,
              snap.safetyOutput == 0, snap.safetyInput == 0 else {
            throw HFLControlError.contractViolation("device latency/safety offset must be zero")
        }
        guard snap.zeroTimestampPeriod == 16_384 else {
            throw HFLControlError.contractViolation("zero timestamp period must be 16384")
        }
        guard snap.bufferFrames >= 15, snap.bufferFrames <= 4_096,
              snap.bufferRangeMin <= Double(snap.bufferFrames), Double(snap.bufferFrames) <= snap.bufferRangeMax else {
            throw HFLControlError.contractViolation("buffer size outside HAL-managed range")
        }
    }

    /// Guarded, explicit write. Requires idle IO and (when provided) the exact
    /// expected `hflr` revision. The commit is deferred to the host device
    /// configuration transaction, so the caller waits a bounded interval for
    /// the confirmed committed value and revision. It never rolls back merely
    /// because readback lags the host commit.
    func apply(milliseconds: Int, expectRevision: UInt64?) throws -> ApplyResult {
        let id = try findDevice()
        let before = try snapshot(of: id)
        try validateContract(before)

        if let expected = expectRevision, before.hflr != expected {
            throw HFLControlError.revisionMismatch(expected: expected, actual: before.hflr)
        }
        guard !before.running else { throw HFLControlError.deviceBusy }

        let plan = try LatencyMath.frames(milliseconds: milliseconds, rate: before.nominalRate)
        if plan.frames == before.hflaFrames {
            let after = try snapshot(of: id)
            guard after.hflaFrames == before.hflaFrames,
                  after.hflr == before.hflr,
                  after.latencyScopesMatch,
                  after.latencyGlobal == after.hflaFrames else {
                throw HFLControlError.contractViolation("idempotent value changed concurrently")
            }
            return .noop(before: before, after: after)
        }

        do {
            try writeNumber(id, latencySelector, value: plan.frames)
        } catch {
            // A failed write changes nothing; do not attempt rollback.
            throw error
        }

        let expectedRevision = LatencyMath.expectedRevision(
            previousRevision: before.hflr,
            previousFrames: before.hflaFrames,
            requestedFrames: plan.frames)

        let deadline = Date().addingTimeInterval(Self.commitTimeout)
        while true {
            let after = try snapshot(of: id)
            guard after.nominalRate == before.nominalRate else {
                throw HFLControlError.rateChanged(previous: before.nominalRate,
                                                  current: after.nominalRate)
            }
            if let status = after.pendingStatus, status == .rejected {
                throw HFLControlError.writeRejected(status.label)
            }
            let verified = after.hflaFrames == plan.frames
                && after.hflr == expectedRevision
                && after.latencyScopesMatch
                && after.latencyOutput == plan.frames
                && after.latencyGlobal == plan.frames
            if verified {
                return .applied(before: before, after: after, requestedFrames: plan.frames)
            }
            guard Date() < deadline else {
                throw HFLControlError.commitTimeout(observedFrames: after.hflaFrames,
                                                    requestedFrames: plan.frames)
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
    }

    private func rollback(before: DeviceSnapshot,
                          observed: DeviceSnapshot?,
                          requestedFrames: UInt32,
                          failure: String) throws -> ApplyResult {
        let current: DeviceSnapshot
        do {
            current = try snapshot(of: before.id)
        } catch {
            return .rollbackFailed(before: before, observed: observed ?? before,
                                   requestedFrames: requestedFrames,
                                   failure: "\(failure); re-read for rollback failed: \(error)")
        }
        guard current.nominalRate == before.nominalRate else {
            return .rollbackFailed(before: before, observed: current,
                                   requestedFrames: requestedFrames,
                                   failure: "\(failure); rollback unsafe after rate change")
        }
        do {
            try writeNumber(before.id, latencySelector, value: before.hflaFrames)
            let restored = try snapshot(of: before.id)
            guard restored.hflaFrames == before.hflaFrames,
                  restored.latencyScopesMatch,
                  restored.latencyGlobal == before.hflaFrames,
                  restored.nominalRate == before.nominalRate else {
                return .rollbackFailed(before: before, observed: current,
                                       requestedFrames: requestedFrames,
                                       failure: "\(failure); rollback write did not restore")
            }
            return .rolledBack(before: before, observed: current,
                               requestedFrames: requestedFrames, failure: failure, restored: restored)
        } catch {
            return .rollbackFailed(before: before, observed: current,
                                   requestedFrames: requestedFrames,
                                   failure: "\(failure); rollback write failed: \(error)")
        }
    }
}
