"""Run the offline source-first multichannel acceptance suite.

Generates deterministic fixtures in a temporary directory, checks every route
matrix, renders a representative WAV subset, verifies channel identity with
narrow-band projection, and exercises rejection/latency/buffer/layer gates.

No audio is played or captured; no device is changed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
from typing import Dict, List, Optional

import analyze_multichannel_capture as analyzer
import make_multichannel_fixtures as fixtures
import multichannel_model as model
import multichannel_wav as wav


SELECTED_WAV_CASES = (
    "MC-A01",  # mono identity
    "MC-A02",  # stereo identity
    "MC-A05",  # 5.1 side identity
    "MC-A07",  # 7.1 identity
    "MC-A08",  # 7.1.2 reserved identity
    "MC-B02",  # mono -> 5.1 side passthrough
    "MC-B05",  # stereo -> 5.1 side passthrough fallback
    "MC-B07",  # quad -> 5.1 back passthrough
    "MC-B11",  # 7.1 -> 7.1.2 reserved passthrough
    "MC-C01",  # stereo -> mono
    "MC-C05",  # quad -> stereo
    "MC-C08",  # 5.1 side -> stereo
    "MC-C13",  # 7.1 -> 5.1 side
    "MC-C18",  # 7.1.2 -> 7.1
    "MC-D01",  # stereo -> 5.1 side upmix fallback
    "MC-D02",  # stereo -> 7.1 upmix fallback
    "MC-F-7_1-1",
    "MC-F-7_1-3",
    "MC-F-7_1-6",
    "MC-F-5_1_side-2",
)


def _plan_for_case(case: Dict[str, object]) -> model.RoutePlan:
    source = str(case["source_layout"])
    target = str(case["target_layout"])
    lfe_policy = str(case["lfe_policy"])
    if case["kind"] == "endpoint":
        return model.build_endpoint_route(
            source, model.channel_count_for(target), lfe_policy=lfe_policy
        )
    return model.build_route(source, target, str(case["mode"]), lfe_policy=lfe_policy)


def _expect_reject(name: str, function, code: str) -> Dict[str, object]:
    try:
        function()
    except model.RejectError as error:
        return {
            "name": name,
            "status": "pass" if error.code == code else "fail",
            "expected": code,
            "actual": error.code,
        }
    except Exception as error:  # noqa: BLE001 - report unexpected failure type
        return {
            "name": name,
            "status": "fail",
            "expected": code,
            "actual": f"{type(error).__name__}: {error}",
        }
    return {"name": name, "status": "fail", "expected": code, "actual": "no rejection"}


def _matrix_checks(cases: List[Dict[str, object]]) -> Dict[str, object]:
    failures = []
    for case in cases:
        try:
            plan = _plan_for_case(case)
            model.validate_route_claims(plan)
            if model.max_row_l1(plan.matrix) > 1.0 + 1e-9:
                failures.append(f"{case['case']}: row L1 > 1")
            if len(plan.labels) != plan.container_channel_count:
                failures.append(f"{case['case']}: label/container count mismatch")
            if plan.mode != "identity" and plan.reported_as_native_5_1_or_7_1:
                failures.append(f"{case['case']}: non-identity native 5.1/7.1 claim")
            tones = model.expected_tones(plan)
            if set(tones) != set(plan.labels):
                failures.append(f"{case['case']}: expected tone labels mismatch")
        except Exception as error:  # noqa: BLE001
            failures.append(f"{case['case']}: {type(error).__name__}: {error}")
    return {"case_count": len(cases), "failures": failures, "status": "pass" if not failures else "fail"}


def _endpoint_checks() -> Dict[str, object]:
    rows = {}
    failures = []
    for source in fixtures.REQUIRED_SOURCES:
        rows[source] = {}
        for count in model.REQUIRED_ENDPOINT_COUNTS:
            try:
                plan = model.build_endpoint_route(source, count)
                claim = model.acoustic_claim_for(source, count)
                if model.max_row_l1(plan.matrix) > 1.0 + 1e-9:
                    failures.append(f"{source}->{count}: row L1 > 1")
                if count == 2 and source in model.SURROUND_LAYOUTS and claim != "stereo_downmix":
                    failures.append(f"{source}->2: claim {claim} is not stereo_downmix")
                if count == 6 and source in ("5.1_side", "5.1_back") and claim != source:
                    failures.append(f"{source}->6: claim {claim} != {source}")
                rows[source][str(count)] = {
                    "target_layout": plan.container_layout,
                    "mode": plan.mode,
                    "acoustic_claim": claim,
                }
            except Exception as error:  # noqa: BLE001
                failures.append(f"{source}->{count}: {type(error).__name__}: {error}")
    return {"matrix": rows, "failures": failures, "status": "pass" if not failures else "fail"}


def _latency_checks() -> Dict[str, object]:
    failures = []
    checks = {}
    try:
        left = model.DeviceClock("left")
        right = model.DeviceClock("right")
        revision = left.set_latency(4800)
        checks["per_device_isolation"] = right.revision == 1 and left.revision == revision
        checks["idempotent"] = left.set_latency(4800) == revision
        checks["monotonic"] = left.set_latency(2400) == revision + 1
        seconds_before = left.latency_frames / left.rate
        left.set_rate(44100)
        checks["rate_recomputes_frames"] = (
            abs(left.latency_frames / left.rate - seconds_before) < 1e-9
        )
        old = left
        left = left.rediscover()
        try:
            old.assert_revision(old.revision)
        except model.RejectError as error:
            checks["rediscovery_invalidates_old_revision"] = (
                error.code == "latency_revision_changed"
            )
        else:
            checks["rediscovery_invalidates_old_revision"] = False
    except Exception as error:  # noqa: BLE001
        failures.append(f"latency: {type(error).__name__}: {error}")
    if not all(value for key, value in checks.items() if isinstance(value, bool)):
        failures.append("one or more latency assertions failed")
    return {"checks": checks, "failures": failures, "status": "pass" if not failures else "fail"}


def _buffer_checks() -> Dict[str, object]:
    failures = []
    checks = {}
    device = model.DeviceClock("buffer")
    revision = device.revision
    for value in (15, 16, 255, 256, 512, 1024, 4096):
        try:
            device.set_buffer(value)
            device.accept_io_frames(value)
        except model.RejectError as error:
            failures.append(f"buffer {value}: {error}")
    checks["valid_range_accepted"] = not failures
    checks["revision_unchanged"] = device.revision == revision
    checks["period_independent"] = device.zero_timestamp_period == 16384
    checks["driver_value_not_authoritative"] = device.driver_reported_buffer == 512
    for value in (14, 4097, 0, -1):
        try:
            device.set_buffer(value)
        except model.RejectError:
            pass
        else:
            failures.append(f"buffer {value} should reject")
    return {"checks": checks, "failures": failures, "status": "pass" if not failures else "fail"}


def _layer_checks() -> Dict[str, object]:
    failures = []
    claims = {
        "mono->1": model.acoustic_claim_for("mono", 1),
        "stereo->2": model.acoustic_claim_for("stereo", 2),
        "5.1_side->2": model.acoustic_claim_for("5.1_side", 2),
        "5.1_side->6": model.acoustic_claim_for("5.1_side", 6),
        "7.1->2": model.acoustic_claim_for("7.1", 2),
        "7.1->8": model.acoustic_claim_for("7.1", 8),
    }
    if claims["5.1_side->2"] != "stereo_downmix":
        failures.append("5.1 on two endpoints must claim stereo_downmix")
    if claims["7.1->2"] != "stereo_downmix":
        failures.append("7.1 on two endpoints must claim stereo_downmix")
    if claims["5.1_side->6"] != "5.1_side":
        failures.append("5.1 on six endpoints with identity route may claim 5.1_side")

    rejections = [
        _expect_reject(
            "five_1_on_two_endpoints",
            lambda: model.validate_acoustic_claim("5.1_side", 2),
            "acoustic_endpoints_insufficient",
        ),
        _expect_reject(
            "unmeasured_six_endpoints",
            lambda: model.validate_acoustic_claim("5.1_side", 6),
            "acoustic_not_measured",
        ),
    ]
    failures.extend(
        item["name"] for item in rejections if item["status"] != "pass"
    )
    return {
        "claims": claims,
        "claim_rejections": rejections,
        "failures": failures,
        "status": "pass" if not failures else "fail",
    }


def _wav_checks(temp: Path, cases: List[Dict[str, object]]) -> Dict[str, object]:
    by_id = {str(case["case"]): case for case in cases}
    results = []
    failures = []
    for case_id in SELECTED_WAV_CASES:
        case = by_id[case_id]
        plan = _plan_for_case(case)
        capture = temp / "captures" / f"{case_id}.wav"
        expected_path = temp / "expected_wav" / f"{case_id}.json"
        expected_path.parent.mkdir(parents=True, exist_ok=True)
        expected_path.write_text(
            json.dumps(fixtures.expected_for_case(case), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        try:
            wav.render_plan(capture, plan)
            result = analyzer.analyze_capture(capture, expected_path)
        except Exception as error:  # noqa: BLE001
            failures.append(f"{case_id}: {type(error).__name__}: {error}")
            results.append({"case": case_id, "status": "fail", "error": str(error)})
            continue
        results.append(
            {
                "case": case_id,
                "status": result["status"],
                "source_layout": plan.source_layout,
                "container_layout": plan.container_layout,
                "channels": plan.container_channel_count,
                "failures": result["failures"][:5],
            }
        )
        if result["status"] != "pass":
            failures.append(f"{case_id}: {result['failures'][:3]}")
    return {
        "selected": len(SELECTED_WAV_CASES),
        "results": results,
        "failures": failures,
        "status": "pass" if not failures else "fail",
    }


def _clipping_checks(temp: Path) -> Dict[str, object]:
    failures = []
    # The 12-channel source is the largest required source and has the most
    # terms in a two-endpoint row. Render at full scale; row L1 capping must
    # keep the output at or below full scale.
    plan = model.build_endpoint_route("7.1.4", 2)
    path = temp / "stress" / "7_1_4_to_stereo_fullscale.wav"
    try:
        info = wav.render_plan(path, plan, duration=0.25, amplitude=1.0)
        data = wav.read_wav(path)
        measured_peak = max(wav.peak(channel) for channel in data.samples)
        if measured_peak > 1.0 + 1e-6:
            failures.append(f"stress peak {measured_peak:.6f}")
    except Exception as error:  # noqa: BLE001
        failures.append(f"stress render: {type(error).__name__}: {error}")
        info = {}
        measured_peak = None

    try:
        wav.write_wav(
            temp / "stress" / "intentional_clip.wav",
            48000,
            ("FC",),
            {"FC": [1.5, -1.5]},
            mask=model.mask_for("mono"),
        )
    except wav.ClippingError:
        guard = True
    else:
        guard = False
        failures.append("clipping guard did not reject 1.5 full scale")
    return {
        "stress_peak": measured_peak,
        "max_row_l1": model.max_row_l1(plan.matrix),
        "clip_guard": guard,
        "render_info": {key: info.get(key) for key in ("headroom_db", "max_row_l1")}
        if info
        else {},
        "failures": failures,
        "status": "pass" if not failures else "fail",
    }


def run() -> Dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="homepod-mc-acceptance-") as directory:
        temp = Path(directory)
        manifest = fixtures.create(temp / "fixtures")
        cases = fixtures.build_cases()
        matrix = _matrix_checks(cases)
        endpoint = _endpoint_checks()
        latency = _latency_checks()
        buffer = _buffer_checks()
        layers = _layer_checks()
        wav_checks = _wav_checks(temp, cases)
        clipping = _clipping_checks(temp)

    rejections = [
        _expect_reject(
            "unknown_source_layout",
            lambda: model.build_route("unknown", "stereo"),
            "unsupported_layout",
        ),
        _expect_reject(
            "ambiguous_5_1",
            lambda: model.build_route("5.1", "stereo"),
            "ambiguous_layout",
        ),
        _expect_reject(
            "ambiguous_8ch",
            lambda: model.build_route("8ch", "7.1"),
            "ambiguous_layout",
        ),
        _expect_reject(
            "swapped_surround_labels",
            lambda: model.validate_labels(("FL", "FR", "FC", "LFE", "SR", "SL")),
            "unsupported_layout",
        ),
        _expect_reject(
            "duplicate_labels",
            lambda: model.validate_labels(("FL", "FL")),
            "duplicate_label",
        ),
        _expect_reject(
            "side_to_back_relabel",
            lambda: model.build_route("5.1_side", "5.1_back"),
            "layout_mismatch",
        ),
        _expect_reject(
            "wider_target_missing_center",
            lambda: model.build_route("3.0", "4.0_quad"),
            "layout_mismatch",
        ),
        _expect_reject(
            "silence_inference",
            lambda: model.infer_layout_from_silence([0.25, 0.0, 0.0, 0.0, 0.0, 0.0]),
            "silence_does_not_identify_layout",
        ),
        _expect_reject(
            "stereo_native_claim",
            lambda: model.validate_descriptor(
                {
                    "source_layout": "stereo",
                    "container_layout": "5.1_side",
                    "reported_as_native_5_1_or_7_1": True,
                }
            ),
            "false_native_claim",
        ),
        _expect_reject(
            "5_1_carrier_7_1_claim",
            lambda: model.validate_descriptor(
                {
                    "source_layout": "5.1_side",
                    "container_layout": "7.1",
                    "report_container_as_native": True,
                }
            ),
            "false_native_claim",
        ),
        _expect_reject(
            "mask_zero",
            lambda: model.layout_from_mask(0, 6),
            "unsupported_layout",
        ),
    ]
    rejection_status = "pass" if all(item["status"] == "pass" for item in rejections) else "fail"

    sections = {
        "matrix": matrix,
        "endpoint": endpoint,
        "latency": latency,
        "buffer": buffer,
        "layers": layers,
        "wav": wav_checks,
        "clipping": clipping,
        "rejections": {
            "status": rejection_status,
            "items": rejections,
        },
    }
    failed = [name for name, value in sections.items() if value["status"] != "pass"]
    fixture_sources = {
        layout: {
            key: info[key]
            for key in ("channels", "frames", "mask", "peak", "rate", "sha256")
        }
        for layout, info in manifest["sources"].items()
    }
    return {
        "status": "pass" if not failed else "fail",
        "failed_sections": failed,
        "playback": False,
        "fixture_case_count": len(cases),
        "fixture_sources": fixture_sources,
        "sections": sections,
        "limits": [
            "Offline reference model only; no driver, player, browser, or HomePod was used.",
            "Two HomePods can only verify downmix/front routing, not 5.1/7.1 acoustics.",
            "10/12-channel height layouts are reserved, not first-round hardware gates.",
            "Real captures still need source/player/container/acoustic evidence.",
        ],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print full JSON")
    args = parser.parse_args()
    result = run()
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            json.dumps(
                {
                    "status": result["status"],
                    "failed_sections": result["failed_sections"],
                    "fixture_case_count": result["fixture_case_count"],
                    "section_status": {
                        name: value["status"] for name, value in result["sections"].items()
                    },
                },
                indent=2,
                sort_keys=True,
            )
        )
    raise SystemExit(0 if result["status"] == "pass" else 1)

