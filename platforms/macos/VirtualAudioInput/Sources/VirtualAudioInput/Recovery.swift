import Foundation

public struct OutputLease: Codable, Equatable, Sendable {
    public var sessionUUID: UUID
    public var ownerToken: UUID
    public var generation: UInt64
    public var virtualUID: String
    public var originalDefaultUID: String
    public var originalSystemUID: String
    public var defaultModified: Bool
    public var systemModified: Bool
    public var latencyRevision: UInt64
    public var createdAt: Date

    public init(originalDefaultUID: String, originalSystemUID: String, latencyRevision: UInt64,
                generation: UInt64, sessionUUID: UUID = UUID(), ownerToken: UUID = UUID()) {
        self.sessionUUID = sessionUUID; self.ownerToken = ownerToken; self.generation = generation
        virtualUID = VirtualIdentity.deviceUID; self.originalDefaultUID = originalDefaultUID
        self.originalSystemUID = originalSystemUID; defaultModified = false; systemModified = false
        self.latencyRevision = latencyRevision; createdAt = Date()
    }
}

public enum RestoreDecision: Equatable, Sendable {
    case noChange
    case userOverride
    case restore(String)
    case unavailable
}

public enum OutputRecoveryPolicy {
    /// Candidates must already be verified, live, non-input, non-project outputs.
    /// The policy never blindly enumerates or chooses aggregate/AirPlay devices.
    public static func decision(lease: OutputLease, expectedOwner: UUID, expectedGeneration: UInt64,
                                currentDefaultUID: String, availableUIDs: Set<String>,
                                verifiedFallbackUID: String?) throws -> RestoreDecision {
        guard lease.ownerToken == expectedOwner, lease.generation == expectedGeneration,
              lease.virtualUID == VirtualIdentity.deviceUID, !lease.systemModified else {
            throw InputFailure.invalidLease
        }
        guard lease.defaultModified else { return .noChange }
        guard currentDefaultUID == lease.virtualUID else { return .userOverride }
        if lease.originalDefaultUID != lease.virtualUID, availableUIDs.contains(lease.originalDefaultUID) {
            return .restore(lease.originalDefaultUID)
        }
        if let fallback = verifiedFallbackUID, fallback != lease.virtualUID, availableUIDs.contains(fallback) {
            return .restore(fallback)
        }
        return .unavailable
    }
}

@MainActor
public protocol LeaseJournal {
    func load() throws -> OutputLease?
    func save(_ lease: OutputLease) throws
    func clear(expectedOwner: UUID, expectedGeneration: UInt64) throws
}

/// Explicitly constructed and explicitly saved only; no implicit filesystem writes.
/// Production caller supplies its private app-support URL, never a shared temporary path.
@MainActor
public final class FileLeaseJournal: LeaseJournal {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> OutputLease? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= 16_384 {
            let remaining = 16_385 - data.count
            guard let part = try handle.read(upToCount: remaining), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= 16_384 else { throw InputFailure.invalidLease }
        return try JSONDecoder().decode(OutputLease.self, from: data)
    }
    public func save(_ lease: OutputLease) throws {
        if let prior = try load(), prior.ownerToken != lease.ownerToken || prior.generation != lease.generation {
            throw InputFailure.invalidLease
        }
        let data = try JSONEncoder().encode(lease)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func clear(expectedOwner: UUID, expectedGeneration: UInt64) throws {
        guard let lease = try load() else { return }
        guard lease.ownerToken == expectedOwner, lease.generation == expectedGeneration else {
            throw InputFailure.invalidLease
        }
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor
public protocol OutputSelectionBackend {
    func currentDefaultUID() throws -> String
    func currentSystemUID() throws -> String
    func availableOutputUIDs() throws -> Set<String>
    /// Backend must recheck expected UID immediately before setting; no CLI exposes this API.
    func setDefaultUID(_ uid: String, expectedCurrentUID: String) throws
}

/// Injectable lifecycle skeleton. No real HAL default-output writer or helper is provided.
@MainActor
public final class OutputLeaseController {
    private let backend: any OutputSelectionBackend
    private let journal: any LeaseJournal
    public init(backend: any OutputSelectionBackend, journal: any LeaseJournal) {
        self.backend = backend; self.journal = journal
    }

    public func takeOver(generation: UInt64, latency: LatencyDescriptor,
                         capturePathVerified: Bool, explicitUserIntent: Bool,
                         recoveryHelperAvailable: Bool = false) throws -> OutputLease {
        guard explicitUserIntent else { throw InputFailure.invalidLease }
        guard recoveryHelperAvailable else { throw InputFailure.recoveryHelperUnavailable }
        guard capturePathVerified else { throw InputFailure.capturePathUnverified }
        guard latency.calibration != .uncalibrated else { throw InputFailure.invalidProperty("uncalibrated latency") }
        guard try journal.load() == nil else { throw InputFailure.invalidLease }
        let original = try backend.currentDefaultUID()
        guard original != VirtualIdentity.deviceUID else { throw InputFailure.invalidLease }
        var lease = OutputLease(originalDefaultUID: original, originalSystemUID: try backend.currentSystemUID(),
                                latencyRevision: latency.revision, generation: generation)
        // Persist recovery intent before mutation. Even a crash between set and confirmation is recoverable.
        lease.defaultModified = true
        try journal.save(lease)
        try backend.setDefaultUID(lease.virtualUID, expectedCurrentUID: original)
        guard try backend.currentDefaultUID() == lease.virtualUID else { throw InputFailure.userOverride }
        return lease
    }

    @discardableResult
    public func restore(expectedOwner: UUID, expectedGeneration: UInt64,
                        verifiedFallbackUID: String? = nil) throws -> RestoreDecision {
        guard let lease = try journal.load() else { return .noChange }
        let current = try backend.currentDefaultUID()
        let result = try OutputRecoveryPolicy.decision(lease: lease, expectedOwner: expectedOwner,
            expectedGeneration: expectedGeneration, currentDefaultUID: current,
            availableUIDs: try backend.availableOutputUIDs(), verifiedFallbackUID: verifiedFallbackUID)
        switch result {
        case .restore(let uid):
            try backend.setDefaultUID(uid, expectedCurrentUID: current)
            guard try backend.currentDefaultUID() == uid else { throw InputFailure.outputRestoreFailed }
            try journal.clear(expectedOwner: expectedOwner, expectedGeneration: expectedGeneration)
        case .noChange, .userOverride:
            try journal.clear(expectedOwner: expectedOwner, expectedGeneration: expectedGeneration)
        case .unavailable: throw InputFailure.outputRestoreFailed // Keep journal for later recovery.
        }
        return result
    }
}
