"""Managed worker protocol tests. Injected runners test control, not native audio."""
import asyncio
import json
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
from unittest.mock import patch

from adapters.worker.protocol import MAX_LINE_BYTES, ProtocolError, parse_request
from adapters.worker.server import WorkerServer as RealWorkerServer

ROOT = Path(__file__).resolve().parents[1]
SESSION_A = "AABBCCDD-1122-3344-5566-778899AABBCC"
SESSION_B = "12345678-1122-3344-5566-778899AABBCC"


def request(request_id, command, params=None):
    return json.dumps({"v": 1, "id": request_id, "command": command, "params": params or {}}) + "\n"


def params(session=SESSION_A):
    return {"session": session, "library": str(ROOT / "unused-test-library"),
            "wav": str(ROOT / "unused-test.wav"), "execution": "offline",
            "routes": [{"output_id": 0, "channels": [0, 0]}]}


def certify(report):
    report.update(cleanup_complete=True, input_closed=True, hub_stopped=True, native_core_used=True)


async def waiting_runner(_params, report):
    try:
        await asyncio.Event().wait()
    finally:
        certify(report)


async def virtual_preflight(_params):
    return {"sample_rate": 44100, "channels": 1, "frames": 44100, "duration_seconds": 1}


def WorkerServer(*args, **kwargs):
    kwargs.setdefault("preflight", virtual_preflight)
    return RealWorkerServer(*args, **kwargs)


HARNESS = r'''
import asyncio
import adapters.worker.__main__ as entry
from adapters.worker.server import WorkerServer
async def runner(params, report):
    try:
        print("library diagnostic only", flush=True)
        await asyncio.Event().wait()
    finally:
        report.update(cleanup_complete=True,input_closed=True,hub_stopped=True,native_core_used=True)
async def preflight(params):
    return {"sample_rate":44100,"channels":1,"frames":44100,"duration_seconds":1}
entry.WorkerServer=lambda emit:WorkerServer(emit,runner=runner,preflight=preflight,stop_timeout=.5)
raise SystemExit(entry.main())
'''


class WorkerProtocolTests(unittest.TestCase):
    def test_validation_rejects_nan_unknown_fields_and_noncanonical_inputs(self):
        bad = [b"\xff\n", "{}\n", request("a", "missing"), request("a", "hello", {"extra": 1}),
               request("a", "start", {**params(), "volume": float("nan")}),
               request("a", "start", {**params(), "library": "relative"}),
               request("a", "start", {**params(), "routes": [{"output_id": 0, "channels": [0, 0], "host": "127.0.0.1"}]}),
               request("a", "start", {**params(), "execution": "airplay"}),
               request("a", "start", {**params(), "session": "not-a-uuid"}),
               request("a", "hello").replace('"v": 1', '"v": 1e999'),
               request("a", "hello").replace('"a"', '"\\ud800"'),
               "x" * (MAX_LINE_BYTES + 1)]
        for line in bad:
            with self.subTest(line=str(line)[:80]), self.assertRaises(ProtocolError):
                parse_request(line)
        self.assertEqual(parse_request(request("hello", "hello"))["command"], "hello")

    def test_hello_is_honest_and_does_not_call_runner(self):
        async def run():
            events = []
            async def forbidden(*_):
                self.fail("hello must not load a native library")
            server = WorkerServer(events.append, runner=forbidden)
            await server.handle_line(request("hello", "hello"))
            self.assertEqual(events[-1]["event"], "result")
            self.assertFalse(events[-1]["payload"]["capabilities"]["capture"])
            self.assertEqual(events[-1]["payload"]["core_abi_version"], 1)
        asyncio.run(run())

    def test_duplicate_active_id_does_not_terminal_or_cancel_original(self):
        async def run():
            events = []
            server = WorkerServer(events.append, runner=waiting_runner)
            await server.handle_line(request("start", "start", params()))
            await server.handle_line(request("start", "hello"))
            duplicate = events[-1]
            self.assertIsNone(duplicate["id"])
            self.assertEqual(duplicate["payload"]["code"], "duplicate_id")
            self.assertIsNotNone(server.active)
            await server.eof()
            terminals = [event for event in events if event["id"] == "start" and event["event"] in ("result", "error")]
            self.assertEqual(len(terminals), 1)
            self.assertEqual(terminals[0]["payload"]["state"], "stopped")
        asyncio.run(run())

    def test_stop_stale_session_and_restart_after_confirmed_cleanup(self):
        async def run():
            events = []
            server = WorkerServer(events.append, runner=waiting_runner)
            await server.handle_line(request("start1", "start", params()))
            await server.handle_line(request("stale", "stop", {"session": SESSION_B}))
            self.assertEqual(events[-1]["payload"]["code"], "stale_session")
            self.assertEqual(server.active.session_id, SESSION_A)
            await server.handle_line(request("stop1", "stop", {"session": SESSION_A}))
            self.assertTrue(events[-1]["payload"]["cleanup_complete"])
            await server.handle_line(request("start2", "start", params(SESSION_B)))
            self.assertEqual(server.active.session_id, SESSION_B)
            await server.handle_line(request("stop2", "stop", {"session": SESSION_B}))
            self.assertFalse(server.poisoned)
            self.assertIsNone(server.active)
        asyncio.run(run())

    def test_busy_inspect_and_scan_do_not_disturb_playback(self):
        async def run():
            events = []
            server = WorkerServer(events.append, runner=waiting_runner)
            await server.handle_line(request("start", "start", params()))
            for command, value in (("inspect", {"wav": params()["wav"]}), ("scan", {}), ("start", params(SESSION_B))):
                await server.handle_line(request("busy-" + command, command, value))
                self.assertEqual(events[-1]["payload"]["code"], "busy")
            await server.eof()
        asyncio.run(run())

    def test_cleanup_uncertainty_poison_prevents_another_session(self):
        async def run():
            events = []
            async def unclean(_params, report):
                report.update(cleanup_complete=False, input_closed=True, hub_stopped=True)
                raise RuntimeError("sensitive details must not be echoed")
            server = WorkerServer(events.append, runner=unclean)
            await server.handle_line(request("start1", "start", params()))
            await asyncio.sleep(0)
            if server.active:
                await server.active.task
            self.assertTrue(server.poisoned)
            self.assertEqual(events[-1]["payload"]["code"], "cleanup_failed")
            self.assertNotIn("sensitive", json.dumps(events))
            await server.handle_line(request("start2", "start", params(SESSION_B)))
            self.assertEqual(events[-1]["payload"]["code"], "worker_poisoned")
        asyncio.run(run())

    def test_runner_failure_with_cleanup_is_terminal_and_reusable(self):
        async def run():
            events = []
            async def failed(_params, report):
                certify(report)
                raise ValueError("private exception detail")
            server = WorkerServer(events.append, runner=failed)
            await server.handle_line(request("start", "start", params()))
            if server.active:
                await server.active.task
            self.assertEqual(events[-1]["payload"]["code"], "operation_failed")
            self.assertFalse(server.poisoned)
            self.assertNotIn("private exception", json.dumps(events))
        asyncio.run(run())

    def test_offline_completion_does_not_invent_streaming_state(self):
        async def run():
            events = []
            async def completed(_params, report):
                certify(report)
                report["playback_origin_ns"] = 123
            server = WorkerServer(events.append, runner=completed)
            await server.handle_line(request("start", "start", params()))
            if server.active:
                await server.active.task
            states = [event["payload"]["state"] for event in events if event["event"] == "state"]
            self.assertEqual(states, ["preparing", "completed"])
            self.assertTrue(events[-1]["payload"]["cleanup_complete"])
        asyncio.run(run())

    def test_id_limit_is_bounded_but_shutdown_still_available(self):
        async def run():
            events = []
            server = WorkerServer(events.append, id_limit=2)
            for index in range(3):
                await server.handle_line(request(str(index), "hello"))
            self.assertEqual(events[-1]["payload"]["code"], "resource_limit")
            self.assertEqual(len(server.ids.values), 2)
            await server.handle_line(request("shutdown", "shutdown"))
            self.assertTrue(events[-1]["payload"]["cleanup_complete"])
        asyncio.run(run())

    def test_production_preflight_rejects_missing_files_before_accepted(self):
        async def run():
            events = []
            server = RealWorkerServer(events.append, runner=waiting_runner)
            await server.handle_line(request("start", "start", params()))
            self.assertEqual([event["event"] for event in events], ["error"])
            self.assertEqual(events[-1]["payload"]["code"], "invalid_params")
            self.assertIsNone(server.active)
        asyncio.run(run())

    def test_completed_session_uuid_is_never_reused(self):
        async def run():
            events = []
            server = WorkerServer(events.append, runner=waiting_runner)
            await server.handle_line(request("start", "start", params()))
            await server.handle_line(request("stop", "stop", {"session": SESSION_A}))
            await server.handle_line(request("reuse", "start", params()))
            self.assertEqual(events[-1]["payload"]["code"], "stale_session")
            self.assertIsNone(server.active)
        asyncio.run(run())

    def test_stop_during_terminal_finalization_does_not_cancel_cleanup_reporting(self):
        async def run():
            events = []
            async def completed(_params, report):
                certify(report)
            server = WorkerServer(events.append, runner=completed)
            await server.handle_line(request("start", "start", params()))
            await server.handle_line(request("stop", "stop", {"session": SESSION_A}))
            self.assertIsNone(server.active)
            self.assertTrue(events[-1]["payload"]["cleanup_complete"])
            terminals = [event for event in events if event["id"] == "start" and event["event"] in ("result", "error")]
            self.assertEqual(len(terminals), 1)
        asyncio.run(run())

    def test_related_errors_keep_valid_session_correlation(self):
        async def run():
            events = []
            server = WorkerServer(events.append)
            invalid = {**params(), "routes": [{"output_id": 0, "channels": [-1, 0]}]}
            await server.handle_line(request("invalid-route", "start", invalid))
            self.assertEqual(events[-1]["session"], SESSION_A)
            server.poisoned = True
            await server.handle_line(request("poison", "start", params()))
            self.assertEqual(events[-1]["session"], SESSION_A)
            limited = WorkerServer(events.append, id_limit=1)
            await limited.handle_line(request("hello", "hello"))
            await limited.handle_line(request("limited", "start", params()))
            self.assertEqual(events[-1]["payload"]["code"], "resource_limit")
            self.assertEqual(events[-1]["session"], SESSION_A)
        asyncio.run(run())

    def test_native_runner_never_manufactures_missing_hub_stop_evidence(self):
        from adapters.worker.runner import RunReport, native_runner
        class Reader:
            channels = 1
            closed = False
            def close(self):
                self.closed = True
        async def incomplete(*_args, report, **_kwargs):
            report.update(cleanup_complete=True, input_closed=True)
            raise OSError("hub.stop failed before its final report")
        async def run():
            report = RunReport()
            with patch("adapters.airplay_pyatv.streaming.WavReader", return_value=Reader()), \
                 patch("adapters.airplay_pyatv.streaming.stream_dry_run", side_effect=incomplete):
                with self.assertRaises(OSError):
                    await native_runner(params(), report)
            self.assertNotIn("hub_stopped", report)
            self.assertFalse(RealWorkerServer.clean(report))
        asyncio.run(run())

    def process(self, injected=False):
        command = [sys.executable, "-u", "-c", HARNESS] if injected else [sys.executable, "-u", "-m", "adapters.worker"]
        process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def finish(self, process, timeout=5):
        process.wait(timeout=timeout)
        stdout, stderr = process.stdout.read(), process.stderr.read()
        process.stdout.close()
        process.stderr.close()
        events = [json.loads(line) for line in stdout.decode("utf-8").splitlines()]
        self.assertTrue(all(event["v"] == 1 for event in events))
        return events, stderr.decode("utf-8")

    def test_subprocess_shutdown_exits_even_when_stdin_stays_open(self):
        process = self.process()
        process.stdin.write((request("hello", "hello") + request("shutdown", "shutdown")).encode())
        process.stdin.flush()
        events, _stderr = self.finish(process)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(events[-1]["payload"]["state"], "shutdown")
        self.assertFalse(process.stdin.closed)
        process.stdin.close()

    def test_subprocess_stop_then_restart_and_json_stdout_only(self):
        process = self.process(injected=True)
        messages = [request("start1", "start", params()), request("stop1", "stop", {"session": SESSION_A}),
                    request("start2", "start", params(SESSION_B)), request("stop2", "stop", {"session": SESSION_B}),
                    request("shutdown", "shutdown")]
        process.stdin.write("".join(messages).encode())
        process.stdin.flush()
        events, stderr = self.finish(process)
        self.assertEqual(process.returncode, 0)
        self.assertIn("library diagnostic only", stderr)
        for request_id in ("start1", "start2", "stop1", "stop2", "shutdown"):
            terminal = [event for event in events if event["id"] == request_id and event["event"] in ("result", "error")]
            self.assertEqual(len(terminal), 1)
            self.assertEqual(terminal[0]["event"], "result")
            self.assertTrue(terminal[0]["payload"]["cleanup_complete"])
        process.stdin.close()

    def test_subprocess_eof_cleans_an_active_session(self):
        process = self.process(injected=True)
        process.stdin.write(request("start", "start", params()).encode())
        process.stdin.close()
        events, _stderr = self.finish(process)
        terminal = [event for event in events if event["id"] == "start" and event["event"] == "result"]
        self.assertEqual(process.returncode, 0)
        self.assertEqual(terminal[-1]["payload"]["state"], "stopped")
        self.assertTrue(terminal[-1]["payload"]["cleanup_complete"])

    def test_subprocess_bad_line_and_oversize_recover_to_valid_request(self):
        process = self.process()
        process.stdin.write(b"not-json\n" + b"x" * (MAX_LINE_BYTES + 2) + b"\n"
                            + (request("hello", "hello") + request("shutdown", "shutdown")).encode())
        process.stdin.flush()
        events, _stderr = self.finish(process)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(sum(event["event"] == "error" for event in events), 2)
        self.assertEqual(events[-1]["payload"]["state"], "shutdown")
        process.stdin.close()

    def test_subprocess_eof_without_lf_never_executes_final_request(self):
        process = self.process(injected=True)
        process.stdin.write(request("start", "start", params()).rstrip("\n").encode())
        process.stdin.close()
        events, stderr = self.finish(process)
        self.assertEqual(process.returncode, 0)
        self.assertEqual([event["event"] for event in events], ["error"])
        self.assertNotIn("library diagnostic only", stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
