"""HPCM v2 virtual-input integration: bounded capture, routing and request parse."""
import array
import asyncio
import json
import math
import os
from pathlib import Path
import struct
import sys
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from adapters.live.capture_v2 import CaptureHostV2
from adapters.live.hub import LiveFailure, LiveHub
from adapters.live.pcm_v2 import LAYOUTS, PCMV2Error, PCMV2Validator
from adapters.live.routing_v2 import VirtualRoutePlan
from adapters.system_worker import parse_system_request
from adapters.worker.protocol import ProtocolError
from adapters.airplay_pyatv.render import pcm16be

SESSION = "AB12CD34-AB12-4D34-AB12-AB12CD34EF56"
UID71 = "com.homepodflow.virtual-audio.surround71.v1"
ORDER = list(LAYOUTS["7_1"])


def wire(header, payload=b""):
    raw = json.dumps(header, allow_nan=False, separators=(",", ":")).encode()
    return struct.pack("<4sII", b"HPCM", len(raw), len(payload)) + raw + payload


def control(kind, correlation, session=SESSION, **extra):
    header = {"v": 2, "id": correlation, "session": session, "kind": kind}
    header.update(extra)
    return header


def ready(correlation, **extra):
    header = control("ready", correlation, outputRate=44100, outputChannels=8,
                     outputLayout="7_1", deviceUID=UID71,
                     sourceRate=48000, sourceChannels=8)
    header.update(extra)
    return header


def stopped(correlation, **extra):
    header = control("stopped", correlation, cleanupComplete=True,
                     drainComplete=False, discardedConverterTail=True)
    header.update(extra)
    return header


def pcm_header(correlation, sequence=0, first=0, frames=2, source_frames=2):
    source_start = sequence * source_frames
    host = 123_456_789 + source_start
    source = {
        "sourceRate": 48000, "sourceChannels": 8, "sourceLayout": "7_1",
        "sourceChannelOrder": list(ORDER),
        "sourceLayoutAuthority": "decoder", "sourceOrigin": "decoder",
        "sourceLayoutVerified": True, "nativeClaim": True,
        "upstreamTransform": "none_known", "evidence": "integration fixture",
        "sourceFrameStart": source_start, "sourceFrames": source_frames,
        "sourceSequence": sequence, "hostTime": host, "sampleTime": "0.0",
        "flags": 3, "nowHostTime": host + 1000, "nowSampleTime": "0.0",
        "nowFlags": 3, "timebaseNumerator": 1_000_000_000,
        "timebaseDenominator": 48000, "droppedBlocksBefore": 0,
    }
    container = {"deviceUID": UID71, "channels": 8, "layout": "7_1",
                 "channelOrder": list(ORDER), "authority": "device",
                 "verified": True}
    return {"v": 2, "id": correlation, "session": SESSION, "kind": "pcm",
            "sequence": sequence, "outputRate": 44100, "outputChannels": 8,
            "outputLayout": "7_1", "outputChannelOrder": list(ORDER),
            "outputFrameStart": first, "outputFrames": frames,
            "container": container, "source": source,
            "captureTransform": {"kind": "identity", "placed": [],
                                 "silentSlots": [],
                                 "transformations": ["identity"]},
            "provenance": "source_native",
            "inputFramesConsumedTotal": source_start + source_frames,
            "converterLeadingFrames": 0, "converterTrailingFrames": 0,
            "primeMethod": "none", "converterDelayKnown": False,
            "timestampRelation": "input_block_metadata"}


def pcm_payload(frames=2, marker=None):
    marker = marker or {}
    values = []
    for frame in range(frames):
        for channel, label in enumerate(ORDER):
            values.append(marker.get(label, ((frame + 1) * 8 + channel) / 64.0))
    return struct.pack("<%df" % len(values), *values)


class FakeHub:
    def __init__(self):
        self.pushed = []
        self.failures = []

    async def push(self, samples):
        self.pushed.append(samples)

    async def fail(self, error):
        self.failures.append(error)


class VC2PumpTests(unittest.IsolatedAsyncioTestCase):
    def make(self, processor=None):
        hub = FakeHub()
        capture = CaptureHostV2(sys.executable, SESSION, hub, UID71, "7_1",
                                processor or (lambda samples: samples))
        return capture, hub

    async def pump(self, capture, frames, stopping=False, feed_eof=True):
        loop = asyncio.get_running_loop()
        capture.ready = loop.create_future()
        capture.stopped_reply = loop.create_future()
        capture.stopping = stopping
        capture.process = SimpleNamespace(stdout=asyncio.StreamReader())
        for header, payload in frames:
            capture.process.stdout.feed_data(wire(header, payload))
        if feed_eof:
            capture.process.stdout.feed_eof()
        await capture._pump()
        for future in (capture.ready, capture.stopped_reply):
            if future.done() and not future.cancelled():
                future.exception()

    async def test_constructor_only_accepts_canonical_layout_uid_and_processor(self):
        for layout, uid in (("5_1_2", UID71), ("7_1", "com.homepodflow.virtual-audio.stereo.v1")):
            with self.subTest(layout=layout, uid=uid), self.assertRaises(ValueError):
                CaptureHostV2(sys.executable, SESSION, FakeHub(), uid, layout, lambda x: x)
        with self.assertRaises(ValueError):
            CaptureHostV2(sys.executable, SESSION, FakeHub(), UID71, "7_1", "not-callable")
        capture, _ = self.make()
        self.assertIsInstance(capture.validator, PCMV2Validator)
        self.assertEqual(capture.channels, 8)

    async def test_command_emits_bounded_v2_jsonl(self):
        capture, _ = self.make()
        emitted = []

        class Stdin:
            def write(self, data):
                emitted.append(json.loads(data))
            async def drain(self):
                return None

        capture.process = SimpleNamespace(stdin=Stdin())
        await capture._command("start", capture.start_id)
        await capture._command("stop", capture.stop_id)
        self.assertEqual([line["v"] for line in emitted], [2, 2])
        self.assertEqual(emitted[0]["params"],
                         {"session": SESSION, "deviceUID": UID71, "layout": "7_1"})
        self.assertEqual(emitted[1]["params"], {"session": SESSION})
        self.assertEqual({line["id"] for line in emitted},
                         {capture.start_id, capture.stop_id})

    async def test_ready_resolves_then_eof_fails_the_group(self):
        capture, hub = self.make()
        await self.pump(capture, [(ready(capture.start_id), b"")])
        self.assertEqual(capture.ready.result()["outputLayout"], "7_1")
        self.assertEqual(capture.ready.result()["deviceUID"], UID71)
        self.assertEqual(capture.ready_header, capture.ready.result())
        self.assertEqual(len(hub.failures), 1)
        self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)

    async def test_pcm_before_ready_is_rejected_and_group_fails(self):
        capture, hub = self.make()
        await self.pump(capture, [(pcm_header(capture.start_id), pcm_payload())])
        self.assertEqual(hub.pushed, [])
        self.assertEqual(len(hub.failures), 1)
        self.assertIsInstance(capture.ready.exception(), LiveFailure)
        self.assertEqual(capture.last_error, "LiveFailure")

    async def test_ready_then_pcm_pushes_fully_processed_samples(self):
        capture, hub = self.make()
        await self.pump(capture, [(ready(capture.start_id), b""),
                                  (pcm_header(capture.start_id), pcm_payload())])
        self.assertEqual(len(hub.pushed), 1)
        self.assertEqual(list(hub.pushed[0]), list(array.array("f", pcm_payload())))
        self.assertEqual(capture.ready.result()["sourceRate"], 48000)
        self.assertEqual(capture.ready.result()["sourceChannels"], 8)
        self.assertNotIn("source", capture.ready.result())

    async def test_ready_malformed_flags_layout_rate_and_source(self):
        mutations = [
            lambda h: h.update(outputRate=48000),
            lambda h: h.update(outputChannels=6),
            lambda h: h.update(outputLayout="5_1_side"),
            lambda h: h.update(deviceUID="com.homepodflow.virtual-audio.stereo.v1"),
            lambda h: h.update(sourceRate=44101),
            lambda h: h.update(sourceRate=True),
            lambda h: h.update(sourceChannels=6),
            lambda h: (h.pop("sourceRate"), None),
            lambda h: (h.pop("sourceChannels"), None),
        ]
        for index, mutate in enumerate(mutations):
            capture, hub = self.make()
            header = ready(capture.start_id)
            mutate(header)
            with self.subTest(mutation=index):
                await self.pump(capture, [(header, b"")])
                self.assertEqual(capture.last_error, "LiveFailure")
                self.assertIsInstance(capture.ready.exception(), LiveFailure)

    async def test_ready_rejects_legacy_nested_source_payload(self):
        capture, hub = self.make()
        header = control("ready", capture.start_id, outputRate=44100,
                         outputChannels=8, outputLayout="7_1", deviceUID=UID71,
                         source={"sourceRate": 48000, "sourceChannels": 8})
        await self.pump(capture, [(header, b"")])
        self.assertEqual(capture.last_error, "LiveFailure")
        self.assertIsInstance(capture.ready.exception(), LiveFailure)

    async def test_stale_session_and_duplicate_ready_never_enter_new_session(self):
        capture, hub = self.make()
        stale = ready(capture.start_id, session=SESSION.lower())
        await self.pump(capture, [(stale, b"")])
        self.assertIsInstance(capture.ready.exception(), PCMV2Error)
        self.assertEqual(len(hub.failures), 1)

        capture, hub = self.make()
        first = ready(capture.start_id)
        await self.pump(capture, [(first, b""), (ready(capture.start_id), b"")])
        self.assertEqual(capture.ready.result()["deviceUID"], UID71)
        self.assertEqual(capture.last_error, "LiveFailure")
        self.assertEqual(len(hub.failures), 1)

    async def test_stop_ack_requires_controller_stop_and_complete_fields(self):
        capture, hub = self.make()
        await self.pump(capture, [(stopped(capture.stop_id), b"")], stopping=False)
        self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)
        self.assertEqual(len(hub.failures), 1)

        for field in ("cleanupComplete", "discardedConverterTail"):
            capture, hub = self.make()
            header = stopped(capture.stop_id)
            del header[field]
            with self.subTest(missing=field):
                await self.pump(capture, [(header, b"")], stopping=True)
                self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)

        capture, hub = self.make()
        header = stopped(capture.stop_id, drainComplete=True)
        await self.pump(capture, [(header, b"")], stopping=True)
        self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)

    async def test_stop_ack_resolves_only_once_with_clean_evidence(self):
        capture, hub = self.make()
        header = stopped(capture.stop_id)
        await self.pump(capture, [(header, b"")], stopping=True)
        self.assertEqual(capture.stopped_reply.result()["cleanupComplete"], True)
        self.assertEqual(capture.stopped_reply.result()["drainComplete"], False)
        self.assertEqual(capture.stopped_reply.result()["discardedConverterTail"], True)
        self.assertEqual(hub.failures, [])

    async def test_eof_without_stop_ack_never_resolves_cleanup(self):
        capture, hub = self.make()
        await self.pump(capture, [], stopping=True, feed_eof=True)
        self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)
        self.assertEqual(hub.failures, [])

    async def test_error_frame_requires_start_correlation_and_strict_cleanup(self):
        capture, hub = self.make()
        await self.pump(capture, [(control("error", capture.start_id,
                                           session=SESSION.lower(), code="x",
                                           cleanupComplete=True), b"")])
        self.assertIsNone(capture.error_header)
        self.assertIsInstance(capture.ready.exception(), PCMV2Error)

        capture, hub = self.make()
        await self.pump(capture, [(control("error", capture.start_id,
                                           code="capture_failed",
                                           message="fixture failure",
                                           cleanupComplete=True), b"")])
        self.assertEqual(capture.error_header["cleanupComplete"], True)
        self.assertIn("capture_failed", str(hub.failures[0]))

        capture, hub = self.make()
        await self.pump(capture, [(control("error", capture.start_id,
                                           code="capture_failed",
                                           cleanupComplete="yes"), b"")])
        self.assertIsInstance(capture.ready.exception(), LiveFailure)


class VC2StopLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def run_stop(self, ack, exit_code):
        hub = FakeHub()
        capture = CaptureHostV2(sys.executable, SESSION, hub, UID71, "7_1",
                                lambda samples: samples)
        loop = asyncio.get_running_loop()
        capture.ready, capture.stopped_reply = (loop.create_future(),
                                                loop.create_future())
        reader = asyncio.StreamReader()
        commands = []

        class Process:
            stdout = reader
            returncode = None

            async def wait(self):
                self.returncode = exit_code
                return exit_code

            def terminate(self):
                self.returncode = -15

            def kill(self):
                self.returncode = -9

        def write(data):
            command = json.loads(data)
            commands.append(command)
            if ack:
                header = stopped(command["id"])
                reader.feed_data(wire(header))
                reader.feed_eof()

        async def drain():
            return None

        if not ack:
            reader.feed_eof()
        process = Process()
        process.stdin = SimpleNamespace(write=write, drain=drain, close=lambda: None)
        capture.process = process
        capture.pump_task = asyncio.create_task(capture._pump())
        cleaned = await capture.stop()
        return capture, commands, hub, cleaned

    async def test_stop_confirms_only_clean_ack_and_exit_zero(self):
        for ack, exit_code, expected in ((True, 0, True), (False, 0, False),
                                         (True, 7, False)):
            with self.subTest(ack=ack, exit_code=exit_code):
                capture, commands, _hub, cleaned = await self.run_stop(ack, exit_code)
                self.assertEqual(cleaned, expected)
                if ack:
                    self.assertEqual(commands[-1]["v"], 2)
                    self.assertEqual(commands[-1]["params"], {"session": SESSION})
                self.assertEqual(capture.cleanup_complete, expected)

    async def test_eof_without_ack_is_not_clean_cleanup(self):
        capture, commands, hub, cleaned = await self.run_stop(False, 0)
        self.assertFalse(cleaned)
        self.assertFalse(capture.cleanup_complete)
        self.assertEqual(hub.failures, [])
        self.assertIsInstance(capture.stopped_reply.exception(), LiveFailure)


class RoutingMatrixTests(unittest.TestCase):
    def order_index(self, label):
        return ORDER.index(label)

    def test_synchronized_downmix_uses_frozen_contract_coefficients(self):
        a = math.sqrt(2) - 1
        b = 1 - math.sqrt(2) / 2
        c = b / 2
        plan = VirtualRoutePlan("7_1", [0, 1], "synchronized")
        left, right = plan.rows[0], plan.rows[1]
        self.assertAlmostEqual(left[self.order_index("FL")], a, places=6)
        self.assertAlmostEqual(right[self.order_index("FR")], a, places=6)
        self.assertAlmostEqual(left[self.order_index("FC")], b, places=6)
        self.assertAlmostEqual(right[self.order_index("FC")], b, places=6)
        self.assertAlmostEqual(left[self.order_index("SL")], c, places=6)
        self.assertAlmostEqual(right[self.order_index("SR")], c, places=6)
        self.assertAlmostEqual(left[self.order_index("BL")], c, places=6)
        self.assertAlmostEqual(right[self.order_index("BR")], c, places=6)
        self.assertEqual(left[self.order_index("LFE")], 0.0)
        self.assertEqual(right[self.order_index("LFE")], 0.0)
        self.assertEqual(plan.actual_mode, "stereo_downmix")
        self.assertEqual(plan.report()["discarded_channels"], ["LFE"])
        for row in plan.rows:
            self.assertAlmostEqual(sum(abs(value) for value in row), 1.0, places=6)

    def test_downmix_keeps_center_and_discards_lfe_without_silent_drop(self):
        plan = VirtualRoutePlan("7_1", [0, 1], "synchronized")
        center = [0.0] * 8
        center[self.order_index("FC")] = 1.0
        out = plan.process(array.array("f", center))
        self.assertEqual(len(out), 4)
        self.assertGreater(out[0], 0.29)
        self.assertEqual(set(out), {out[0]})
        lfe = [0.0] * 8
        lfe[self.order_index("LFE")] = 1.0
        self.assertEqual(list(plan.process(array.array("f", lfe))), [0.0, 0.0, 0.0, 0.0])

    def test_cinema_complete_unique_roles_route_independent_channels(self):
        roles = {0: "FL", 1: "FR", 2: "FC", 3: "SL", 4: "SR", 5: "BL", 6: "BR"}
        plan = VirtualRoutePlan("7_1", list(range(7)), "cinema", roles)
        self.assertEqual(plan.actual_mode, "channel_distribution")
        self.assertEqual(plan.channels, 14)
        self.assertEqual(plan.routes, {i: [2 * i, 2 * i + 1] for i in range(7)})
        values = [(index + 1) / 16.0 for index in range(8)]
        out = plan.process(array.array("f", values))
        for endpoint, role in roles.items():
            self.assertEqual(out[2 * endpoint], out[2 * endpoint + 1])
            self.assertEqual(out[2 * endpoint], values[ORDER.index(role)])
        self.assertIn("LFE", plan.report()["discarded_channels"])

    def test_cinema_incomplete_or_duplicate_roles_are_rejected(self):
        for roles in ({0: "FL"}, {0: "FL", 1: "FL"}, {0: "XX"}):
            with self.subTest(roles=roles), self.assertRaises(ValueError):
                VirtualRoutePlan("7_1", [0, 1], "cinema", roles)
        fallback = VirtualRoutePlan("7_1", [0, 1], "cinema", {})
        self.assertEqual(fallback.actual_mode, "stereo_downmix")
        with self.assertRaises(ValueError):
            VirtualRoutePlan("5_1_2", [0, 1], "synchronized")

    def test_process_rejects_bad_dimensions_and_nonfinite_samples(self):
        plan = VirtualRoutePlan("7_1", [0, 1], "synchronized")
        with self.assertRaises(LiveFailure):
            plan.process(array.array("f", [0.1] * 7))
        with self.assertRaises(LiveFailure):
            plan.process(array.array("f", [float("inf")] * 8))
        with self.assertRaises(LiveFailure):
            plan.process(array.array("f", [1.5] * 8))


class NativeRoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_native_core_routes_distinct_channels_to_each_endpoint(self):
        library = os.environ.get("FLOW_CORE_LIBRARY")
        self.assertTrue(library,
                        "FLOW_CORE_LIBRARY required: matrix-only tests cannot prove native routing")
        roles = {0: "FL", 1: "FR", 2: "FC", 3: "SL", 4: "SR", 5: "BL", 6: "BR"}
        plan = VirtualRoutePlan("7_1", list(range(7)), "cinema", roles)
        hub = LiveHub(library, plan.routes, input_channels=plan.channels,
                      input_capacity_frames=32, block_frames=2,
                      output_capacity_blocks=2, stall_timeout=.2,
                      clock_ns=lambda: 1_000_000_000)
        self.addAsyncCleanup(hub.stop)
        values = []
        for _frame in range(2):
            values.extend((index + 1) / 16.0 for index in range(8))
        processed = plan.process(array.array("f", values))
        await hub.push(processed, receipt_ns=1_000_000_000)
        hub.start(500_000_000)
        for endpoint, role in roles.items():
            data = await hub.read(endpoint, 2)
            frame = struct.unpack(">4h", data)
            expected = int(round((ORDER.index(role) + 1) / 16.0 * 32767))
            self.assertEqual(frame, (expected, expected, expected, expected), role)


class SystemRequestParseTests(unittest.TestCase):
    def params(self, input_=None, routes=None, mode="synchronized",
               roles=None):
        routes = routes or [{"output_id": 0, "channels": [0, 1], "host": "offline-a"}]
        result = {"session": SESSION, "library": str(ROOT / "unused-library"),
                  "capture_host": sys.executable, "routes": list(routes),
                  "mode": mode}
        if input_ is not None:
            result["input"] = input_
        if roles:
            for route, role in zip(result["routes"], roles or []):
                if role is not None:
                    route["role"] = role
        return result

    def request(self, rid, params):
        return (json.dumps({"v": 1, "id": rid, "command": "start",
                            "params": params}) + "\n").encode()

    def valid_input(self):
        return {"backend": "virtual_device_v2", "device_uid": UID71,
                "layout": "7_1"}

    def test_v2_input_accepts_optional_roles_and_truthful_plan_prepare(self):
        routes = [{"output_id": i, "channels": [0, 1], "host": f"offline-{i}"}
                  for i in range(2)]
        parsed = parse_system_request(self.request("ok", self.params(
            input_=self.valid_input(), routes=routes, roles=["FL", "FR"])))
        self.assertEqual(parsed["params"]["input"]["device_uid"], UID71)
        self.assertEqual(parsed["params"]["routes"][0]["role"], "FL")

    def test_v1_request_keeps_stereo_routes_and_rejects_role(self):
        parsed = parse_system_request(self.request("v1", self.params()))
        self.assertEqual(parsed["params"]["routes"][0]["channels"], [0, 1])
        self.assertNotIn("input", parsed["params"])
        with self.assertRaises(ProtocolError):
            parse_system_request(self.request("bad", self.params(
                routes=[{"output_id": 0, "channels": [0, 1], "host": "offline-a",
                         "role": "FL"}])))

    def test_malformed_bool_null_and_unknown_input_fields_are_rejected(self):
        cases = []
        for bad in ({"backend": True, "device_uid": UID71, "layout": "7_1"},
                    {"backend": "virtual_device_v2", "device_uid": None, "layout": "7_1"},
                    {"backend": "virtual_device_v2", "device_uid": UID71, "layout": None},
                    {"backend": "virtual_device_v2", "device_uid": UID71,
                     "layout": "7_1", "surprise": 1},
                    {"backend": "virtual_device_v2", "device_uid": UID71,
                     "layout": "5_1_side"},
                    {"backend": "virtual_device_v2",
                     "device_uid": "com.homepodflow.virtual-audio.stereo.v1",
                     "layout": "7_1"}):
            cases.append(self.params(input_=bad))
        cases.append(self.params(input_=self.valid_input(), mode=True))
        cases.append(self.params(input_=self.valid_input(),
                                 routes=[{"output_id": 0, "channels": [0, 2],
                                          "host": "offline-a"}]))
        for index, params in enumerate(cases):
            with self.subTest(case=index), self.assertRaises(ProtocolError):
                parse_system_request(self.request("bad", params))

    def test_cinema_incomplete_roles_rejected_at_request_boundary(self):
        params = self.params(input_=self.valid_input(), mode="cinema",
                             routes=[{"output_id": i, "channels": [0, 1],
                                      "host": f"offline-{i}"} for i in range(2)],
                             roles=["FL", "FR"])
        with self.assertRaises(ProtocolError):
            parse_system_request(self.request("bad", params))


if __name__ == "__main__":
    unittest.main(verbosity=2)
