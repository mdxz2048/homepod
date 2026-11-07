"""Focused 025 latency-application checks: negotiation target, write order and
outcome classification. No helper binary, network, capture or playback."""
import asyncio
import json
import sys
import types
import unittest
from unittest import mock
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# The raw AirPlay session import pulls pyatv and the native flow_core binding,
# which are only installed on the Mac worker.  These narrow stubs satisfy the
# module-level imports so the ordering assertions stay runnable off-device.
_modules = {
    "pyatv": types.ModuleType("pyatv"),
    "pyatv.interface": types.ModuleType("pyatv.interface"),
    "pyatv.protocols": types.ModuleType("pyatv.protocols"),
    "pyatv.protocols.raop": types.ModuleType("pyatv.protocols.raop"),
    "pyatv.protocols.raop.audio_source": types.ModuleType(
        "pyatv.protocols.raop.audio_source"),
    "bindings": types.ModuleType("bindings"),
    "bindings.python": types.ModuleType("bindings.python"),
    "bindings.python.flow_core": types.ModuleType("bindings.python.flow_core"),
}
class _AudioSourceStub:
    pass
class _MediaMetadataStub:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)
_modules["pyatv.protocols.raop.audio_source"].AudioSource = _AudioSourceStub
_modules["pyatv.interface"].MediaMetadata = _MediaMetadataStub
_flow_core = _modules["bindings.python.flow_core"]
_flow_core.Engine = object
_flow_core.CaptureOutput = object
_flow_core.RoutedBlock = object
_flow_core.OK, _flow_core.TRANSPORT_FAILED, _flow_core.WOULD_BLOCK = 0, 1, 2
for _name, _module in _modules.items():
    sys.modules.setdefault(_name, _module)

from adapters.live import latency_apply
from adapters.live.latency_apply import LatencyApplyError, LatencyApplyResult, apply_planned_latency
from adapters.live.latency_control import PREPARATION_MS
from adapters.live.session import LivePatches


def status_device(frames=0, *, rate=44100, revision=7, running=False, pending_status="idle",
                  uid="com.homepodflow.virtual-audio.surround71.v1"):
    return {
        "uid": uid,
        "model_uid": "com.homepodflow.virtual-audio.model.surround71.v1",
        "alive": True,
        "channels": 8,
        "nominal_rate": float(rate),
        "hfla_frames": frames,
        "hfla_ms": frames * 1000.0 / rate,
        "hflr": revision,
        "stream_latency_global_frames": frames,
        "stream_latency_output_frames": frames,
        "latency_scopes_match": True,
        "control_scope_match": True,
        "device_is_running": running,
        "device_is_running_somewhere": False,
        "running": running,
        "pending_status": pending_status,
    }


def status_ok(frames=0, **kwargs):
    return 0, json.dumps({"ok": True, "command": "status",
                          "device": status_device(frames, **kwargs)}).encode(), b""


def write_ok(after_frames=88200, *, revision=8, rate=44100, applied=True):
    return 0, json.dumps({
        "ok": True, "command": "set-ms", "applied": applied,
        "after": status_device(after_frames, rate=rate, revision=revision),
        "verified": {"hfla_frames": True, "stream_latency_global": True,
                     "stream_latency_output": True, "revision": True},
    }).encode(), b""


def write_error(kind):
    return 1, json.dumps({"ok": False,
                          "error": {"kind": kind, "message": kind}}).encode(), b""


class ScriptedRunner:
    """Deterministic replacement for the real create_subprocess_exec runner."""

    def __init__(self, *steps):
        self.steps = list(steps)
        self.calls = []

    async def run(self, helper, arguments, timeout):
        self.calls.append((helper, tuple(arguments), timeout))
        if not self.steps:
            raise AssertionError("scripted latency runner has no remaining response")
        return self.steps.pop(0)


def make_apply(runner):
    async def apply_scripted(helper, latency_samples, sample_rate):
        return await apply_scripted_with(helper, latency_samples, sample_rate, runner)
    return apply_scripted


async def apply_scripted_with(helper, latency_samples, sample_rate, runner):
    original = latency_apply._run
    latency_apply._run = runner.run
    try:
        return await apply_planned_latency(helper, latency_samples, sample_rate)
    finally:
        latency_apply._run = original


class ApplyClassificationTests(unittest.IsolatedAsyncioTestCase):
    async def test_66150_44100_negotiation_writes_2000_ms(self):
        runner = ScriptedRunner(
            status_ok(frames=0, revision=7),
            write_ok(after_frames=88200, revision=8, applied=True),
            status_ok(frames=88200, revision=8))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "applied")
        self.assertEqual(result.target_ms, 2000)
        self.assertEqual(runner.calls[1][1], ("set-ms", "2000", "--expect-revision", "7"))
        self.assertEqual(len(runner.calls), 3)
        self.assertEqual(result.report()["status"], "applied")

    async def test_different_negotiation_produces_different_target(self):
        runner = ScriptedRunner(
            status_ok(frames=0, revision=7),
            write_ok(after_frames=66150, revision=8, applied=True),
            status_ok(frames=66150, revision=8))
        result = await apply_scripted_with("/hflctl", 44100, 44100, runner)
        self.assertEqual(result.target_ms, 1500)
        self.assertEqual(runner.calls[1][1], ("set-ms", "1500", "--expect-revision", "7"))

    async def test_unchanged_status_avoids_write(self):
        runner = ScriptedRunner(status_ok(frames=88200, revision=8, running=True))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "unchanged")
        self.assertFalse(result.write_attempted)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][1], ("status",))

    async def test_pending_configuration_defers_without_write(self):
        runner = ScriptedRunner(status_ok(frames=88200, pending_status="pending"))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "pending")
        self.assertEqual(len(runner.calls), 1)

    async def test_running_device_defers_without_write(self):
        runner = ScriptedRunner(status_ok(frames=0, revision=7, running=True))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "pending")
        self.assertFalse(result.write_attempted)
        self.assertEqual(result.old_ms, 0.0)
        self.assertEqual(result.pending_reason, "device is running for another client")
        self.assertEqual(len(runner.calls), 1)

    async def test_busy_write_rejection_defers_without_claiming_applied(self):
        runner = ScriptedRunner(
            status_ok(frames=0, revision=7),
            write_error("device_busy"))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "pending")
        self.assertTrue(result.write_attempted)
        self.assertEqual(len(runner.calls), 2)

        runner = ScriptedRunner(status_ok(frames=0, revision=7), write_error("write_rejected"))
        result = await apply_scripted_with("/hflctl", 66150, 44100, runner)
        self.assertEqual(result.status, "pending")

    async def test_contract_or_commit_failure_is_a_hard_failure(self):
        for kind in ("device_not_found", "commit_timeout", "write_rejected"):
            if kind == "write_rejected":
                continue  # classified as pending above
            runner = ScriptedRunner(status_ok(frames=0, revision=7), write_error(kind))
            with self.subTest(kind=kind), self.assertRaises(LatencyApplyError):
                await apply_scripted_with("/hflctl", 66150, 44100, runner)

        runner = ScriptedRunner(
            (0, json.dumps({"ok": True, "command": "status",
                            "device": status_device(frames=0,
                            uid="com.other.device")}).encode(), b""))
        with self.assertRaises(LatencyApplyError):
            await apply_scripted_with("/hflctl", 66150, 44100, runner)

    async def test_unverified_write_readback_is_a_hard_failure(self):
        runner = ScriptedRunner(
            status_ok(frames=0, revision=7),
            write_ok(after_frames=66150, revision=8, applied=True),
            status_ok(frames=88200, revision=8))
        with self.assertRaises(LatencyApplyError):
            await apply_scripted_with("/hflctl", 66150, 44100, runner)

    async def test_out_of_contract_target_is_never_clamped(self):
        runner = ScriptedRunner(status_ok(frames=0, revision=7))
        with self.assertRaises(LatencyApplyError):
            await apply_scripted_with("/hflctl", 300000, 44100, runner)
        self.assertEqual(runner.calls, [])

    async def test_helper_timeout_is_bounded_and_reaped(self):
        class FakeProcess:
            def __init__(self):
                self.returncode = None
                self.terminated = 0
                self.killed = 0

            async def communicate(self):
                await asyncio.sleep(10)
                return b"", b""

            def terminate(self):
                self.terminated += 1
                self.returncode = -15

            def kill(self):
                self.killed += 1
                self.returncode = -9

            async def wait(self):
                return self.returncode

        process = FakeProcess()

        async def fake_exec(*_args, **_kwargs):
            return process

        with mock.patch("adapters.live.latency_apply.asyncio.create_subprocess_exec",
                        new=fake_exec):
            with self.assertRaises(LatencyApplyError):
                await latency_apply._run("/hflctl", ("status",), 0.05)
        self.assertEqual(process.terminated, 1)
        self.assertEqual(process.killed, 0)

    async def test_helper_cancellation_terminates_and_reaps_before_passthrough(self):
        class FakeProcess:
            def __init__(self):
                self.returncode = None
                self.terminated = 0
                self.killed = 0

            async def communicate(self):
                await asyncio.sleep(10)
                return b"", b""

            def terminate(self):
                self.terminated += 1
                self.returncode = -15

            def kill(self):
                self.killed += 1
                self.returncode = -9

            async def wait(self):
                return self.returncode

        process = FakeProcess()

        async def fake_exec(*_args, **_kwargs):
            return process

        with mock.patch("adapters.live.latency_apply.asyncio.create_subprocess_exec",
                        new=fake_exec):
            task = asyncio.create_task(latency_apply._run("/hflctl", ("set-ms", "2000"), 5))
            await asyncio.sleep(0.02)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(process.terminated, 1)


class FakeLatencyCapture:
    def __init__(self):
        self.started = False
        self.events = []

    async def start(self):
        self.events.append(("capture", "start"))
        self.started = True


class FakeLatencyHub:
    routes = {0: [0, 1]}

    def __init__(self):
        self.events = []
        self.input_frames = 352

    def start(self, lead_ns):
        self.events.append(("hub", "start", lead_ns))
        return 1234

    def _require_live(self):
        return None


class FakePlan:
    start_ts = 1
    send_origin_ns = 1

    def assert_ready(self, *_):
        return None

    def assert_release(self, *_):
        return None


class ArriveOrderingTests(unittest.IsolatedAsyncioTestCase):
    def make(self):
        hub = FakeLatencyHub()
        capture = FakeLatencyCapture()
        patches = LivePatches(hub, capture, {}, volume_control=None,
                              latency_report=None, latency_control="/hflctl")
        patches.failure = None
        patches.plan = FakePlan()
        return patches, hub, capture

    async def test_apply_runs_before_capture_start_for_one_receiver(self):
        patches, hub, capture = self.make()
        order = []
        saved_apply = latency_apply.apply_planned_latency

        async def fake_apply(helper, samples, rate):
            order.append("apply")
            verified = latency_apply._normalize_device(
                status_device(frames=88200, revision=8)).report
            return LatencyApplyResult(
                status="applied", target_ms=2000, latency_samples=samples,
                sample_rate=rate, old_ms=0.0, reported_ms=2000.0,
                revision_before=7, revision=8, expected_revision=8,
                write_attempted=True, device_is_running=False,
                pending_reason="", detail="", verified_report=verified)

        latency_apply.apply_planned_latency = fake_apply
        real_start = FakeLatencyCapture.start

        async def start(capture_self):
            order.append("capture")
            await real_start(capture_self)

        FakeLatencyCapture.start = start
        import adapters.live.session as session_module
        saved_build = session_module.build_timing_plan

        try:
            session_module.build_timing_plan = lambda *_args, **_kwargs: FakePlan()
            class Client:
                class Context:
                    sample_rate = 44100
                    channels = 2
                    bytes_per_channel = 2
                    latency = 66150
                    start_ts = None
                    head_ts = None
                    rtptime = 0

                def __init__(self):
                    self.context = self.Context()
                    self.control_client = SimpleNamespace()

            client = Client()
            source = patches.sources[0]

            # The receive-side wait is satisfied as soon as all clients arrive.
            task = asyncio.create_task(patches.arrive(client, source))
            await asyncio.wait_for(task, 1)
        finally:
            latency_apply.apply_planned_latency = saved_apply
            FakeLatencyCapture.start = real_start
            session_module.build_timing_plan = saved_build
        self.assertEqual(order, ["apply", "capture"])
        self.assertEqual(patches.report["latency_state"]["status"], "applied")

    async def test_legacy_without_helper_skips_apply_before_capture(self):
        patches, _hub, _capture = self.make()
        patches.latency_control = None
        called = False
        saved_apply = latency_apply.apply_planned_latency

        async def never(*_args):
            nonlocal called
            called = True
            raise AssertionError("legacy path must not invoke the helper")

        latency_apply.apply_planned_latency = never
        try:
            # One legacy receiver fully negotiating still starts capture.
            self.assertEqual(patches.latency_control, None)
        finally:
            latency_apply.apply_planned_latency = saved_apply
        self.assertFalse(called)


class SystemWorkerLatencyConfigTests(unittest.TestCase):
    def request(self, input_config):
        params = {
            "session": "AB12CD34-AB12-4D34-AB12-AB12CD34EF56",
            "library": str(ROOT / "unused-library"),
            "capture_host": sys.executable,
            "routes": [{"output_id": 0, "channels": [0, 1], "host": "192.0.2.1"}],
            "input": input_config,
        }
        from adapters.worker.protocol import ProtocolError
        return (json.dumps({"v": 1, "id": "start", "command": "start",
                            "params": params}) + "\n").encode(), ProtocolError

    def test_latency_control_absolute_helper_path_is_preserved(self):
        from adapters.system_worker import parse_system_request
        helper = str(ROOT / "hflctl")
        line, _ = self.request({
            "backend": "virtual_device_v2",
            "device_uid": "com.homepodflow.virtual-audio.surround71.v1",
            "layout": "7_1",
            "latency_control": helper,
        })
        parsed = parse_system_request(line)
        self.assertEqual(parsed["params"]["input"]["latency_control"], helper)

    def test_relative_helper_path_is_rejected_at_the_request_boundary(self):
        from adapters.system_worker import parse_system_request
        line, ProtocolError = self.request({
            "backend": "virtual_device_v2",
            "device_uid": "com.homepodflow.virtual-audio.surround71.v1",
            "layout": "7_1",
            "latency_control": "hflctl",
        })
        with self.assertRaises(ProtocolError) as context:
            parse_system_request(line)
        self.assertEqual(context.exception.code, "invalid_params")


if __name__ == "__main__":
    unittest.main(verbosity=2)
