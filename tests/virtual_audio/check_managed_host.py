"""015 integration gate: real Swift managed host -> Python -> native core.

Runs the independently-built ManagedHostProbe executable (real
VirtualCaptureHostController + BoundedPipeWriter, deterministic FakeProvider)
through CaptureHostV2, VirtualRoutePlan and LiveHub with the real native Engine
against libflow_bridge.dylib. It never touches HAL, TCC, RAOP, HomePods or the
default device, and it reports ``acoustic_sync_verified: false``.
"""
from __future__ import annotations

import argparse
import array
import asyncio
import hashlib
import json
import math
import os
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from adapters.live.capture_v2 import CaptureHostV2
from adapters.live.hub import LiveHub
from adapters.live.pcm_v2 import CANONICAL_DEVICE_UID, LAYOUTS, read_frame_v2
from adapters.live.routing_v2 import VirtualRoutePlan

SESSION = "AB12CD34-AB12-4D34-AB12-AB12CD34EF56"
UID71 = CANONICAL_DEVICE_UID["7_1"]
ORDER = list(LAYOUTS["7_1"])

# Must mirror FakeProvider.channelValues in the probe. Values are deliberately
# channel-distinct, within [-0.8, 0.8], with FC strongest ("centre dialogue").
CHANNEL_VALUES = [0.10, -0.20, 0.70, -0.40, 0.30, -0.30, 0.50, -0.50]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _decode(payload: bytes):
    """Big-endian stereo int16 -> float samples in [-1, 1]."""
    if len(payload) % 4:
        raise AssertionError("stereo payload is not 4-byte aligned")
    words = struct.unpack(">%dh" % (len(payload) // 2), payload)
    return [value / 32767.0 for value in words]


def _tail_stats(samples, frames_per_channel=2048):
    """Mean/max-abs over the tail of an interleaved stereo float list."""
    start = max(0, len(samples) - 2 * frames_per_channel)
    left = samples[start::2]
    right = samples[start + 1::2]
    if not left:
        raise AssertionError("empty verification tail")
    return (sum(left) / len(left), sum(right) / len(right),
            max(abs(v) for v in samples[start:]))


def _verify_continuity(capture):
    validator = capture.validator
    assert capture.process.returncode == 0, "capture process did not exit 0"
    assert capture.cleanup_complete is True, "capture cleanup was not confirmed"
    assert capture.last_error is None, "capture pump reported an error"
    assert validator.sequence > 0, "no HPCM PCM frames observed"
    assert validator.frames > 0, "no output frames observed"
    first = validator.first_source
    last = validator.last_source
    assert isinstance(first, dict) and isinstance(last, dict), "missing source metadata"
    assert first["sourceSequence"] == 0, "first source sequence was not zero"
    assert last["hostTime"] > first["hostTime"], "host clock was not monotonic"
    assert (last["sourceFrameStart"] + last["sourceFrames"]
            > first["sourceFrameStart"] + first["sourceFrames"]), "input frames regressed"
    assert validator.source_rate == 48000, "source rate was not 48 kHz"
    assert validator.timebase is not None, "timebase was never validated"
    expected_output = validator.total_input * 44100 / 48000
    assert abs(validator.frames - expected_output) <= 128, (
        "source/output rate relation violated: input=%s output=%s expected~%.1f"
        % (validator.total_input, validator.frames, expected_output))
    assert capture.ready_header["outputRate"] == 44100
    assert capture.ready_header["outputChannels"] == 8
    assert capture.ready_header["outputLayout"] == "7_1"
    assert capture.ready_header["sourceRate"] == 48000
    assert capture.ready_header["sourceChannels"] == 8
    return {
        "sequence": validator.sequence,
        "output_frames": validator.frames,
        "source_rate": validator.source_rate,
        "total_input": validator.total_input,
        "first_source": first,
        "last_source": last,
    }


async def _run_phase(exe, library, session, plan, target_frames,
                     lead_ns=120_000_000, chunk=352):
    hub = LiveHub(
        library,
        plan.routes,
        input_channels=plan.channels,
        input_capacity_frames=88_200,
        block_frames=352,
        output_capacity_blocks=4,
        stall_timeout=2.0,
    )
    capture = CaptureHostV2(exe, session, hub, UID71, "7_1", plan.process)
    tasks = []
    try:
        await capture.start()
        origin = hub.start(lead_ns)

        async def reader(output_id):
            parts, remaining = [], target_frames
            while remaining:
                count = min(chunk, remaining)
                parts.append(await hub.read(output_id, count))
                remaining -= count
            return output_id, b"".join(parts)

        tasks = [asyncio.create_task(reader(output_id)) for output_id in plan.outputs]
        payloads = dict(await asyncio.gather(*tasks))
        cleaned = await capture.stop()
        report = hub.report()
        assert cleaned, "capture stop was not clean"
        assert report["native_core_used"], "native core was never submitted"
        assert not report["group_failed"], "live group faulted"
        assert report["playback_origin_ns"] == origin, "started origin mismatch"
        return {
            "payloads": payloads,
            "report": report,
            "continuity": _verify_continuity(capture),
            "exit_code": capture.process.returncode,
        }
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if not capture.cleanup_complete:
            try:
                await capture.stop()
            except BaseException:
                pass
        await hub.stop()


async def run_synchronized(exe, library, target_frames=6144):
    plan = VirtualRoutePlan("7_1", [0, 1], "synchronized")
    result = await _run_phase(exe, library, SESSION, plan, target_frames)
    payloads = result["payloads"]
    report = result["report"]
    assert payloads[0] == payloads[1], "synchronized endpoints diverged"
    ref = list(plan.process(array.array("f", CHANNEL_VALUES)))
    ref_left, ref_right = ref[0], ref[1]

    stats = {}
    for output_id, payload in payloads.items():
        samples = _decode(payload)
        left, right, peak = _tail_stats(samples)
        assert peak <= 1.0 + 1e-9, "normalized range exceeded"
        assert abs(left - ref_left) <= 2e-3, (
            "endpoint %d left slot mismatch: got %.6f want %.6f"
            % (output_id, left, ref_left))
        assert abs(right - ref_right) <= 2e-3, (
            "endpoint %d right slot mismatch: got %.6f want %.6f"
            % (output_id, right, ref_right))
        stats[output_id] = {"left": left, "right": right, "peak": peak}

    # Centre retention: removing FC must materially change both downmix sides.
    centre_removed = [value if label != "FC" else 0.0
                      for label, value in zip(ORDER, CHANNEL_VALUES)]
    ref_no_centre = list(plan.process(array.array("f", centre_removed)))
    assert abs(ref_left - ref_no_centre[0]) > 0.05, "centre not in left downmix"
    assert abs(ref_right - ref_no_centre[1]) > 0.05, "centre not in right downmix"
    assert report["outputs"][0]["first_presentation_ns"] is not None
    return {
        "mode": plan.report()["actual_mode"],
        "discarded": plan.report()["discarded_channels"],
        "reference": {"left": ref_left, "right": ref_right},
        "stats": stats,
        "report": report,
        "continuity": result["continuity"],
    }


async def run_cinema(exe, library, target_frames=4096):
    roles = {index: label for index, label in enumerate(ORDER)}
    endpoints = list(range(8))
    plan = VirtualRoutePlan("7_1", endpoints, "cinema", roles)
    result = await _run_phase(exe, library, SESSION, plan, target_frames)
    payloads = result["payloads"]
    report = result["report"]
    ref = list(plan.process(array.array("f", CHANNEL_VALUES)))
    expected = [CHANNEL_VALUES[index] for index in range(8)]

    stats = {}
    for output_id, payload in payloads.items():
        samples = _decode(payload)
        left, right, peak = _tail_stats(samples)
        assert peak <= 1.0 + 1e-9, "normalized range exceeded"
        expect = expected[output_id]
        assert abs(left - expect) <= 2e-3, (
            "endpoint %d slot mismatch: got %.6f want %.6f" % (output_id, left, expect))
        assert abs(right - expect) <= 2e-3, (
            "endpoint %d duplicated slot mismatch" % output_id)
        assert abs(left - right) <= 2e-3, "multiplex pair differs within endpoint"
        stats[output_id] = {"role": roles[output_id], "value": left, "peak": peak}

    outputs = {item["output_id"]: item for item in report["outputs"]}
    hashes = {item["native_pcm_sha256"] for item in report["outputs"]}
    consumed = {item["consumed_pcm_sha256"] for item in report["outputs"]}
    assert len(hashes) == 8, "native PCM hashes were not endpoint-distinct"
    assert len(consumed) == 8, "consumed PCM hashes were not endpoint-distinct"
    first_presentations = {item["first_presentation_ns"] for item in report["outputs"]}
    assert len(first_presentations) == 1, "outputs lack a common presentation origin"
    assert all(item["native_frames"] > 0 for item in report["outputs"])
    assert all(item["consumed_frames"] == target_frames for item in report["outputs"])
    return {
        "mode": plan.report()["actual_mode"],
        "discarded": plan.report()["discarded_channels"],
        "roles": {str(k): v for k, v in roles.items()},
        "stats": stats,
        "report": report,
        "continuity": result["continuity"],
        "first_presentation_ns": first_presentations.pop(),
    }


async def run_eof(exe):
    """EOF path: real controller endInput must emit a correlated `stopped` and exit 0.

    This is also the direct-subprocess contract probe: it starts the real
    Swift probe without CaptureHostV2 and records the literal ready header,
    which is the evidence for any Python-side contract mismatch.
    """
    start_id = "eof-check"
    process = None
    try:
        process = await asyncio.create_subprocess_exec(
            exe, "--serve", stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=98_304)
        command = (json.dumps({
            "v": 2, "id": start_id, "command": "start",
            "params": {"session": SESSION, "deviceUID": UID71, "layout": "7_1"},
        }, allow_nan=False) + "\n").encode()
        process.stdin.write(command)
        await asyncio.wait_for(process.stdin.drain(), 1)

        async def ready_and_pcm():
            ready, pcm = None, 0
            while pcm < 3:
                frame = await read_frame_v2(process.stdout)
                kind = frame.header["kind"]
                if kind == "ready":
                    assert ready is None, "duplicate ready before EOF"
                    ready = frame.header
                elif kind == "pcm":
                    pcm += 1
                else:
                    raise AssertionError("unexpected frame before EOF: %s" % kind)
            return ready

        ready = await asyncio.wait_for(ready_and_pcm(), 20)
        assert ready, "no ready header before EOF"
        process.stdin.close()

        async def until_stopped():
            while True:
                frame = await read_frame_v2(process.stdout)
                if frame.header["kind"] == "stopped":
                    return frame.header
                if frame.header["kind"] == "error":
                    raise AssertionError("EOF produced error frame: %r" % frame.header)

        stopped = await asyncio.wait_for(until_stopped(), 20)
        assert stopped["id"] == start_id, "EOF stop was not correlated to the start id"
        assert stopped["session"] == SESSION, "EOF stop session mismatch"
        assert stopped["cleanupComplete"] is True, "EOF stop lacked cleanup evidence"
        assert stopped["drainComplete"] is False, "EOF stop claimed a drain"
        assert isinstance(stopped.get("discardedConverterTail"), bool)

        exit_code = await asyncio.wait_for(process.wait(), 5)
        assert exit_code == 0, "EOF teardown exited %r" % exit_code
        stderr = (await process.stderr.read()).decode("utf-8", "replace")
        return {
            "exit_code": exit_code,
            "stop_header": stopped,
            "ready_header": ready,
            "ready_has_nested_source": isinstance(ready.get("source"), dict),
            "stderr_tail": stderr[-2000:],
        }
    finally:
        if process is not None and process.returncode is None:
            try:
                process.kill()
                await asyncio.wait_for(process.wait(), 3)
            except (ProcessLookupError, asyncio.TimeoutError):
                pass


def production_sources(library: Path, probe: Path) -> dict:
    files = [
        ROOT / "adapters/live/capture.py",
        ROOT / "adapters/live/capture_v2.py",
        ROOT / "adapters/live/hub.py",
        ROOT / "adapters/live/routing_v2.py",
        ROOT / "adapters/live/pcm_v2.py",
        ROOT / "bindings/python/flow_core.py",
        ROOT / "platforms/macos/VirtualAudioInput/Package.swift",
        ROOT / "platforms/macos/VirtualAudioInput/Sources/VirtualCaptureHostSupport/VirtualCaptureHostController.swift",
        ROOT / "platforms/macos/VirtualAudioInput/Sources/VirtualCaptureHost/main.swift",
        ROOT / "platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/DeviceTapCapture.swift",
        ROOT / "platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/VirtualHPCMEncoder.swift",
        ROOT / "platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/VirtualPCMResampler.swift",
        ROOT / "platforms/macos/ProcessTapCapture/Sources/TapCaptureHostSupport/BoundedPipeWriter.swift",
    ]
    hashes = {str(path.relative_to(ROOT)): _sha256(path) for path in files}
    hashes["native_core_dylib"] = _sha256(library)
    hashes["managed_host_probe_binary"] = _sha256(probe)
    return hashes


async def main_async(args):
    probe = Path(args.probe).resolve()
    library = Path(args.library).resolve()
    if not probe.is_file() or not os.access(probe, os.X_OK):
        raise SystemExit("probe binary missing/not executable: %s" % probe)
    if not library.is_file():
        raise SystemExit("native core library missing: %s" % library)

    report = {
        "gate": "015 managed Swift host -> Python -> native core",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "session": SESSION,
        "probe": str(probe),
        "library": str(library),
        "acoustic_sync_verified": False,
        "tcc_claimed": False,
        "source_sha256": production_sources(library, probe),
        "status": "running",
    }

    async def attempt(section, coro):
        try:
            report[section] = await coro
            report[section]["status"] = "ok"
            print("PASS", section)
            return True
        except BaseException as exc:
            report[section] = {
                "status": "blocked" if isinstance(exc, Exception) else "failed",
                "exception_type": type(exc).__name__,
                "exception": " ".join(str(exc).split())[:512],
            }
            print("BLOCKED", section, "-", type(exc).__name__, str(exc)[:200])
            return False

    # Direct subprocess first: it needs neither CaptureHostV2 nor the native
    # core, and it captures the literal ready header the real Swift host
    # emits, which is the evidence for any Python-side contract mismatch.
    eof_ok = await attempt("eof", run_eof(probe))
    sync_ok = await attempt("synchronized", run_synchronized(probe, library))
    cinema_ok = await attempt("cinema", run_cinema(probe, library))

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = out_dir / "managed-host-report.json"
    report["status"] = "ok" if (eof_ok and sync_ok and cinema_ok) else "blocked"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not (eof_ok and sync_ok and cinema_ok):
        print("BLOCKED: report saved but the gate did not fully pass")
    else:
        print("PASS 015 managed-host integration")
    print("report:", report_path)
    if report["synchronized"].get("status") == "ok":
        print("synchronized discarded:", report["synchronized"]["discarded"])
    if report["cinema"].get("status") == "ok":
        print("cinema roles:", report["cinema"]["roles"])
        print("cinema distinct hashes:", len({o["native_pcm_sha256"]
                                              for o in report["cinema"]["report"]["outputs"]}))
    if report["eof"].get("status") == "ok":
        print("eof exit:", report["eof"]["exit_code"])
    if report["status"] != "ok":
        raise SystemExit(1)
    return report_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", default=os.environ.get(
        "MANAGED_HOST_PROBE",
        str(ROOT / "tests/virtual_audio/managed_host_probe/.build/debug/ManagedHostProbe")))
    parser.add_argument("--library", default=os.environ.get(
        "FLOW_CORE_LIBRARY",
        "/Users/lvzhipeng/Developer/HomePodSpatialRouter/core-m2-validation/build/core/libflow_bridge.dylib"))
    parser.add_argument("--out-dir", default=os.environ.get(
        "MANAGED_HOST_OUT", str(ROOT / "tests/virtual_audio/managed_host_probe/out")))
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
