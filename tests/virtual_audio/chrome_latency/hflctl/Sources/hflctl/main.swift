import CoreAudio
import Darwin
import Foundation
import HFLatencyControlCore

let toolName = "hflctl"
let toolVersion = "0.1.0"

func nowUnixMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000.0)
}

func num(_ value: UInt32) -> NSNumber { NSNumber(value: value) }
func num(_ value: UInt64) -> NSNumber { NSNumber(value: value) }
func num(_ value: Int64) -> NSNumber { NSNumber(value: value) }
func num(_ value: Int) -> NSNumber { NSNumber(value: value) }
func num(_ value: Double) -> NSNumber { NSNumber(value: value) }
func num(_ value: Bool) -> NSNumber { NSNumber(value: value) }

func snapshotJSON(_ s: DeviceSnapshot) -> [String: Any] {
    [
        "id": num(s.id),
        "uid": s.uid,
        "model_uid": s.modelUID,
        "alive": num(s.isAlive == 1),
        "device_is_running": num(s.isRunning),
        "device_is_running_somewhere": num(s.isRunningSomewhere),
        "running": num(s.running),
        "nominal_rate": num(s.nominalRate),
        "available_rates": s.availableRates.map { num($0) },
        "buffer_frames": num(s.bufferFrames),
        "buffer_range_min": num(s.bufferRangeMin),
        "buffer_range_max": num(s.bufferRangeMax),
        "device_latency_frames_output": num(s.deviceLatencyOutput),
        "device_latency_frames_input": num(s.deviceLatencyInput),
        "safety_offset_frames_output": num(s.safetyOutput),
        "safety_offset_frames_input": num(s.safetyInput),
        "zero_timestamp_period": num(s.zeroTimestampPeriod),
        "output_streams": num(s.outputStreams.count),
        "input_streams": num(s.inputStreams.count),
        "channels": num(s.channels),
        "hfla_frames": num(s.hflaFrames),
        "hfla_ms": num(LatencyMath.milliseconds(frames: s.hflaFrames, rate: s.nominalRate)),
        "hflr": num(s.hflr),
        "pending_status": s.pendingStatus?.label ?? "unknown",
        "stream_latency_global_frames": num(s.latencyGlobal),
        "stream_latency_output_frames": num(s.latencyOutput),
        "latency_scopes_match": num(s.latencyScopesMatch),
        "control_scope_match": num(s.latencyGlobal == s.hflaFrames && s.hflaFrames == s.latencyOutput),
    ]
}

func errorKind(_ error: Error) -> String {
    if let e = error as? HFLControlError {
        switch e {
        case .deviceNotFound: return "device_not_found"
        case .duplicateDeviceUID: return "duplicate_device_uid"
        case .halRead, .halWrite: return "hal_error"
        case .sizeMismatch: return "size_mismatch"
        case .customPropertyType: return "custom_property_type"
        case .revisionMismatch: return "revision_mismatch"
        case .deviceBusy: return "device_busy"
        case .rateChanged: return "rate_changed"
        case .commitTimeout: return "commit_timeout"
        case .writeRejected: return "write_rejected"
        case .contractViolation: return "contract_violation"
        case .notSettable: return "not_settable"
        case .invalidRequest: return "invalid_request"
        }
    }
    if error is LatencyMathError { return "latency_range" }
    return "unknown_error"
}

func fail(dictionary: [String: Any]) -> Never {
    let object: [String: Any] = [
        "ok": false,
        "tool": toolName,
        "version": toolVersion,
        "timestamp_unix_ms": num(nowUnixMs()),
        "error": dictionary,
    ]
    emit(object)
    exit(1)
}

func ok(_ extra: [String: Any]) -> Never {
    var object: [String: Any] = [
        "ok": true,
        "tool": toolName,
        "version": toolVersion,
        "timestamp_unix_ms": num(nowUnixMs()),
    ]
    for (key, value) in extra { object[key] = value }
    emit(object)
    exit(0)
}

func emit(_ object: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            fputs("hflctl: json encoding failed\n", stderr)
            exit(1)
        }
        print(text)
    } catch {
        fputs("hflctl: json serialization failed: \(error)\n", stderr)
        exit(1)
    }
}

func usage() -> String {
    """
    hflctl \(toolVersion) — HomePod Flow Audio latency control (fail-closed)

    Target UID: \(TargetIdentity.deviceUID)
    Exact device only; never touches another UID or the system default.

    COMMANDS
      hflctl status [--expect-revision N]
          Read-only: enumerate the exact UID and report rate, running IO,
          hfla/hflr CFNumber, stream latency in both scopes, buffer/clock,
          and contract consistency. Prints JSON. Exits non-zero on any error.

      hflctl set-ms MILLISECONDS [--expect-revision N]
          Explicit latency write, 0...3000 ms. Requires no running IO, checks
          the expected hflr revision before writing, converts ms to frames at
          the current rate, writes, then waits up to 2s for the host device
          configuration transaction to commit and verifies read-back plus both
          stream latency scopes and the expected revision. A lagging readback
          is never treated as a failed write, so no premature rollback is
          issued. Never reports success without verification.

      hflctl rollback --to-ms MILLISECONDS [--expect-revision N]
          Same guarded write path as set-ms but labelled as an explicit
          rollback of a previous configuration.

      hflctl self-check
          Offline-only check of the latency arithmetic. No CoreAudio calls.

      hflctl schema
          Print the JSON field description as text.

    SAFETY
      - No default device, no other UID, no rate change, no install/delete.
      - set-ms/rollback fail closed when IO is running, the revision moved,
        the rate changed, the host rejects the transaction (write_rejected),
        or the commit is not confirmed within the bounded wait (commit_timeout).
      - Exit codes: 0 verified success, 1 any failure, 2 usage error.
    """
}

func schemaText() -> String {
    """
    hflctl JSON (single object on stdout):
      ok                    Bool    true only when the requested result was verified
      tool / version        String
      timestamp_unix_ms     Number
      command               String  status | set-ms | rollback | self-check
      device                Object  status/apply snapshot (see keys below)
      contract              Object  { ok, checks } for status
      expect_revision       Object  { expected, actual, ok } when requested
      before / after        Object  snapshots for write commands
      requested             Object  { milliseconds, frames, rate }
      applied               Bool    false for an idempotent no-op read
      verified              Object  per-field booleans
      rollback              Object? present when verification failed after a write
      error                 Object? { kind, message } on failure; ok=false

    device keys: uid, model_uid, alive, device_is_running,
      device_is_running_somewhere, running, nominal_rate, available_rates,
      buffer_frames, buffer_range_min/max, device_latency_frames_output/input,
      safety_offset_frames_output/input, zero_timestamp_period, output_streams,
      input_streams, channels, hfla_frames, hfla_ms, hflr,
      pending_status, stream_latency_global_frames, stream_latency_output_frames,
      latency_scopes_match, control_scope_match
    """
}

enum Command {
    case status(expectRevision: UInt64?)
    case setMs(milliseconds: Int, expectRevision: UInt64?)
    case rollback(milliseconds: Int, expectRevision: UInt64?)
    case selfCheck
    case schema
}

enum UsageError: Error, CustomStringConvertible {
    case message(String)
    var description: String { "usage_error: \(self)" }
}

func parse(_ arguments: [String]) throws -> Command {
    if arguments.isEmpty { return .status(expectRevision: nil) }
    let command = arguments[0]
    let rest = Array(arguments.dropFirst())

    func option(_ name: String, in args: [String]) -> (value: String?, rest: [String]) {
        var idx = 0
        var rest = args
        while idx < rest.count {
            if rest[idx] == name {
                guard idx + 1 < rest.count else { return (nil, rest) }
                let value = rest[idx + 1]
                rest.removeSubrange(idx...(idx + 1))
                return (value, rest)
            }
            idx += 1
        }
        return (nil, rest)
    }

    func expectRevision(_ args: [String]) throws -> (UInt64?, [String]) {
        let parsed = option("--expect-revision", in: args)
        guard let value = parsed.value else { return (nil, parsed.rest) }
        guard let rev = UInt64(value) else { throw UsageError.message("invalid --expect-revision: \(value)") }
        return (rev, parsed.rest)
    }

    switch command {
    case "status":
        let (rev, rest) = try expectRevision(rest)
        guard rest.isEmpty else { throw UsageError.message("status takes no positional arguments") }
        return .status(expectRevision: rev)

    case "set-ms":
        let parsedMs = option("--expect-revision", in: rest)
        let revision = parsedMs.value.flatMap(UInt64.init)
        guard parsedMs.value == nil || revision != nil else {
            throw UsageError.message("invalid --expect-revision: \(parsedMs.value!)")
        }
        let positional = parsedMs.rest.filter { $0 != "--expect-revision" }
        guard positional.count == 1, let ms = Int(positional[0]) else {
            throw UsageError.message("set-ms requires exactly one millisecond argument")
        }
        try LatencyMath.validateMilliseconds(ms)
        return .setMs(milliseconds: ms, expectRevision: revision)

    case "rollback":
        let parsedTo = option("--to-ms", in: rest)
        guard let toValue = parsedTo.value else {
            throw UsageError.message("rollback requires --to-ms MILLISECONDS")
        }
        guard let ms = Int(toValue) else {
            throw UsageError.message("invalid --to-ms: \(toValue)")
        }
        try LatencyMath.validateMilliseconds(ms)
        let remaining = parsedTo.rest.filter { !$0.hasPrefix("--to-ms") }
        let parsedRev = option("--expect-revision", in: remaining)
        guard parsedRev.rest.filter({ $0 != "--to-ms" }).isEmpty else {
            throw UsageError.message("rollback takes no positional arguments")
        }
        let revision = parsedRev.value.flatMap(UInt64.init)
        guard parsedRev.value == nil || revision != nil else {
            throw UsageError.message("invalid --expect-revision: \(parsedRev.value!)")
        }
        return .rollback(milliseconds: ms, expectRevision: revision)

    case "self-check":
        guard rest.isEmpty else { throw UsageError.message("self-check takes no arguments") }
        return .selfCheck

    case "schema":
        return .schema

    case "help", "--help", "-h":
        print(usage())
        exit(0)

    case "--version", "version":
        var object: [String: Any] = ["tool": toolName, "version": toolVersion]
        object["ok"] = true
        emit(object)
        exit(0)

    default:
        throw UsageError.message("unknown command: \(command)")
    }
}

func runStatus(client: CoreAudioClient, expectRevision: UInt64?) {
    do {
        let id = try client.findDevice()
        let snap = try client.snapshot(of: id)
        try client.validateContract(snap)
        var extra: [String: Any] = ["command": "status", "device": snapshotJSON(snap)]
        extra["contract"] = ["ok": true]
        if let expected = expectRevision {
            extra["expect_revision"] = [
                "expected": num(expected),
                "actual": num(snap.hflr),
                "ok": num(expected == snap.hflr),
            ]
            guard expected == snap.hflr else {
                fail(dictionary: [
                    "kind": "revision_mismatch",
                    "expected": num(expected),
                    "actual": num(snap.hflr),
                    "message": "expected hflr \(expected) but device reports \(snap.hflr)",
                ])
            }
        }
        ok(extra)
    } catch {
        fail(dictionary: ["kind": errorKind(error), "message": "\(error)"])
    }
}

func runSelfCheck() {
    var checks: [[String: Any]] = []
    var allPassed = true
    func check(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            checks.append(["name": name, "ok": true])
        } catch {
            allPassed = false
            checks.append(["name": name, "ok": false, "error": "\(error)"])
        }
    }

    check("frames-0-ms") {
        guard try LatencyMath.frames(milliseconds: 0, rate: 48_000).frames == 0 else { throw UsageError.message("0ms") }
    }
    check("frames-1000-ms-48k") {
        guard try LatencyMath.frames(milliseconds: 1000, rate: 48_000).frames == 48_000 else { throw UsageError.message("1s@48k") }
    }
    check("frames-2000-ms-44100") {
        guard try LatencyMath.frames(milliseconds: 2000, rate: 44_100).frames == 88_200 else { throw UsageError.message("2s@44.1k") }
    }
    check("frames-3000-ms-48k") {
        guard try LatencyMath.frames(milliseconds: 3000, rate: 48_000).frames == 144_000 else { throw UsageError.message("3s@48k") }
    }
    check("frames-below-10s-ceiling") {
        let plan = try LatencyMath.frames(milliseconds: 3000, rate: 48_000)
        guard plan.frames <= LatencyMath.maxLatencyFrames(rate: 48_000) else { throw UsageError.message("ceiling") }
    }
    check("out-of-range-rejected") {
        var rejected = false
        do { _ = try LatencyMath.frames(milliseconds: 3001, rate: 48_000) } catch { rejected = true }
        guard rejected else { throw UsageError.message("3001ms unexpectedly accepted") }
    }
    check("bad-rate-rejected") {
        var rejected = false
        do { _ = try LatencyMath.frames(milliseconds: 100, rate: 48_001) } catch { rejected = true }
        guard rejected else { throw UsageError.message("bad rate unexpectedly accepted") }
    }
    check("revision-idempotent-and-increment") {
        guard LatencyMath.expectedRevision(previousRevision: 1, previousFrames: 0, requestedFrames: 0) == 1 else { throw UsageError.message("idempotent") }
        guard LatencyMath.expectedRevision(previousRevision: 1, previousFrames: 0, requestedFrames: 96_000) == 2 else { throw UsageError.message("increment") }
    }

    if allPassed {
        ok(["command": "self-check", "checks": checks])
    } else {
        fail(dictionary: ["kind": "self_check_failed", "checks": checks])
    }
}

func runApply(_ command: String, milliseconds: Int, expectRevision: UInt64?, client: CoreAudioClient) {
    do {
        let outcome = try client.apply(milliseconds: milliseconds, expectRevision: expectRevision)
        let plan = try LatencyMath.frames(milliseconds: milliseconds, rate: {
            switch outcome {
            case .noop(let before, _): return before.nominalRate
            case .applied(let before, _, _): return before.nominalRate
            case .rolledBack(let before, _, _, _, _): return before.nominalRate
            case .rollbackFailed(let before, _, _, _): return before.nominalRate
            }
        }())
        var extra: [String: Any] = [
            "command": command,
            "requested": [
                "milliseconds": num(milliseconds),
                "frames": num(plan.frames),
                "rate": num(plan.sampleRate),
            ],
        ]
        switch outcome {
        case .noop(let before, let after):
            extra["before"] = snapshotJSON(before)
            extra["after"] = snapshotJSON(after)
            extra["applied"] = false
            extra["verified"] = ["hfla_frames": true, "stream_latency_global": true,
                                 "stream_latency_output": true, "revision": true]
            extra["note"] = "requested value already active; idempotent, revision unchanged"
        case .applied(let before, let after, let requestedFrames):
            extra["before"] = snapshotJSON(before)
            extra["after"] = snapshotJSON(after)
            extra["applied"] = true
            extra["verified"] = [
                "hfla_frames": after.hflaFrames == requestedFrames,
                "stream_latency_global": after.latencyGlobal == requestedFrames,
                "stream_latency_output": after.latencyOutput == requestedFrames,
                "revision": after.hflr == LatencyMath.expectedRevision(
                    previousRevision: before.hflr, previousFrames: before.hflaFrames,
                    requestedFrames: requestedFrames),
                "rate_unchanged": after.nominalRate == before.nominalRate,
            ]
            extra["rollback"] = false
        case .rolledBack(let before, let observed, let requestedFrames, let failure, let restored):
            extra["before"] = snapshotJSON(before)
            extra["observed"] = snapshotJSON(observed)
            extra["restored"] = snapshotJSON(restored)
            extra["applied"] = false
            extra["verified"] = false
            extra["rollback"] = ["attempted": true, "restored": true, "failure": failure]
            extra["error"] = ["kind": "write_not_verified_rolled_back", "message": failure,
                              "requested_frames": num(requestedFrames)]
        case .rollbackFailed(let before, let observed, let requestedFrames, let failure):
            extra["before"] = snapshotJSON(before)
            extra["observed"] = snapshotJSON(observed)
            extra["applied"] = false
            extra["verified"] = false
            extra["rollback"] = ["attempted": true, "restored": false, "failure": failure]
            extra["error"] = [
                "kind": "write_not_verified_rollback_failed",
                "message": failure,
                "requested_frames": num(requestedFrames),
                "manual_restore": [
                    "previous_frames": num(before.hflaFrames),
                    "previous_rate": num(before.nominalRate),
                    "previous_ms": num(LatencyMath.milliseconds(frames: before.hflaFrames, rate: before.nominalRate)),
                ],
            ]
        }
        switch outcome {
        case .noop, .applied:
            ok(extra)
        case .rolledBack:
            emitError(extra)
            exit(1)
        case .rollbackFailed:
            emitError(extra)
            exit(1)
        }
    } catch {
        fail(dictionary: ["kind": errorKind(error), "message": "\(error)"])
    }
}

func emitError(_ object: [String: Any]) {
    var failObject: [String: Any] = [
        "ok": false,
        "tool": toolName,
        "version": toolVersion,
        "timestamp_unix_ms": num(nowUnixMs()),
    ]
    for (key, value) in object { failObject[key] = value }
    emit(failObject)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command: Command
do {
    command = try parse(arguments)
} catch {
    let base: [String: Any] = ["kind": errorKind(error), "message": "\(error)"]
    var obj = base
    obj["usage"] = usage()
    emit(["ok": false, "tool": toolName, "version": toolVersion,
          "timestamp_unix_ms": num(nowUnixMs()), "error": obj])
    exit(2)
}

let client = CoreAudioClient()
switch command {
case .status(let expectRevision):
    runStatus(client: client, expectRevision: expectRevision)
case .setMs(let ms, let expectRevision):
    runApply("set-ms", milliseconds: ms, expectRevision: expectRevision, client: client)
case .rollback(let ms, let expectRevision):
    runApply("rollback", milliseconds: ms, expectRevision: expectRevision, client: client)
case .selfCheck:
    runSelfCheck()
case .schema:
    print(schemaText())
    exit(0)
}
