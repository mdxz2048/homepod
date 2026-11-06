import Foundation
import Testing
@testable import ProcessTapCapture

private let workerIdentity = ProcessIdentity(pid: 123, startSeconds: 50, startMicroseconds: 900)

@Test func unregisteredLivePIDIsOnlyAllowedForExclusiveExclusion() throws {
    let entry = try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123,
        status: 0, objectID: 0, exclusive: true)
    #expect(entry.objectID == nil && entry.identity == workerIdentity)
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123, status: 0, objectID: 0, exclusive: false)
    }
    let selected = try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123,
        status: 0, objectID: 42, exclusive: false)
    #expect(selected.objectID == 42)
}

@Test func errorsAndUnverifiableIdentityCannotBecomeNotRegistered() {
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123, status: -55, objectID: 0, exclusive: true)
    }
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.resolve(identity: nil, pid: 123, status: 0, objectID: 0, exclusive: true)
    }
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 456, status: 0, objectID: 0, exclusive: true)
    }
}

@Test func registrationDisappearancePIDReuseAndObjectChangesRequireStop() throws {
    let pending = try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123, status: 0, objectID: 0, exclusive: true)
    try ProcessExclusionPolicy.validate(pending, currentIdentity: workerIdentity, status: 0, objectID: 0)
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.validate(pending, currentIdentity: workerIdentity, status: 0, objectID: 7)
    }
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.validate(pending, currentIdentity: nil, status: 0, objectID: 0)
    }
    let reusedPID = ProcessIdentity(pid: 123, startSeconds: 51, startMicroseconds: 0)
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.validate(pending, currentIdentity: reusedPID, status: 0, objectID: 0)
    }
    let resolved = try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123, status: 0, objectID: 7, exclusive: true)
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.validate(resolved, currentIdentity: workerIdentity, status: 0, objectID: 0)
    }
    #expect(throws: (any Error).self) {
        try ProcessExclusionPolicy.validate(resolved, currentIdentity: workerIdentity, status: -50, objectID: 7)
    }
}

@Test func reportSeparatesActualObjectExclusionsFromUnregisteredPIDs() throws {
    let pending = try ProcessExclusionPolicy.resolve(identity: workerIdentity, pid: 123, status: 0, objectID: 0, exclusive: true)
    let other = ProcessIdentity(pid: 456, startSeconds: 51, startMicroseconds: 2)
    let resolved = try ProcessExclusionPolicy.resolve(identity: other, pid: 456, status: 0, objectID: 42, exclusive: true)
    let report = ProcessExclusionReport(entries: [pending, resolved], monitoring: true)
    #expect(report.notRegisteredPIDs == [123] && report.objectExcludedPIDs == [456])
    #expect(report.registrationMonitoring && report.policy.contains("fail_stop"))
}

@Test func kernelIdentityIsStableForTheCurrentLiveProcess() throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let first = try #require(ProcessIdentity.current(pid))
    let second = try #require(ProcessIdentity.current(pid))
    #expect(first == second && first.pid == pid && first.startSeconds > 0)
    #expect(ProcessIdentity.current(-1) == nil)
}
