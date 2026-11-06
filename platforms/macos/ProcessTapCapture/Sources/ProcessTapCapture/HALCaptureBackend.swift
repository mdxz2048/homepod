import Foundation
import CoreAudio
import CaptureRing

// This noncapturing C callback only validates/copies into preallocated C storage.
// No Swift Array/Data creation, logging, locks, dispatch, or file operations.
private let captureIOProc: AudioDeviceIOProc = { _, now, input, time, output, _, context in
    let silent = capture_zero_output(output)
    if let context {
        let ring = OpaquePointer(context)
        if silent != 0 { capture_ring_set_fault(ring, 6) }
        else { capture_ring_push(ring, input, time, now) }
    }
    return noErr
}

private final class RingToken: @unchecked Sendable {
    let pointer: OpaquePointer
    private let lock = NSLock()
    private var active = true
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    var isActive: Bool { lock.withLock { active } }
    func setFault(_ code: UInt32) {
        lock.withLock { if active { capture_ring_set_fault(pointer, code) } }
    }
    func invalidate() { lock.withLock { active = false } }
}

@MainActor final class HALCaptureBackend: CaptureBackend {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var tapUID: String?
    private var tapFormat: CaptureFormat?
    private var outputClock: OutputClockDescriptor?
    private var io: AudioDeviceIOProcID?
    private var startAttempted = false
    private let listenerQueue = DispatchQueue(label: "HomePodFlow.ProcessTap.property-events")
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var exclusions: [ProcessExclusionEntry] = []
    private var exclusiveSelection = false
    private var processMonitor: (any DispatchSourceTimer)?
    private var ringToken: RingToken?
    var callbackDetached: Bool { !startAttempted && io == nil && listeners.isEmpty && processMonitor == nil }
    var exclusionReport: ProcessExclusionReport {
        exclusiveSelection ? .init(entries: exclusions, monitoring: processMonitor != nil) : .unavailable
    }

    func createTap(configuration: CaptureConfiguration) throws -> CaptureFormat {
        let pids: [Int32]
        let exclusive: Bool
        switch configuration.selection {
        case .processes(let selected): pids = selected; exclusive = false
        case .allExceptCurrentProcess:
            pids = Array(Set(configuration.excludedProcessIDs + [ProcessInfo.processInfo.processIdentifier]))
            exclusive = true
        }
        exclusiveSelection = exclusive
        exclusions = try pids.map { pid in
            let before = ProcessIdentity.current(pid)
            let lookup = AudioProcessLookup.get(pid)
            let after = ProcessIdentity.current(pid)
            guard before != nil, before == after else {
                throw CaptureError.invalidConfiguration("Excluded PID identity changed while resolving Core Audio process")
            }
            return try ProcessExclusionPolicy.resolve(identity: after, pid: pid,
                status: lookup.status, objectID: lookup.objectID, exclusive: exclusive)
        }
        let objects = exclusions.compactMap(\.objectID)
        let description = CATapDescription()
        description.name = "HomePod Flow private capture"
        description.processes = objects
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = exclusive
        description.muteBehavior = .unmuted
        var created: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &created)
        if created != kAudioObjectUnknown { tap = created }
        try check(status, "Create private process tap")
        guard tap != kAudioObjectUnknown else { throw CaptureError.unsupportedFormat }
        var uid: CFString = "" as CFString
        var address = property(kAudioTapPropertyUID)
        var size = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
        }
        try check(uidStatus, "Read tap UID")
        tapUID = uid as String
        var asbd = AudioStreamBasicDescription()
        address = property(kAudioTapPropertyFormat)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Read actual tap format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size else { throw CaptureError.unsupportedFormat }
        let format = try CaptureFormat(asbd: asbd)
        guard format.channels == 2 else { throw CaptureError.unsupportedFormat }
        tapFormat = format
        return format
    }
    func createAggregate() throws {
        guard let tapUID, tapFormat?.channels == 2 else { throw CaptureError.invalidState }
        let clock = try OutputClockLookup.current()
        outputClock = clock
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HomePod Flow private capture input",
            kAudioAggregateDeviceUIDKey: "com.homepodflow.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock.uid]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                               kAudioSubTapDriftCompensationKey: true]]
        ]
        var created: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &created)
        if created != kAudioObjectUnknown { aggregate = created }
        try check(status, "Create private tap aggregate")
        guard aggregate != kAudioObjectUnknown else { throw CaptureError.unsupportedFormat }
    }
    func installIO(ring: OpaquePointer) throws {
        try validateOutputClock()
        try check(AudioDeviceCreateIOProcID(aggregate, captureIOProc, UnsafeMutableRawPointer(ring), &io), "Install capture IOProc")
        let token = RingToken(ring)
        ringToken = token
        try listen(object: tap, selector: kAudioTapPropertyFormat, fault: 3, token: token)
        try listen(object: aggregate, selector: kAudioDevicePropertyDeviceIsAlive, fault: 4, token: token)
        guard let clock = outputClock else { throw CaptureError.invalidState }
        try listen(object: clock.deviceID, selector: kAudioDevicePropertyDeviceIsAlive, fault: 4, token: token)
        try listen(object: clock.deviceID, selector: kAudioDevicePropertyStreams,
                   scope: kAudioDevicePropertyScopeInput, fault: 6, token: token)
        try listen(object: clock.deviceID, selector: kAudioDevicePropertyStreams,
                   scope: kAudioDevicePropertyScopeOutput, fault: 6, token: token)
        try listen(object: AudioObjectID(kAudioObjectSystemObject),
                   selector: kAudioHardwarePropertyDefaultOutputDevice, fault: 4, token: token)
        // No capture IO has started yet. Recheck on both sides of listener
        // registration, then once more at start to avoid a lost change window.
        try AudioProcessLookup.validate(exclusions)
        let snapshot = exclusions
        let verify: @Sendable () -> Void = {
            guard token.isActive else { return }
            do { try AudioProcessLookup.validate(snapshot) }
            catch { token.setFault(5) }
        }
        var address = property(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { _, _ in verify() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectAddPropertyListenerBlock(system, &address, listenerQueue, block), "Watch excluded process registrations")
        listeners.append(.init(object: system, address: address, block: block))
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.setEventHandler(handler: verify)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        processMonitor = timer
        timer.resume()
        try AudioProcessLookup.validate(snapshot)
        try validateOutputClock()
    }
    func startDevice() throws {
        guard let io else { throw CaptureError.invalidState }
        try validateOutputClock()
        try AudioProcessLookup.validate(exclusions)
        if let ringToken, capture_ring_fault(ringToken.pointer) != 0 { throw CaptureError.callbackFault(5) }
        startAttempted = true
        try check(AudioDeviceStart(aggregate, io), "Start process-tap capture (permission may be required)")
        try AudioProcessLookup.validate(exclusions)
        try validateOutputClock()
    }
    func stopDevice() throws {
        guard startAttempted, aggregate != kAudioObjectUnknown, let io else { return }
        try check(AudioDeviceStop(aggregate, io), "Stop capture device")
        startAttempted = false
    }
    func destroyIO() throws {
        guard !startAttempted else {
            throw CaptureError.cleanupFailed(["IOProc retained because stopping the device is unconfirmed"])
        }
        var errors: [String] = []
        processMonitor?.cancel()
        processMonitor = nil
        var retained: [Listener] = []
        for var listener in listeners.reversed() {
            let status = AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, listenerQueue, listener.block)
            if status != noErr {
                errors.append("Remove property listener (\(status))")
                retained.append(listener)
            }
        }
        listeners = retained
        // Drains listener calls already queued before removal before freeing ring.
        listenerQueue.sync { }
        if let io {
            let status = AudioDeviceDestroyIOProcID(aggregate, io)
            if status == noErr { self.io = nil; startAttempted = false }
            else { errors.append("Detach IOProc (\(status))") }
        }
        if callbackDetached { ringToken?.invalidate(); ringToken = nil }
        if !errors.isEmpty { throw CaptureError.cleanupFailed(errors) }
    }
    func destroyAggregate() throws {
        guard aggregate != kAudioObjectUnknown else { return }
        guard callbackDetached, !startAttempted else {
            throw CaptureError.cleanupFailed(["Aggregate retained because IO/listener detachment is unconfirmed"])
        }
        try check(AudioHardwareDestroyAggregateDevice(aggregate), "Destroy private aggregate")
        aggregate = kAudioObjectUnknown
        outputClock = nil
    }
    func destroyTap() throws {
        guard tap != kAudioObjectUnknown else { return }
        guard aggregate == kAudioObjectUnknown, callbackDetached, !startAttempted else {
            throw CaptureError.cleanupFailed(["Tap retained because aggregate/IO cleanup is unconfirmed"])
        }
        try check(AudioHardwareDestroyProcessTap(tap), "Destroy private process tap")
        tap = kAudioObjectUnknown; tapUID = nil; tapFormat = nil
    }
    private func listen(object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        fault: UInt32, token: RingToken) throws {
        var address = property(selector)
        address.mScope = scope
        let block: AudioObjectPropertyListenerBlock = { _, _ in token.setFault(fault) }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block), "Watch capture format/device")
        listeners.append(.init(object: object, address: address, block: block))
    }
    private func validateOutputClock() throws {
        guard let outputClock else { throw CaptureError.invalidState }
        try OutputClockPolicy.validateUnchanged(OutputClockLookup.current(), expected: outputClock)
    }
    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureError.osStatus(operation, status) }
    }
}
