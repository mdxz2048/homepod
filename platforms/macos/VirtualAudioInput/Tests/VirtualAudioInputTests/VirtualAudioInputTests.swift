import Foundation
import XCTest
@testable import VirtualAudioInput

private func fixture() throws -> DiscoveredVirtualDevice {
    let format = try InputFormat(sampleRate: 48_000, packing: .interleaved, channelCount: 2,
                                labels: [.FL, .FR], layoutAuthority: "device", layoutVerified: true)
    return DiscoveredVirtualDevice(descriptor: InputDescriptor(deviceUID: VirtualIdentity.deviceUID,
        capturedFormat: format, latency: LatencyDescriptor(revision: 1, reportedFrames: 0,
            sampleRate: 48_000, calibration: .uncalibrated)), running: false,
        availableSampleRates: [44_100, 48_000], deviceLatencyFrames: 0,
        safetyOffsetFrames: 0, bufferFrames: 512, zeroTimestampPeriod: 16_384)
}

@MainActor
private final class FakeDevice: VirtualDeviceBackend {
    var value: DiscoveredVirtualDevice
    var writes = 0
    var rejectWriteBusy = false
    var injectExternalWrite = false
    init() throws { value = try fixture() }
    func discover() throws -> DiscoveredVirtualDevice { value }
    func setLatencyFrames(_ frames: UInt32) throws {
        if rejectWriteBusy { throw InputFailure.deviceBusy }
        writes += 1
        if value.descriptor.latency.reportedFrames != frames {
            value.descriptor.latency.reportedFrames = frames
            value.descriptor.latency.revision += 1
        }
        if injectExternalWrite { value.descriptor.latency.revision += 1 }
    }
}

@MainActor
private final class MemoryJournal: LeaseJournal {
    var value: OutputLease?
    var rejectSave = false
    func load() throws -> OutputLease? { value }
    func save(_ lease: OutputLease) throws {
        if rejectSave { throw InputFailure.invalidLease }
        value = lease
    }
    func clear(expectedOwner: UUID, expectedGeneration: UInt64) throws {
        guard value?.ownerToken == expectedOwner, value?.generation == expectedGeneration else { throw InputFailure.invalidLease }
        value = nil
    }
}

@MainActor
private final class FakeOutputs: OutputSelectionBackend {
    var current = "builtin"
    var writes = 0
    var outputs: Set<String> = ["builtin", VirtualIdentity.deviceUID]
    var observeJournal: MemoryJournal?
    func currentDefaultUID() throws -> String { current }
    func currentSystemUID() throws -> String { "system-output" }
    func availableOutputUIDs() throws -> Set<String> { outputs }
    func setDefaultUID(_ uid: String, expectedCurrentUID: String) throws {
        guard current == expectedCurrentUID else { throw InputFailure.userOverride }
        if let journal = observeJournal { XCTAssertNotNil(journal.value, "recovery intent precedes mutation") }
        current = uid; writes += 1
    }
}

final class FormatChecks: XCTestCase {
    func testRejectsLabelCountAndNonFiniteRate() throws {
        XCTAssertThrowsError(try InputFormat(sampleRate: .nan, packing: .interleaved, channelCount: 2,
            labels: [.FL, .FR], layoutAuthority: "device", layoutVerified: true))
        XCTAssertThrowsError(try InputFormat(sampleRate: 48_000, packing: .interleaved, channelCount: 6,
            labels: [.FL, .FR], layoutAuthority: "device", layoutVerified: true))
    }
    func testDescriptorRoundTripKeepsUnverifiedCaptureAndSourceProvenance() throws {
        let source = try fixture()
        let decoded = try JSONDecoder().decode(DiscoveredVirtualDevice.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(source, decoded)
        XCTAssertFalse(decoded.tapVerified)
        XCTAssertEqual(decoded.descriptor.provenance, .deviceMix)
        XCTAssertEqual(decoded.descriptor.latency.calibration, .uncalibrated)
        XCTAssertEqual(decoded.descriptor.audioCapturePermission, .unknown)
        XCTAssertNil(decoded.descriptor.decoderReportedFormat)
    }
}

@MainActor
final class ControlChecks: XCTestCase {
    func testDiscoveryIsReadOnlyAndStartNeverPretendsReady() async throws {
        let backend = try FakeDevice(), client = VirtualInputClient(backend: backend)
        _ = try client.discover()
        XCTAssertEqual(backend.writes, 0)
        XCTAssertThrowsError(try client.startCapture()) { XCTAssertEqual($0 as? InputFailure, .capturePathUnverified) }
    }
    func testLatencyWriteConfirmsRevisionButNotCalibration() async throws {
        let backend = try FakeDevice(), client = VirtualInputClient(backend: backend)
        let after = try client.setLatencyFrames(96_000, expectedRevision: 1)
        XCTAssertEqual(after.descriptor.latency.revision, 2)
        XCTAssertEqual(after.descriptor.latency.reportedFrames, 96_000)
        XCTAssertEqual(after.descriptor.latency.calibration, .uncalibrated)
        _ = try client.setLatencyFrames(96_000, expectedRevision: 2)
        XCTAssertEqual(backend.value.descriptor.latency.revision, 2)
    }
    func testRunningStaleAndOutOfRangeNeverWrite() async throws {
        let backend = try FakeDevice(), client = VirtualInputClient(backend: backend)
        backend.value.running = true
        XCTAssertThrowsError(try client.setLatencyFrames(100, expectedRevision: 1)) { XCTAssertEqual($0 as? InputFailure, .deviceBusy) }
        backend.value.running = false
        XCTAssertThrowsError(try client.setLatencyFrames(100, expectedRevision: 2)) { XCTAssertEqual($0 as? InputFailure, .latencyRevisionChanged) }
        XCTAssertThrowsError(try client.setLatencyFrames(480_001, expectedRevision: 1))
        XCTAssertEqual(backend.writes, 0)
    }
    func testDriverRaceAndExternalRevisionDoNotConfirmSuccess() async throws {
        let backend = try FakeDevice(), client = VirtualInputClient(backend: backend)
        backend.rejectWriteBusy = true
        XCTAssertThrowsError(try client.setLatencyFrames(100, expectedRevision: 1)) { XCTAssertEqual($0 as? InputFailure, .deviceBusy) }
        backend.rejectWriteBusy = false; backend.injectExternalWrite = true
        XCTAssertThrowsError(try client.setLatencyFrames(100, expectedRevision: 1)) { XCTAssertEqual($0 as? InputFailure, .latencyRevisionChanged) }
    }
    func testDefaultTakeoverBlockedWithoutIndependentHelper() async throws {
        let outputs = FakeOutputs(), journal = MemoryJournal()
        let controller = OutputLeaseController(backend: outputs, journal: journal)
        let latency = LatencyDescriptor(revision: 1, reportedFrames: 96_000, sampleRate: 48_000, calibration: .planned)
        XCTAssertThrowsError(try controller.takeOver(generation: 1, latency: latency,
            capturePathVerified: true, explicitUserIntent: true)) { XCTAssertEqual($0 as? InputFailure, .recoveryHelperUnavailable) }
        XCTAssertEqual(outputs.writes, 0); XCTAssertNil(journal.value)
    }
    func testJournalBeforeSwitchAndRestoreLeavesSystemRoleAlone() async throws {
        let outputs = FakeOutputs(), journal = MemoryJournal(); outputs.observeJournal = journal
        let controller = OutputLeaseController(backend: outputs, journal: journal)
        let latency = LatencyDescriptor(revision: 3, reportedFrames: 96_000, sampleRate: 48_000, calibration: .planned)
        let lease = try controller.takeOver(generation: 7, latency: latency, capturePathVerified: true,
            explicitUserIntent: true, recoveryHelperAvailable: true)
        XCTAssertEqual(outputs.current, VirtualIdentity.deviceUID)
        XCTAssertFalse(lease.systemModified)
        XCTAssertEqual(lease.originalSystemUID, "system-output")
        let result = try controller.restore(expectedOwner: lease.ownerToken, expectedGeneration: 7)
        XCTAssertEqual(result, .restore("builtin")); XCTAssertEqual(outputs.current, "builtin"); XCTAssertNil(journal.value)
    }
    func testFailedJournalDoesNotSwitchOutput() async throws {
        let outputs = FakeOutputs(), journal = MemoryJournal(); journal.rejectSave = true
        let controller = OutputLeaseController(backend: outputs, journal: journal)
        XCTAssertThrowsError(try controller.takeOver(generation: 1,
            latency: LatencyDescriptor(revision: 1, reportedFrames: 100, sampleRate: 48_000, calibration: .planned),
            capturePathVerified: true, explicitUserIntent: true, recoveryHelperAvailable: true))
        XCTAssertEqual(outputs.writes, 0)
    }
    func testUserOverrideIsPreservedAndOldOwnerCannotRestore() async throws {
        let outputs = FakeOutputs(), journal = MemoryJournal()
        var lease = OutputLease(originalDefaultUID: "builtin", originalSystemUID: "system-output", latencyRevision: 1, generation: 2)
        lease.defaultModified = true; try journal.save(lease)
        let controller = OutputLeaseController(backend: outputs, journal: journal)
        XCTAssertThrowsError(try controller.restore(expectedOwner: UUID(), expectedGeneration: 2))
        XCTAssertNotNil(journal.value)
        outputs.current = "headphones"
        let result = try controller.restore(expectedOwner: lease.ownerToken, expectedGeneration: 2)
        XCTAssertEqual(result, .userOverride); XCTAssertEqual(outputs.writes, 0); XCTAssertNil(journal.value)
    }
    func testMissingOriginalRequiresVerifiedFallbackAndRetainsJournalOnFailure() async throws {
        let outputs = FakeOutputs(), journal = MemoryJournal()
        var lease = OutputLease(originalDefaultUID: "gone", originalSystemUID: "system-output", latencyRevision: 1, generation: 2)
        lease.defaultModified = true; try journal.save(lease); outputs.current = VirtualIdentity.deviceUID
        let controller = OutputLeaseController(backend: outputs, journal: journal)
        XCTAssertThrowsError(try controller.restore(expectedOwner: lease.ownerToken, expectedGeneration: 2))
        XCTAssertNotNil(journal.value); XCTAssertEqual(outputs.writes, 0)
        XCTAssertEqual(try controller.restore(expectedOwner: lease.ownerToken, expectedGeneration: 2,
            verifiedFallbackUID: "builtin"), .restore("builtin"))
    }
    func testFileJournalRejectsStaleOwnerAndPersistsForNextProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("lease.json")
        let first = FileLeaseJournal(url: url)
        let lease = OutputLease(originalDefaultUID: "builtin", originalSystemUID: "system-output", latencyRevision: 1, generation: 9)
        try first.save(lease)
        let reopened = FileLeaseJournal(url: url)
        XCTAssertEqual(try reopened.load(), lease)
        XCTAssertThrowsError(try reopened.clear(expectedOwner: UUID(), expectedGeneration: 9))
        XCTAssertNotNil(try reopened.load())
        try reopened.clear(expectedOwner: lease.ownerToken, expectedGeneration: 9)
        XCTAssertNil(try reopened.load())
    }
    func testOversizedJournalIsRejectedByBoundedRead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: 16_385).write(to: url)
        XCTAssertThrowsError(try FileLeaseJournal(url: url).load()) {
            XCTAssertEqual($0 as? InputFailure, .invalidLease)
        }
    }
}
