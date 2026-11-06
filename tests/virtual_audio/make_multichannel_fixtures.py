"""Generate deterministic source-first multichannel fixtures (contract v1).

Writes one distinct-tone source WAV per accepted layout plus expected route
JSON files. It never plays audio, captures, installs, or touches a device.
No FFmpeg or network dependency is used.

The 84 cases are contract-v1 cells: identity, capture-valid padding, explicit
Flow downmix/remap/mono-map/upmix, endpoint capability cells, and reserved
height checks. Capture refusals live in the test suite and offline runner, not
in the renderable fixture set.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List

import multichannel_model as model
import multichannel_wav as wav


SOURCE_FILES: Dict[str, str] = {
    "mono": "mono_source.wav",
    "stereo": "stereo_source.wav",
    "3.0": "3_0_source.wav",
    "4.0_quad": "quad_source.wav",
    "5.1_side": "5_1_side_source.wav",
    "5.1_back": "5_1_back_source.wav",
    "7.1": "7_1_source.wav",
    "5.1.2": "5_1_2_source.wav",
    "7.1.2": "7_1_2_source.wav",
    "7.1.4": "7_1_4_source.wav",
}

REQUIRED_SOURCES = ("mono", "stereo", "3.0", "4.0_quad",
                    "5.1_side", "5.1_back", "7.1")
RESERVED_SOURCES = ("5.1.2", "7.1.2", "7.1.4")


def _case(
    case_id: str,
    source: str,
    target: str,
    mode: str = "auto",
    *,
    kind: str = "container",
    note: str = "",
    reserved: bool = False,
) -> Dict[str, object]:
    return {
        "case": case_id,
        "source_layout": source,
        "target_layout": target,
        "mode": mode,
        "kind": kind,
        "note": note,
        "reserved": reserved,
    }


def build_cases() -> List[Dict[str, object]]:
    cases: List[Dict[str, object]] = []

    # A. Identity (10 layouts, including reserved height naming/order).
    for index, source in enumerate(SOURCE_FILES, start=1):
        cases.append(
            _case(
                f"MC-A{index:02d}",
                source,
                source,
                "identity",
                note="source equals container",
                reserved=source in RESERVED_SOURCES,
            )
        )

    # B. Capture-valid padding (source labels are an exact subset).
    pads = [
        ("stereo", "3.0"),
        ("stereo", "4.0_quad"),
        ("stereo", "5.1_side"),
        ("stereo", "5.1_back"),
        ("stereo", "7.1"),
        ("3.0", "5.1_side"),
        ("3.0", "5.1_back"),
        ("3.0", "7.1"),
        ("4.0_quad", "5.1_back"),
        ("4.0_quad", "7.1"),
        ("5.1_side", "7.1"),
        ("5.1_back", "7.1"),
        ("5.1.2", "7.1.2"),
        ("7.1", "7.1.2"),
        ("7.1.2", "7.1.4"),
        # Reserved height containers.
        ("5.1.2", "7.1.4"),
        ("7.1", "7.1.4"),
        ("5.1_side", "7.1.2"),
        ("5.1_back", "7.1.2"),
        ("3.0", "7.1.2"),
    ]
    for index, (source, target) in enumerate(pads, start=1):
        cases.append(
            _case(
                f"MC-B{index:02d}",
                source,
                target,
                "passthrough",
                note="source_padded; target-only slots must be exact +0.0",
                reserved=target in RESERVED_SOURCES,
            )
        )

    # C. Explicit Flow downmix (capture already had a container >= source).
    downmix = [
        ("3.0", "stereo"),
        ("4.0_quad", "stereo"),
        ("5.1_side", "stereo"),
        ("5.1_back", "stereo"),
        ("7.1", "stereo"),
        ("7.1", "5.1_side"),
        ("7.1", "5.1_back"),
        # Reserved height folds.
        ("7.1.2", "7.1"),
        ("7.1.4", "7.1.2"),
        ("5.1.2", "7.1"),
        ("5.1.2", "5.1_side"),
    ]
    for index, (source, target) in enumerate(downmix, start=1):
        cases.append(
            _case(
                f"MC-C{index:02d}",
                source,
                target,
                "downmix",
                note="explicit label-aware downmix; losses recorded",
                reserved=source in RESERVED_SOURCES or target in RESERVED_SOURCES,
            )
        )

    # D. Explicit layout remaps (never native).
    remaps = [
        ("4.0_quad", "5.1_side"),
        ("5.1_side", "5.1_back"),
        ("5.1_back", "5.1_side"),
    ]
    for index, (source, target) in enumerate(remaps, start=1):
        cases.append(
            _case(
                f"MC-D{index:02d}",
                source,
                target,
                "remap",
                note="explicit position remap; not native 5.1",
            )
        )

    # E. Mono map (contract §5.3.1, not an upmix).
    mono_targets = ["stereo", "3.0", "4.0_quad", "5.1_side", "5.1_back", "7.1"]
    for index, target in enumerate(mono_targets, start=1):
        cases.append(
            _case(
                f"MC-E{index:02d}",
                "mono",
                target,
                "auto",
                note="mono map; not native multichannel",
            )
        )

    # F. Explicit stereo cinema upmix (default off, not native).
    cases.append(_case("MC-F01", "stereo", "5.1_side", "upmix",
                       note="M_ST_51S; explicit fallback, not native"))
    cases.append(_case("MC-F02", "stereo", "7.1", "upmix",
                       note="M_ST_71; explicit fallback, not native"))

    # G. Contract §5.2 endpoint capability cells (valid cells only).
    endpoint_cells = {
        "mono": (1, 2, 3, 4, 6, 8),
        "stereo": (2, 3, 4, 6, 8),
        "3.0": (2, 3, 6, 8),
        "4.0_quad": (2, 4, 6, 8),
        "5.1_side": (2, 6, 8),
        "5.1_back": (2, 6, 8),
        "7.1": (2, 6, 8),
    }
    for source in REQUIRED_SOURCES:
        for count in endpoint_cells[source]:
            target = model.endpoint_layout_for(source, count)
            cases.append(
                _case(
                    f"MC-G-{source.replace('.', '_')}-{count}",
                    source,
                    target,
                    "auto",
                    kind="endpoint",
                    note=f"{count} endpoints; target {target}; no acoustic claim",
                )
            )

    # H. Reserved height endpoint cells.
    cases.append(_case("MC-H01", "7.1.2", "7.1.2", "auto", kind="endpoint",
                       note="reserved 10ch identity", reserved=True))
    cases.append(_case("MC-H02", "7.1.4", "7.1.4", "auto", kind="endpoint",
                       note="reserved 12ch identity", reserved=True))
    cases.append(_case("MC-H03", "7.1.2", "7.1", "auto", kind="endpoint",
                       note="reserved 10ch -> 8", reserved=True))
    cases.append(_case("MC-H04", "7.1.4", "7.1.2", "auto", kind="endpoint",
                       note="reserved 12ch -> 10", reserved=True))
    return cases


def expected_for_case(case: Dict[str, object]) -> Dict[str, object]:
    source = str(case["source_layout"])
    target = str(case["target_layout"])
    mode = str(case["mode"])
    if case["kind"] == "endpoint":
        count = model.channel_count_for(target)
        plan = model.build_endpoint_route(source, count)
    else:
        plan = model.build_route(source, target, mode)

    model.validate_route_claims(plan)
    tones = model.expected_tones(plan)
    return {
        "case": case["case"],
        "kind": case["kind"],
        "note": case["note"],
        "reserved": case["reserved"],
        "source_layout": plan.source_layout,
        "container_layout": plan.container_layout,
        "source_channels": plan.source_channel_count,
        "container_channels": plan.container_channel_count,
        "channel_order": list(plan.channel_order),
        "labels": list(plan.labels),
        "rate": 48000,
        "duration_s": model.FIXTURE_DURATION_SECONDS,
        "amplitude": model.FIXTURE_AMPLITUDE,
        "mode": plan.mode,
        "matrix_id": plan.matrix_id,
        "provenance": plan.provenance,
        "native": plan.native,
        "losses": {key: list(value) for key, value in plan.losses.items()},
        "ui_label": plan.ui_label,
        "transformations": list(plan.transformations),
        "native_layout_claim": plan.native_layout_claim,
        "report_container_as_native": plan.report_container_as_native,
        "reported_as_native_5_1_or_7_1": plan.reported_as_native_5_1_or_7_1,
        "matrix": plan.matrix,
        "max_row_l1": model.max_row_l1(plan.matrix),
        "headroom_db": model.headroom_db(plan.matrix),
        "metadata": plan.metadata,
        "warnings": list(plan.warnings),
        "tones": {
            label: {str(frequency): amplitude for frequency, amplitude in values.items()}
            for label, values in tones.items()
        },
        "tone_map": dict(model.FIXTURE_TONES),
        "status": "expected_from_offline_reference_model_not_capture",
    }


def create(output: Path) -> Dict[str, object]:
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    expected_dir = output / "expected"
    expected_dir.mkdir()

    source_manifest: Dict[str, object] = {}
    for layout, filename in SOURCE_FILES.items():
        labels = model.labels_for(layout)
        samples = wav.source_samples(labels, model.FIXTURE_TONES)
        info = wav.write_wav(
            output / filename,
            48000,
            labels,
            samples,
            mask=model.mask_for(layout),
        )
        source_manifest[layout] = info

    cases = build_cases()
    case_files = []
    for case in cases:
        expected = expected_for_case(case)
        filename = f"{case['case']}.json"
        (expected_dir / filename).write_text(
            json.dumps(expected, indent=2, sort_keys=True), encoding="utf-8"
        )
        case_files.append(
            {
                "case": case["case"],
                "source_layout": case["source_layout"],
                "target_layout": case["target_layout"],
                "kind": case["kind"],
                "reserved": case["reserved"],
                "expected": f"expected/{filename}",
            }
        )

    manifest = {
        "status": "offline_fixture_only_not_playback",
        "contract": "MULTICHANNEL_CONTRACT.md v1",
        "rate": 48000,
        "duration_s": model.FIXTURE_DURATION_SECONDS,
        "amplitude": model.FIXTURE_AMPLITUDE,
        "tone_map": model.FIXTURE_TONES,
        "sources": source_manifest,
        "required_sources": list(REQUIRED_SOURCES),
        "reserved_sources": list(RESERVED_SOURCES),
        "case_count": len(case_files),
        "cases": case_files,
        "endpoint_matrix": model.endpoint_matrix(),
        "notes": [
            "No audio was played, captured, or routed.",
            "Capture is identity/pad_silent/refused only; downmix/remap/upmix belong to Flow.",
            "mono label is M; 7.1 order is FL FR FC LFE SL SR BL BR.",
            "5.1.2/7.1.2/7.1.4 use TFL/TFR/TRL/TRR and are RES, not first-round hardware gates.",
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
    )
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New local directory")
    args = parser.parse_args()
    print(json.dumps(create(args.output), indent=2, sort_keys=True))
