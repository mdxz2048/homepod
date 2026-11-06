"""Focused 019 latency-budget and verified Core Audio report checks."""
import json
from pathlib import Path
import unittest

from adapters.live.latency_control import (
    PREPARATION_MS,
    default_estimate_ms,
    latency_comparison,
    negotiated_latency_ms,
    plan_telemetry,
    playback_lead_ns,
    planned_presentation_ms,
    protocol_latency_ns,
    validate_latency_report,
)
from adapters.system_worker import parse_system_request

SESSION = "AABBCCDD-1122-3344-5566-778899AABBCC"
ROOT = str(Path(__file__).resolve().parents[1])
UID = "com.homepodflow.virtual-audio.surround71.v1"
MODEL = "com.homepodflow.virtual-audio.model.surround71.v1"


def make_report(*, rate=44100, hfla_frames=66150, running=False, **overrides):
    report = {
        "verified": True,
        "tool": "hflctl",
        "command": "status",
        "uid": UID,
        "model_uid": MODEL,
        "channels": 8,
        "nominal_rate": rate,
        "hfla_frames": hfla_frames,
        "hfla_ms": hfla_frames * 1000.0 / rate,
        "hflr": 3,
        "stream_latency_global_frames": hfla_frames,
        "stream_latency_output_frames": hfla_frames,
        "latency_scopes_match": True,
        "control_scope_match": True,
        "device_is_running": running,
    }
    report.update(overrides)
    return report


def system_start(latency_report=None, with_input=True):
    params = {"session": SESSION, "library": ROOT + "/unused-test-library",
              "capture_host": ROOT + "/unused-capture-host",
              "routes": [{"output_id": 0, "channels": [0, 1], "host": "192.0.2.1"}],
              "volume": 15, "mode": "synchronized"}
    if with_input:
        config = {"backend": "virtual_device_v2", "device_uid": UID, "layout": "7_1"}
        if latency_report is not None:
            config["latency_report"] = latency_report
        params["input"] = config
    return json.dumps({"v": 1, "id": "start", "command": "start", "params": params}).encode() + b"\n"


def make_diff_report(reported_ms):
    """A verified report whose hfla_ms is `reported_ms` at 44100."""
    frames = round(reported_ms * 44100 / 1000)
    return make_report(hfla_frames=frames, hfla_ms=float(reported_ms))


class LatencyArithmeticTests(unittest.TestCase):
    def test_default_estimate_is_the_observed_formula(self):
        self.assertEqual(default_estimate_ms(), 66150 * 1000 // 44100 + PREPARATION_MS)
        self.assertEqual(default_estimate_ms(), 2000)

    def test_negotiated_and_planned_milliseconds(self):
        self.assertEqual(negotiated_latency_ms(66150, 44100), 1500)
        self.assertEqual(planned_presentation_ms(66150, 44100), 2000)
        self.assertEqual(negotiated_latency_ms(66150, 48000), 1378)
        self.assertEqual(planned_presentation_ms(66150, 48000), 1878)
        self.assertEqual(negotiated_latency_ms(50, 44100), 1)
        self.assertEqual(planned_presentation_ms(50, 44100), 501)

    def test_scheduler_formula_is_unchanged(self):
        for latency, rate in [(0, 44100), (1, 44100), (66150, 44100), (66150, 48000), (88200, 44100)]:
            self.assertEqual(playback_lead_ns(latency, rate),
                             latency * 1_000_000_000 // rate + PREPARATION_MS * 1_000_000)
            self.assertEqual(protocol_latency_ns(latency, rate), latency * 1_000_000_000 // rate)

    def test_plan_does_not_round_trip_a_second_preparation(self):
        negotiated = negotiated_latency_ms(66150, 44100)
        plan = plan_telemetry(66150, 44100)
        self.assertEqual(plan["planned_presentation_ms"], negotiated + PREPARATION_MS)


class LatencyReportValidationTests(unittest.TestCase):
    def test_valid_report_is_accepted_and_normalized(self):
        normalized = validate_latency_report(make_report(rate=48000, hfla_frames=96000))
        self.assertEqual(normalized["hfla_ms"], 2000.0)
        self.assertEqual(normalized["hflr"], 3)
        self.assertTrue(normalized["verified"])

    def test_rejects_invalid_reports(self):
        cases = {
            "not_verified": make_report(verified=False),
            "missing_uid": {k: v for k, v in make_report().items() if k != "uid"},
            "wrong_uid": make_report(uid="com.other.device"),
            "wrong_model": make_report(model_uid="com.other.model"),
            "wrong_channels": make_report(channels=2),
            "bad_rate": make_report(rate=96000),
            "hfla_ms_mismatch": make_report(hfla_ms=2000.0),
            "scope_global_mismatch": make_report(stream_latency_global_frames=66151),
            "scope_output_mismatch": make_report(stream_latency_output_frames=66150 - 1),
            "scopes_flag_false": make_report(latency_scopes_match=False),
            "control_flag_false": make_report(control_scope_match=False),
            "revision_zero": make_report(hflr=0),
            "running_invalid": make_report(device_is_running="yes"),
            "too_large_ms": make_report(hfla_frames=round(3001 * 44100 / 1000)),
        }
        for name, report in cases.items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                validate_latency_report(report)

    def test_comparison_is_signed_programmed_minus_reported(self):
        comparison = latency_comparison(66150, 44100, validate_latency_report(make_diff_report(1400)))
        self.assertEqual(comparison["programmed_ms"], 1500)
        self.assertEqual(comparison["reported_ms"], 1400.0)
        self.assertEqual(comparison["signed_difference_ms"], 100)

    def test_plan_separates_nominal_model_from_reported_measurement(self):
        plan = plan_telemetry(66150, 44100)
        self.assertFalse(plan["report_verified"])
        self.assertEqual(plan["programmed_model"]["kind"], "nominal_plan")
        self.assertNotIn("acoustic_measurement", plan)

        plan = plan_telemetry(66150, 44100, validate_latency_report(make_diff_report(1400)))
        self.assertTrue(plan["report_verified"])
        self.assertEqual(plan["acoustic_measurement"]["kind"], "core_audio_stream_latency_property")
        self.assertIs(plan["residual_claimed_zero"], False)
        self.assertGreaterEqual(len(plan["unknown_components"]), 1)


class SystemWorkerParseTests(unittest.TestCase):
    def test_v1_start_unchanged_without_input(self):
        parsed = parse_system_request(system_start(with_input=False))
        self.assertEqual(parsed["command"], "start")
        self.assertNotIn("input", parsed["params"])

    def test_v2_input_without_report_still_parses(self):
        parsed = parse_system_request(system_start())
        self.assertNotIn("latency_report", parsed["params"]["input"])

    def test_verified_report_is_normalized(self):
        report = make_report()
        parsed = parse_system_request(system_start(latency_report=report))
        normalized = parsed["params"]["input"]["latency_report"]
        self.assertNotIn("timestamp_unix_ms", normalized)
        self.assertEqual(normalized["hfla_ms"], report["hfla_ms"])
        self.assertTrue(normalized["verified"])

    def test_invalid_report_rejected_with_bad_params(self):
        from adapters.worker.protocol import ProtocolError
        with self.assertRaises(ProtocolError) as context:
            parse_system_request(system_start(latency_report=make_report(verified=False)))
        self.assertEqual(context.exception.code, "invalid_params")


if __name__ == "__main__":
    unittest.main(verbosity=2)
