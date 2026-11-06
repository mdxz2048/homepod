import Foundation
import CoreAudio
import CaptureRing

struct ProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    static func current(_ pid: Int32) -> Self? {
        var seconds: UInt64 = 0, microseconds: UInt64 = 0
        guard capture_process_identity(pid, &seconds, &microseconds) == 0 else { return nil }
        return .init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }
}
struct ProcessExclusionEntry: Sendable, Equatable {
    let identity: ProcessIdentity
    let objectID: UInt32?
}

enum ProcessExclusionPolicy {
    static func resolve(identity: ProcessIdentity?, pid: Int32, status: Int32,
                        objectID: UInt32, exclusive: Bool) throws -> ProcessExclusionEntry {
        guard status == noErr else { throw CaptureError.osStatus("Resolve Core Audio process object", status) }
        guard let identity, identity.pid == pid else {
            throw CaptureError.invalidConfiguration("Excluded PID \(pid) is not alive or its identity cannot be verified")
        }
        if objectID == kAudioObjectUnknown {
            guard exclusive else { throw CaptureError.missingProcess(pid) }
            return .init(identity: identity, objectID: nil)
        }
        return .init(identity: identity, objectID: objectID)
    }
    static func validate(_ entry: ProcessExclusionEntry, currentIdentity: ProcessIdentity?,
                         status: Int32, objectID: UInt32) throws {
        guard currentIdentity == entry.identity else {
            throw CaptureError.invalidConfiguration("Excluded process disappeared or PID was reused")
        }
        guard status == noErr else { throw CaptureError.osStatus("Recheck excluded process", status) }
        let current = objectID == kAudioObjectUnknown ? nil : objectID
        guard current == entry.objectID else {
            throw CaptureError.invalidConfiguration("Excluded process registered or changed its Core Audio object; restart capture explicitly")
        }
    }
}

public struct ProcessExclusionReport: Encodable, Sendable {
    public let objectExcludedPIDs: [Int32]
    public let notRegisteredPIDs: [Int32]
    public let registrationMonitoring: Bool
    public let policy = "fail_stop_on_registration_identity_or_object_change"
    init(entries: [ProcessExclusionEntry], monitoring: Bool) {
        objectExcludedPIDs = entries.filter { $0.objectID != nil }.map(\.identity.pid).sorted()
        notRegisteredPIDs = entries.filter { $0.objectID == nil }.map(\.identity.pid).sorted()
        registrationMonitoring = monitoring
    }
    public static var unavailable: Self { .init(entries: [], monitoring: false) }
}

/// Only called from the non-RT control path or serial property queue.
enum AudioProcessLookup {
    static func get(_ value: Int32) -> (status: OSStatus, objectID: AudioObjectID) {
        var pid = value, object: AudioObjectID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<Int32>.size), &pid, &size, &object)
        return (status, object)
    }
    static func validate(_ entries: [ProcessExclusionEntry]) throws {
        for entry in entries {
            let lookup = get(entry.identity.pid)
            try ProcessExclusionPolicy.validate(entry, currentIdentity: .current(entry.identity.pid),
                                                status: lookup.status, objectID: lookup.objectID)
        }
    }
}
