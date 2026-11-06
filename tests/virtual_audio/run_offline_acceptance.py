"""Run the offline multichannel acceptance suite aligned to contract v1.

Generates deterministic fixtures in a temporary directory, checks every route
matrix and capture transform, renders a representative WAV subset, verifies
channel identity/order with narrow-band projection, and exercises rejection/
latency/buffer/layer gates.

No audio is played or captured; no device is changed; no SSH/Git is used.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
from typing import Dict, List

import analyze_multichannel_capture as analyzer
import make_multichannel_fixtures as fixtures
import multichannel_model as model
import multichannel_wav as wav


SELECTED_WAV_CASES = (
    "MC-A01",  # mono identity (M)
    "MC-A02",  # stereo identity
    "MC-A05",  # 5.1 side identity
    "MC-A07",  # 7.1 identity, side-before-back order
    "MC-A08",  # 5.1.2 reserved identity
    "MC-B03",  # stereo -> 5.1 side padded
    "MC-B06",  # 3.0 -> 5.1 side padded
    "MC-B09",  # 4.0 -> 5.1 back padded
    "MC-B14",  # 7.1 -> 7.1.2 reserved padded
    "MC-C01",  # 3.0 -> stereo
    "MC-C02",  # 4.0 -> stereo
    "MC-C03",  # 5.1 side -> stereo (LFE discarded)
    "MC-C06",  # 7.1 -> 5.1 side (0.5/0.5)
    "MC-C08",  # 7.1.2 -> 7.1 reserved
    "MC-D01",  # 4.0 -> 5.1 side remap
    "MC-E01",  # mono -> stereo mono map
    "MC-G-7_1-6",
    "MC-G-7_1-2",
    "MC-G-5_1_side-2",
    "MC-H03",  # 7.1.2 -> 8 reserved
)


def _plan_for_case(case: Dict[str, object]) -> model.RoutePlan:
    source = str(case["source_layout"])
    target = str(case["target_layout"])
    if case["kind"] == "endpoint":
        return model.build_endpoint_route(source, model.channel_count_for(target))
    return model.build_route(source, target, str(case["mode"]))


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


def _capture_checks() -> Dict[str, object]:
    failures: List[str] = []
    rows: Dict[str, object] = {}
    cases = [
        ("identity_mono", "mono", "mono", "identity", "source_native"),
        ("identity_7_1", "7.1", "7.1", "identity", "source_native"),
        ("stereo_to_7_1", "stereo", "7.1", "pad_silent",
         "stereo_passthrough_in_multichannel"),
        ("3_0_to_5_1_back", "3.0", "5.1_back", "pad_silent", "source_padded"),
        ("4_0_to_7_1", "4.0_quad", "7.1", "pad_silent", "source_padded"),
        ("5_1_side_to_7_1", "5.1_side", "7.1", "pad_silent", "source_padded"),
        ("5_1_back_to_7_1", "5.1_back", "7.1", "pad_silent", "source_padded"),
    ]
    for name, source, container, kind, provenance in cases:
        try:
            plan = model.plan_capture(source, container)
            model.validate_capture_claims(plan)
            if (plan.kind, plan.provenance) != (kind, provenance):
                failures.append(
                    f"{name}: got {(plan.kind, plan.provenance)!r}"
                )
            for label in ("downmix", "upmix", "remap", "gain", "lfe_fold"):
                if label in plan.transformations:
                    failures.append(f"{name}: capture contains {label}")
            rows[name] = {
                "kind": plan.kind,
                "provenance": plan.provenance,
                "silent_slots": plan.silent_slots,
                "native_claim": plan.native_claim,
            }
        except Exception as error:  # noqa: BLE001
            failures.append(f"{name}: {type(error).__name__}: {error}")

    refusals = [
        ("7_1_to_5_1_side", "7.1", "5.1_side", "source_exceeds_container"),
        ("5_1_side_to_5_1_back", "5.1_side", "5.1_back", "container_layout_mismatch"),
        ("5_1_back_to_5_1_side", "5.1_back", "5.1_side", "container_layout_mismatch"),
        ("4_0_to_5_1_side", "4.0_quad", "5.1_side", "container_layout_mismatch"),
        ("mono_to_stereo", "mono", "stereo", "container_layout_mismatch"),
        ("3_0_to_4_0", "3.0", "4.0_quad", "container_layout_mismatch"),
    ]
    for name, source, container, code in refusals:
        plan = model.plan_capture(source, container)
        if plan.kind != "refused" or plan.error != code:
            failures.append(f"{name}: got {(plan.kind, plan.error)!r}")
        rows[name] = {"kind": plan.kind, "error": plan.error}
    return {
        "rows": rows,
        "failures": failures,
        "status": "pass" if not failures else "fail",
    }


def _matrix_checks(cases: List[Dict[str, object]]) -> Dict[str, object]:
    failures: List[str] = []
    for case in cases:
        try:
            plan = _plan_for_case(case)
            model.validate_route_claims(plan)
            if model.max_row_l1(plan.matrix) > 1.0 + 1e-12:
                failures.append(f"{case['case']}: row L1 > 1")
            if list(plan.channel_order) != list(model.labels_for(plan.container_layout)):
                failures.append(f"{case['case']}: channelOrder mismatch")
            if len(plan.labels) != plan.container_channel_count:
                failures.append(f"{case['case']}: label/container count mismatch")
            if plan.provenance != "native" and plan.reported_as_native_5_1_or_7_1:
                failures.append(f"{case['case']}: non-native 5.1/7.1 claim")
            if plan.matrix_id == "":
                failures.append(f"{case['case']}: empty matrix id")
            tones = model.expected_tones(plan)
            if set(tones) != set(plan.labels):
                failures.append(f"{case['case']}: expected tone labels mismatch")
        except Exception as error:  # noqa: BLE001
            failures.append(f"{case['case']}: {type(error).__name__}: {error}")
    return {"case_count": len(cases), "failures": failures,
            "status": "pass" if not failures else "fail"}


def _endpoint_checks() -> Dict[str, object]:
    table = {
        "mono": {1: "native", 2: "mono_map", 3: "mono_map",
                 4: "mono_map", 6: "mono_map", 8: "mono_map"},
        "stereo": {2: "native", 3: "padded", 4: "padded",
                   6: "padded", 8: "padded"},
        "3.0": {2: "downmix", 3: "native", 6: "padded", 8: "padded"},
        "4.0_quad": {2: "downmix", 4: "native", 6: "padded", 8: "padded"},
        "5.1_side": {2: "downmix", 6: "native", 8: "padded"},
        "5.1_back": {2: "downmix", 6: "native", 8: "padded"},
        "7.1": {2: "downmix", 6: "downmix", 8: "native"},
    }
    rows: Dict[str, object] = {}
    failures: List[str] = []
    for source, counts in table.items():
        rows[source] = {}
        for count, mode in counts.items():
            try:
                plan = model.build_endpoint_route(source, count)
                claim = model.acoustic_claim_for(source, count)
                if plan.mode != mode:
                    failures.append(f"{source}->{count}: mode {plan.mode} != {mode}")
                if model.max_row_l1(plan.matrix) > 1.0 + 1e-12:
                    failures.append(f"{source}->{count}: row L1 > 1")
                if count == 2 and source in model.SURROUND_LAYOUTS:
                    if claim != "stereo_downmix":
                        failures.append(f"{source}->2: claim {claim}")
                if count == 6 and source in ("5.1_side", "5.1_back"):
                    if claim != source:
                        failures.append(f"{source}->6: claim {claim} != {source}")
                rows[source][str(count)] = {
                    "target_layout": plan.container_layout,
                    "mode": plan.mode,
                    "matrix_id": plan.matrix_id,
                    "acoustic_claim": claim,
                }
            except Exception as error:  # noqa: BLE001
                failures.append(f"{source}->{count}: {type(error).__name__}: {error}")
    for source, count in [("stereo", 1), ("3.0", 4), ("5.1_side", 3),
                          ("5.1_back", 4), ("7.1", 3)]:
        try:
            model.build_endpoint_route(source, count)
        except model.RejectError as error:
            if error.code != "route_unsupported":
                failures.append(f"{source}->{count}: expected route_unsupported")
        else:
            failures.append(f"{source}->{count}: should be route_unsupported")
    return {"matrix": rows, "failures": failures,
            "status": "pass" if not failures else "fail"}


def _latency_checks() -> Dict[str, object]:
    failures: List[str] = []
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
    if not all(value for value in checks.values() if isinstance(value, bool)):
        failures.append("one or more latency assertions failed")
    return {"checks": checks, "failures": failures,
            "status": "pass" if not failures else "fail"}


def _buffer_checks() -> Dict[str, object]:
    failures: List[str] = []
    checks = {}
    device = model.DeviceClock("buffer")
    revision = device.revision
    for value in (15, 16, 255, 256, 512, 1024, 4096):
        try:
            device.set_buffer(value)
            device.accept_io_frames(value)
        except model.RejectError as error:
            failures.append(f"buffer {value}: {error}")
    checks["buffer_range_accepted"] = not failures
    checks["revision_unchanged"] = device.revision == revision
    checks["period_independent"] = device.zero_timestamp_period == 16384
    checks["driver_value_not_authoritative"] = device.driver_reported_buffer == 512

    # Contract §7.2: DoIO accepts 0..4096 even though buffer Set is 15..4096.
    for value in (0, 1, 14, 4095, 4096):
        try:
            device.accept_io_frames(value)
        except model.RejectError as error:
            failures.append(f"DoIO {value} should accept: {error}")
    checks["doio_zero_accepted"] = not _raises_io(device, 0)
    for value in (-1, 4097):
        if not _raises_io(device, value):
            failures.append(f"DoIO {value} should reject")
    for value in (0, 14, 4097):
        try:
            device.set_buffer(value)
        except model.RejectError:
            pass
        else:
            failures.append(f"buffer {value} should reject")
    return {"checks": checks, "failures": failures,
            "status": "pass" if not failures else "fail"}


def _raises_io(device: model.DeviceClock, value: int) -> bool:
    try:
        device.accept_io_frames(value)
    except model.RejectError:
        return True
    return False


def _layer_checks() -> Dict[str, object]:
    failures: List[str] = []
    claims = {
        "mono->1": model.acoustic_claim_for("mono", 1),
        "mono->2": model.acoustic_claim_for("mono", 2),
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
        failures.append("5.1 on six endpoints with native route may claim 5.1_side")
    if claims["mono->2"] != "stereo_mono_map":
        failures.append("mono on stereo endpoints must claim stereo_mono_map")
    if claims["7.1->8"] != "7.1":
        failures.append("7.1 on eight endpoints with native route may claim 7.1")

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
    failures.extend(item["name"] for item in rejections if item["status"] != "pass")
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
                "matrix_id": plan.matrix_id,
                "channel_order": list(plan.channel_order),
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
            ("M",),
            {"M": [1.5, -1.5]},
            mask=model.mask_for("mono"),
        )
    except wav.ClippingError:
        guard = True
    else:
        guard = False
        failures.append("clipping guard did not reject 1.5 full scale")
    return {
        "stress_peak": measured_peak,
        "matrix_id": plan.matrix_id,
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
        capture = _capture_checks()
        endpoint = _endpoint_checks()
        latency = _latency_checks()
        buffer = _buffer_checks()
        layers = _layer_checks()
        wav_checks = _wav_checks(temp, cases)
        clipping = _clipping_checks(temp)

    io_device = model.DeviceClock("reject")
    rejections = [
        _expect_reject(
            "unknown_source_layout",
            lambda: model.build_route("unknown", "stereo"),
            "unsupported_layout",
        ),
        _expect_reject(
            "ambiguous_5_1",
            lambda: model.build_route("5.1", "stereo"),
            "source_layout_ambiguous",
        ),
        _expect_reject(
            "ambiguous_8ch",
            lambda: model.build_route("8ch", "7.1"),
            "source_layout_ambiguous",
        ),
        _expect_reject(
            "ambiguous_10ch",
            lambda: model.build_route("10ch", "7.1"),
            "source_layout_ambiguous",
        ),
        _expect_reject(
            "unsupported_5_1_4",
            lambda: model.build_route("5.1.4", "7.1"),
            "unsupported_layout",
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
            "capture_side_to_back",
            lambda: model.require_capture("5.1_side", "5.1_back"),
            "container_layout_mismatch",
        ),
        _expect_reject(
            "capture_back_to_side",
            lambda: model.require_capture("5.1_back", "5.1_side"),
            "container_layout_mismatch",
        ),
        _expect_reject(
            "capture_7_1_to_5_1",
            lambda: model.require_capture("7.1", "5.1_side"),
            "source_exceeds_container",
        ),
        _expect_reject(
            "capture_quad_to_5_1_side",
            lambda: model.require_capture("4.0_quad", "5.1_side"),
            "container_layout_mismatch",
        ),
        _expect_reject(
            "capture_mono_to_stereo",
            lambda: model.require_capture("mono", "stereo"),
            "container_layout_mismatch",
        ),
        _expect_reject(
            "flow_3_0_to_4_0",
            lambda: model.build_route("3.0", "4.0_quad"),
            "route_unsupported",
        ),
        _expect_reject(
            "flow_5_1_to_3_0",
            lambda: model.build_route("5.1_side", "3.0"),
            "route_unsupported",
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
        _expect_reject(
            "doio_4097",
            lambda: io_device.accept_io_frames(4097),
            "unsupported_io_frames",
        ),
        _expect_reject(
            "buffer_zero",
            lambda: io_device.set_buffer(0),
            "unsupported_buffer",
        ),
    ]
    rejection_status = "pass" if all(item["status"] == "pass" for item in rejections) else "fail"

    sections = {
        "matrix": matrix,
        "capture": capture,
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
        "contract": "MULTICHANNEL_CONTRACT.md v1",
        "fixture_case_count": len(cases),
        "fixture_sources": fixture_sources,
        "sections": sections,
        "limits": [
            "Offline reference model only; no driver, player, browser, or HomePod was used.",
            "Capture is identity/pad_silent/refused only; downmix/remap/upmix are Flow plans.",
            "Two HomePods can only verify downmix/front routing, not 5.1/7.1 acoustics.",
            "5.1.2/7.1.2/7.1.4 are RES naming/order checks, not first-round hardware gates.",
            "Real captures still need 6/8ch device tap, endpoints, and acoustic evidence.",
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
