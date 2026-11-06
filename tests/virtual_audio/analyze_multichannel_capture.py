"""Analyze an offline multichannel WAV against an expected route JSON.

This is a numeric check of channel identity, label order, expected tone
amplitude, crosstalk, DC, and clipping. It does not play, capture, or infer a
source layout from silence. A real capture must still be accompanied by the
source/player/container/acoustic evidence described in MULTICHANNEL_ACCEPTANCE.md.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Dict, List, Optional

import multichannel_model as model
import multichannel_wav as wav


def analyze_capture(
    capture_path: Path,
    expected_path: Path,
    *,
    rel_tol: float = 0.03,
    abs_tol: float = 0.002,
    crosstalk_db: float = -50.0,
    allow_unknown_mask: bool = False,
) -> Dict[str, object]:
    expected = json.loads(Path(expected_path).read_text(encoding="utf-8"))
    capture = wav.read_wav(Path(capture_path))
    labels = list(expected["labels"])
    failures: List[str] = []
    warnings: List[str] = []
    checks: List[Dict[str, object]] = []

    if capture.rate != int(expected["rate"]):
        failures.append(f"rate {capture.rate} != expected {expected['rate']}")
    if capture.channels != len(labels):
        failures.append(f"channel count {capture.channels} != expected {len(labels)}")

    slot_identity_verified = False
    if capture.mask == 0:
        if allow_unknown_mask:
            warnings.append(
                "WAV has no channel mask; channel order is taken from expected JSON, "
                "so slot identity is unverified"
            )
        else:
            failures.append("WAV has no channel mask; cannot verify label/slot identity")
    else:
        try:
            actual_layout = model.layout_from_mask(capture.mask, capture.channels)
        except model.RejectError as error:
            failures.append(f"mask/layout rejection: {error}")
        else:
            if actual_layout != expected["container_layout"]:
                failures.append(
                    f"mask layout {actual_layout} != expected {expected['container_layout']}"
                )
            elif list(model.labels_for(actual_layout)) != labels:
                failures.append("mask-derived label order differs from expected")
            else:
                slot_identity_verified = True

    if capture.channels != len(labels):
        return {
            "status": "fail",
            "case": expected.get("case"),
            "failures": failures,
            "warnings": warnings,
            "not_playback_evidence": True,
        }

    expected_tones: Dict[str, Dict[int, float]] = {
        label: {int(frequency): float(amplitude) for frequency, amplitude in values.items()}
        for label, values in expected["tones"].items()
    }
    all_frequencies = sorted(set(model.FIXTURE_TONES.values()))
    global_expected_max = max(
        (amplitude for values in expected_tones.values() for amplitude in values.values()),
        default=0.0,
    )
    crosstalk_limit = global_expected_max * (10.0 ** (crosstalk_db / 20.0))

    for index, label in enumerate(labels):
        samples = capture.samples[index]
        peak_value = wav.peak(samples)
        dc_value = wav.dc(samples)
        checks.append(
            {
                "channel": label,
                "rms": round(wav.rms(samples), 8),
                "peak": round(peak_value, 8),
                "dc": round(dc_value, 8),
                "tones": {},
            }
        )
        if peak_value > 1.0 + 1e-6:
            failures.append(f"{label}: clipping peak {peak_value:.6f}")
        if abs(dc_value) > 0.002:
            failures.append(f"{label}: DC offset {dc_value:.6f}")

        for frequency in all_frequencies:
            measured = wav.project_amplitude(samples, capture.rate, frequency)
            wanted = expected_tones.get(label, {}).get(frequency, 0.0)
            entry = checks[-1]["tones"]
            assert isinstance(entry, dict)
            entry[str(frequency)] = {
                "expected": round(wanted, 8),
                "measured": round(measured, 8),
            }
            if wanted > 0:
                tolerance = max(abs_tol, rel_tol * wanted)
                if abs(measured - wanted) > tolerance:
                    failures.append(
                        f"{label}@{frequency}Hz: measured {measured:.6f}, "
                        f"expected {wanted:.6f} +/- {tolerance:.6f}"
                    )
            elif measured > crosstalk_limit:
                failures.append(
                    f"{label}@{frequency}Hz: crosstalk {measured:.6f} > "
                    f"{crosstalk_limit:.6f} ({crosstalk_db:g} dB)"
                )

    status = "pass" if not failures else "fail"
    if status == "pass" and not slot_identity_verified:
        status = "pass_unverified_mask"
    return {
        "status": status,
        "case": expected.get("case"),
        "source_layout": expected.get("source_layout"),
        "container_layout": expected.get("container_layout"),
        "slot_identity_verified": slot_identity_verified,
        "channel_count": capture.channels,
        "rate": capture.rate,
        "mask": f"0x{capture.mask:04X}",
        "checks": checks,
        "failures": failures,
        "warnings": warnings,
        "thresholds": {
            "relative_tolerance": rel_tol,
            "absolute_tolerance": abs_tol,
            "crosstalk_db": crosstalk_db,
        },
        "not_playback_evidence": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--expected", required=True, type=Path)
    parser.add_argument("--relative-tolerance", type=float, default=0.03)
    parser.add_argument("--absolute-tolerance", type=float, default=0.002)
    parser.add_argument("--crosstalk-db", type=float, default=-50.0)
    parser.add_argument("--allow-unknown-mask", action="store_true")
    args = parser.parse_args()
    result = analyze_capture(
        args.capture,
        args.expected,
        rel_tol=args.relative_tolerance,
        abs_tol=args.absolute_tolerance,
        crosstalk_db=args.crosstalk_db,
        allow_unknown_mask=args.allow_unknown_mask,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0 if result["status"] in ("pass", "pass_unverified_mask") else 1)

