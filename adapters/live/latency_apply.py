"""Owned hflctl latency application for the live captured path (no shell).

The live session applies the negotiated plan exactly once per explicit
activation: after all selected AirPlay receivers agree and before
``capture.start()`` or the first PCM clock is anchored.  Runs are bounded and
the helper is always spawned with ``asyncio.create_subprocess_exec`` using an
argument list, never a shell string.  On timeout or cancellation the child is
terminated, killed when needed, and reaped; no live write is ever issued after
cancellation.

Outcome classification (no false success):

* ``unchanged``: a verified status read already matches the target; no write.
* ``applied``: the guarded write is followed by a fresh verified status read.
* ``pending``: the device is running for another client, or the guarded write
  reports ``device_busy`` / ``revision_mismatch`` / ``write_rejected``.  The
  existing stream is preserved and the write is retried on the next explicit
  activation.
* failure: helper unavailable, invalid contract, timeout, or unverified write.
  The session reports the failure and continues with its negotiated playback plan.
"""
from __future__ import annotations

import asyncio
import json
import math
from dataclasses import dataclass

from .hub import LiveFailure
from .latency_control import MAX_LATENCY_MS, planned_presentation_ms, validate_latency_report

STATUS_TIMEOUT_SECONDS = 6.0
WRITE_TIMEOUT_SECONDS = 12.0
_MAX_OUTPUT_BYTES = 65536
_PENDING_ERROR_KINDS = frozenset(("device_busy", "revision_mismatch", "write_rejected"))


class LatencyApplyError(LiveFailure):
    """The driver's reported latency could not be verified for this plan."""


@dataclass(frozen=True)
class LatencyApplyResult:
    status: str
    target_ms: int
    latency_samples: int
    sample_rate: int
    old_ms: float
    reported_ms: float
    revision_before: int
    revision: int
    expected_revision: int
    write_attempted: bool
    device_is_running: bool
    pending_reason: str
    detail: str
    verified_report: dict

    def report(self) -> dict:
        if self.status not in ("unchanged", "applied", "pending"):
            raise AssertionError("only terminal latency outcomes produce a report")
        return {
            "status": self.status,
            "target_ms": self.target_ms,
            "negotiated_latency_samples": self.latency_samples,
            "sample_rate": self.sample_rate,
            "old_ms": self.old_ms,
            "reported_ms": self.reported_ms,
            "revision_before": self.revision_before,
            "revision": self.revision,
            "expected_revision": self.expected_revision,
            "write_attempted": self.write_attempted,
            "device_is_running": self.device_is_running,
            "pending_reason": self.pending_reason,
            "detail": self.detail,
        }


@dataclass(frozen=True)
class _StatusRead:
    report: dict
    frames: int
    ms: float
    revision: int
    nominal_rate: int
    running: bool
    pending_status: str


def _frames_for_ms(rate: int, milliseconds: int) -> int:
    """Match the helper's half-away-from-zero millisecond -> frame conversion."""
    raw = float(milliseconds) * rate / 1000.0
    return int(math.floor(raw + 0.5)) if raw >= 0 else int(math.ceil(raw - 0.5))


def _expected_revision(before_revision: int, before_frames: int, target_frames: int) -> int:
    return before_revision if before_frames == target_frames else before_revision + 1


async def _reap(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), 2.0)
    except (asyncio.TimeoutError, ProcessLookupError):
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                return
            try:
                await asyncio.wait_for(process.wait(), 2.0)
            except (asyncio.TimeoutError, ProcessLookupError):
                pass


async def _run(helper: str, arguments: tuple, timeout: float):
    try:
        process = await asyncio.create_subprocess_exec(
            helper, *arguments,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
    except OSError as error:
        raise LatencyApplyError("latency helper could not be started") from error
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
    except asyncio.TimeoutError:
        await _reap(process)
        raise LatencyApplyError("latency helper exceeded the bounded wait")
    except asyncio.CancelledError:
        await _reap(process)
        raise
    except BaseException as error:
        await _reap(process)
        raise LatencyApplyError("latency helper failed") from error
    return (process.returncode,
            stdout[:_MAX_OUTPUT_BYTES],
            stderr[:_MAX_OUTPUT_BYTES])


def _decode(stdout: bytes, stderr: bytes) -> dict:
    try:
        parsed = json.loads(stdout.decode("utf-8", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        tail = stderr.decode("utf-8", "replace").strip()
        message = "latency helper output was not valid JSON"
        if tail:
            message += ": " + tail[:160]
        raise LatencyApplyError(message) from error
    if not isinstance(parsed, dict):
        raise LatencyApplyError("latency helper output was not an object")
    return parsed


def _error_kind(stdout: bytes, stderr: bytes) -> str:
    try:
        parsed = _decode(stdout, stderr)
    except LatencyApplyError:
        return "unknown"
    error = parsed.get("error")
    if not isinstance(error, dict):
        return "unknown"
    return str(error.get("kind") or "unknown")


def _error_detail(stdout: bytes, stderr: bytes, fallback: str) -> str:
    try:
        parsed = _decode(stdout, stderr)
    except LatencyApplyError:
        return fallback
    error = parsed.get("error")
    if isinstance(error, dict):
        value = error.get("kind") or error.get("message") or fallback
        return " ".join(str(value).split())[:256]
    return fallback


def _normalize_device(device) -> _StatusRead:
    if not isinstance(device, dict):
        raise LatencyApplyError("latency helper snapshot is not an object")
    try:
        channels = int(device["channels"])
        nominal_rate = float(device["nominal_rate"])
        hfla_frames = int(device["hfla_frames"])
        hfla_ms = float(device["hfla_ms"])
        revision = int(device["hflr"])
        global_frames = int(device["stream_latency_global_frames"])
        output_frames = int(device["stream_latency_output_frames"])
    except (KeyError, TypeError, ValueError) as error:
        raise LatencyApplyError("latency helper snapshot is incomplete") from error
    running = bool(device.get("device_is_running")
                   or device.get("device_is_running_somewhere")
                   or device.get("running"))
    scopes_match = bool(device.get("latency_scopes_match",
                                   global_frames == output_frames))
    control_match = bool(device.get("control_scope_match",
                                    (global_frames == hfla_frames
                                     and hfla_frames == output_frames)))
    report = {
        "verified": True,
        "tool": "hflctl",
        "command": "status",
        "uid": device.get("uid"),
        "model_uid": device.get("model_uid"),
        "channels": channels,
        "nominal_rate": nominal_rate,
        "hfla_frames": hfla_frames,
        "hfla_ms": hfla_ms,
        "hflr": revision,
        "stream_latency_global_frames": global_frames,
        "stream_latency_output_frames": output_frames,
        "latency_scopes_match": scopes_match,
        "control_scope_match": control_match,
        "device_is_running": running,
    }
    try:
        normalized = validate_latency_report(report)
    except ValueError as error:
        raise LatencyApplyError("latency helper status did not verify") from error
    return _StatusRead(normalized, hfla_frames, hfla_ms, revision,
                       int(nominal_rate), running,
                       str(device.get("pending_status") or "unknown"))


async def _status(helper: str) -> _StatusRead:
    code, stdout, stderr = await _run(helper, ("status",), STATUS_TIMEOUT_SECONDS)
    if code != 0:
        raise LatencyApplyError("latency helper status failed: "
                                + _error_detail(stdout, stderr, "non-zero exit"))
    parsed = _decode(stdout, stderr)
    if parsed.get("ok") is not True or parsed.get("command") != "status":
        raise LatencyApplyError("latency helper status was not a verified read")
    return _normalize_device(parsed.get("device"))


def _result(status: str, before: _StatusRead, after: _StatusRead | None, *,
            target_ms: int, latency_samples: int, sample_rate: int,
            write_attempted: bool, pending_reason: str = "", detail: str = "") -> LatencyApplyResult:
    read = after if after is not None else before
    target_frames = _frames_for_ms(read.nominal_rate, target_ms)
    expected = _expected_revision(before.revision, before.frames, target_frames)
    return LatencyApplyResult(
        status=status,
        target_ms=target_ms,
        latency_samples=latency_samples,
        sample_rate=sample_rate,
        old_ms=before.ms,
        reported_ms=read.ms,
        revision_before=before.revision,
        revision=read.revision,
        expected_revision=expected,
        write_attempted=write_attempted,
        device_is_running=read.running,
        pending_reason=pending_reason,
        detail=detail,
        verified_report=read.report,
    )


async def apply_planned_latency(helper: str, latency_samples: int,
                                sample_rate: int) -> LatencyApplyResult:
    """Apply the negotiated presentation latency to the exact Flow driver."""
    if not isinstance(helper, str) or not helper:
        raise LatencyApplyError("latency helper path is missing")
    target_ms = planned_presentation_ms(latency_samples, sample_rate)
    if target_ms < 0 or target_ms > MAX_LATENCY_MS:
        raise LatencyApplyError(
            f"negotiated planned presentation {target_ms} ms is outside the "
            f"0..{MAX_LATENCY_MS} ms Core Audio contract; refusing to clamp")

    before = await _status(helper)
    target_frames = _frames_for_ms(before.nominal_rate, target_ms)
    if before.pending_status == "pending":
        return _result("pending", before, None, target_ms=target_ms,
                       latency_samples=latency_samples, sample_rate=sample_rate,
                       write_attempted=False,
                       pending_reason="a Core Audio configuration change is pending")
    if before.frames == target_frames:
        return _result("unchanged", before, None, target_ms=target_ms,
                       latency_samples=latency_samples, sample_rate=sample_rate,
                       write_attempted=False,
                       detail="verified status already matches the negotiated target")
    if before.running:
        return _result("pending", before, None, target_ms=target_ms,
                       latency_samples=latency_samples, sample_rate=sample_rate,
                       write_attempted=False,
                       pending_reason="device is running for another client")

    expected = _expected_revision(before.revision, before.frames, target_frames)
    code, stdout, stderr = await _run(
        helper, ("set-ms", str(target_ms), "--expect-revision", str(before.revision)),
        WRITE_TIMEOUT_SECONDS)
    if code != 0:
        kind = _error_kind(stdout, stderr)
        if kind in _PENDING_ERROR_KINDS:
            return _result("pending", before, None, target_ms=target_ms,
                           latency_samples=latency_samples, sample_rate=sample_rate,
                           write_attempted=True,
                           pending_reason="guarded write deferred (" + kind + ")")
        raise LatencyApplyError("latency helper write failed: "
                                + _error_detail(stdout, stderr, "kind=" + kind))
    parsed = _decode(stdout, stderr)
    if parsed.get("ok") is not True or parsed.get("command") != "set-ms":
        kind = _error_kind(stdout, stderr)
        if kind in _PENDING_ERROR_KINDS:
            return _result("pending", before, None, target_ms=target_ms,
                           latency_samples=latency_samples, sample_rate=sample_rate,
                           write_attempted=True,
                           pending_reason="guarded write deferred (" + kind + ")")
        raise LatencyApplyError("latency helper write did not verify")
    after = _normalize_device(parsed.get("after"))
    if after.frames != target_frames or after.revision != expected:
        raise LatencyApplyError("latency helper write read-back did not match the requested value")

    verified = await _status(helper)
    if verified.frames != target_frames or verified.revision != expected:
        raise LatencyApplyError("latency helper write was not confirmed by a fresh status read")
    return _result("applied", before, verified, target_ms=target_ms,
                   latency_samples=latency_samples, sample_rate=sample_rate,
                   write_attempted=True,
                   detail="guarded write verified by a fresh status read")
