import Foundation

/// No persisted enabled flag: a new application process always requires an explicit start.
/// A budget covers the entire unstable period; a brief streaming event never resets it.
struct SystemSessionRecovery {
    private(set) var desiredEnabled = false
    private(set) var attempts = 0
    private(set) var intent = UUID()
    private(set) var blocked = false
    static let delays: [Double] = [1, 2, 4, 8, 16]

    mutating func enable() {
        desiredEnabled = true; attempts = 0; blocked = false; intent = UUID()
    }
    mutating func cancel() { desiredEnabled = false; intent = UUID() }
    mutating func block() { blocked = true }
    mutating func nextDelay(cleanupConfirmed: Bool, retryable: Bool, hasStableTargets: Bool) -> Double? {
        guard desiredEnabled, !blocked else { return nil }
        guard cleanupConfirmed else { blocked = true; return nil }
        guard retryable, hasStableTargets, attempts < Self.delays.count else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }
    /// Called only after an uninterrupted, healthy interval, never on every restart.
    mutating func markStable() { attempts = 0 }
}

struct SystemSessionFailure {
    let kind: String
    let retryable: Bool
    let cleanupConfirmed: Bool
    init(payload: [String: JSONValue]) {
        kind = payload["failure_kind"]?.string ?? "internal_error"
        let transient: Set<String> = ["network_transient", "device_offline", "device_address_changed"]
        retryable = payload["retryable"]?.bool == true && transient.contains(kind)
        cleanupConfirmed = payload["cleanup_complete"]?.bool == true
    }
}

/// No address/name fallback: every saved identity must resolve to exactly one current address.
enum StableReceiverResolution {
    static func addresses(for identifiers: [String], discovery: [String: String]) -> [String]? {
        guard !identifiers.isEmpty, Set(identifiers).count == identifiers.count else { return nil }
        var result: [String] = []
        for identifier in identifiers {
            let matches = discovery.filter { $0.value == identifier }.map(\.key)
            guard matches.count == 1, let host = matches.first else { return nil }
            result.append(host)
        }
        return Set(result).count == result.count ? result : nil
    }
}
