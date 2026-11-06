"""Explicit finite real-Tap check; no audio file, network or speaker playback.

Usage: python tests/mac_live_capture_check.py --capture /abs/TapCaptureHost
Only aggregate counts/energy/timestamps are printed; PCM is never persisted.
"""
import argparse
import asyncio
import json
import math
from pathlib import Path
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from adapters.live.capture import CaptureHost


class Meter:
    def __init__(self):
        self.first_block = asyncio.Event()
        self.frames = self.nonzero = 0
        self.peak = self.sum_squares = 0
        self.failure = None

    async def push(self, samples):
        self.frames += len(samples) // 2
        self.nonzero += sum(abs(value) > 1e-7 for value in samples)
        self.peak = max(self.peak, max(abs(value) for value in samples))
        self.sum_squares += sum(value * value for value in samples)
        self.first_block.set()

    async def fail(self, error):
        self.failure = type(error).__name__
        self.first_block.set()

    def _require_live(self):
        if self.failure:
            raise RuntimeError(self.failure)


async def check(path, test_sound=False, exclude_pids=(), permission_wait=20):
    meter = Meter()
    capture = CaptureHost(path, str(uuid.uuid4()), meter, exclude_pids)
    errors = []
    sound_stop = asyncio.Event()
    sound_runs = 0
    async def play_test_sound():
        nonlocal sound_runs
        while capture.ready is None and not sound_stop.is_set():
            await asyncio.sleep(.01)
        if sound_stop.is_set():
            return
        await asyncio.shield(capture.ready)
        while not sound_stop.is_set():
            process = await asyncio.create_subprocess_exec("/usr/bin/afplay", "-v", "0.05",
                "/System/Library/Sounds/Glass.aiff")
            sound_runs += 1
            waiting = asyncio.create_task(process.wait())
            stop = asyncio.create_task(sound_stop.wait())
            try:
                done, _ = await asyncio.wait([waiting, stop], timeout=3, return_when=asyncio.FIRST_COMPLETED)
                if waiting not in done and process.returncode is None:
                    process.terminate()
                await waiting
                if process.returncode not in (0, -15):
                    raise RuntimeError("local test sound failed")
            finally:
                stop.cancel()
                await asyncio.gather(stop, return_exceptions=True)
    sound = asyncio.create_task(play_test_sound()) if test_sound else None
    try:
        await asyncio.wait_for(capture.start(), permission_wait)
        await asyncio.sleep(3)
    except Exception as error:
        errors.append(f"{type(error).__name__}: {error}")
    finally:
        sound_stop.set()
        if sound:
            result = await asyncio.gather(sound, return_exceptions=True)
            if isinstance(result[0], BaseException):
                errors.append("test_sound_failed: " + type(result[0]).__name__)
        clean = await capture.stop()
    report = capture.report()
    report.update(errors=errors, test_sound_runs=sound_runs, nonzero_samples=meter.nonzero, peak=meter.peak,
                  rms=math.sqrt(meter.sum_squares / max(1, meter.frames * 2)),
                  capture_verified=not errors and clean and meter.frames > 0 and meter.nonzero > 0)
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0 if report["capture_verified"] else 3


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, help="Explicitly start real system-audio capture")
    parser.add_argument("--test-sound", action="store_true", help="Explicitly play a quiet local macOS test sound")
    parser.add_argument("--exclude-pid", type=int, action="append", default=[])
    parser.add_argument("--permission-wait", type=int, choices=range(1, 91), default=20)
    args = parser.parse_args()
    sys.exit(asyncio.run(check(args.capture, args.test_sound, args.exclude_pid, args.permission_wait)))
