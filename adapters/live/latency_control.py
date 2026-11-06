"""Pure latency-budget arithmetic and strict Core Audio report validation.

This module intentionally has no pyatv, native library, HAL or process imports:
both the request parser and the live session can import it without side
effects. Everything here documents or checks numbers that other owned
components measured or negotiated, never fabricates an acoustic result.
"""
from __future__ import annotations

import math

# Single named scheduling constant shared by the live session. The 500 ms
# preparation/lead budget is part of every sample's continuous presentation
# mapping, not a one-time startup wait that disappears after playback begins.
PREPARATION_MS = 500

# Previously observed product-device latency used only for the default runtime
# estimate (66150 negotiated samples at 44100 Hz plus the shared preparation).
OBSERVED_LATENCY_SAMPLES = 66150
OBSERVED_SAMPLE_RATE = 44100

# Exact product 8-channel virtual device that hflctl (017) owns. The worker
# only reads and compares these values through an app-side verified report.
PRODUCT_DEVICE_UID = "com.homepodflow.virtual-audio.surround71.v1"
PRODUCT_MODEL_UID = "com.homepodflow.virtual-audio.model.surround71.v1"
PRODUCT_CHANNELS = 8
ALLOWED_SAMPLE_RATES = (44100, 48000)

MIN_LATENCY_MS = 0
MAX_LATENCY_MS = 3000

_NANOS_PER_MILLI = 1_000_000
_NANOS_PER_SECOND = 1_000_000_000


def default_estimate_ms() -> int:
    """Fallback estimate when no calibrated latency value is configured."""
    return OBSERVED_LATENCY_SAMPLES * 1000 // OBSERVED_SAMPLE_RATE + PREPARATION_MS


def _checked_inputs(latency_samples: int, sample_rate: int) -> None:
    if type(latency_samples) is not int or latency_samples < 0:
        raise ValueError("negotiated latency must be a nonnegative integer sample count")
    if type(sample_rate) is not int or sample_rate not in ALLOWED_SAMPLE_RATES:
        raise ValueError("unsupported negotiated sample rate")


def protocol_latency_ns(latency_samples: int, sample_rate: int) -> int:
    """RAOP negotiated latency expressed in monotonic nanoseconds."""
    _checked_inputs(latency_samples, sample_rate)
    return latency_samples * _NANOS_PER_SECOND // sample_rate


def preparation_ns() -> int:
    """The shared preparation budget in monotonic nanoseconds."""
    return PREPARATION_MS * _NANOS_PER_MILLI


def playback_lead_ns(latency_samples: int, sample_rate: int) -> int:
    """First-PCM receipt + negotiated latency + shared preparation (unchanged)."""
    return protocol_latency_ns(latency_samples, sample_rate) + preparation_ns()


def negotiated_latency_ms(latency_samples: int, sample_rate: int) -> int:
    """Negotiated protocol latency rounded to the nearest millisecond."""
    _checked_inputs(latency_samples, sample_rate)
    return (latency_samples * 1000 + sample_rate // 2) // sample_rate


def planned_presentation_ms(latency_samples: int, sample_rate: int) -> int:
    """Programmed nominal presentation: negotiated latency plus preparation."""
    return negotiated_latency_ms(latency_samples, sample_rate) + PREPARATION_MS


def _require_number(value, label: str) -> float:
    if type(value) not in (int, float) or not math.isfinite(float(value)):
        raise ValueError(label + " must be a finite number")
    return float(value)


def _require_int(value, label: str) -> int:
    if type(value) is not int:
        raise ValueError(label + " must be an integer")
    return value


def _require_bool(value, label: str) -> bool:
    if value not in (True, False):
        raise ValueError(label + " must be a boolean")
    return value


def validate_latency_report(value) -> dict:
    """Strictly accept a verified hflctl status transcript.

    The app produces this from ``hflctl status`` after its own write/no-write
    decision. The worker rejects anything not verified, not the exact product
    8ch device, or with inconsistent stream-scope/control values.
    """
    if not isinstance(value, dict):
        raise ValueError("latency_report must be an object")
    if value.get("verified") is not True:
        raise ValueError("latency_report is not a verified read")
    required = {
        "tool", "command", "uid", "model_uid", "channels", "nominal_rate",
        "hfla_frames", "hfla_ms", "hflr", "stream_latency_global_frames",
        "stream_latency_output_frames", "latency_scopes_match",
        "control_scope_match", "device_is_running",
    }
    missing = required - set(value)
    if missing:
        raise ValueError("latency_report missing fields: " + ", ".join(sorted(missing)))
    if value.get("tool") != "hflctl" or value.get("command") != "status":
        raise ValueError("latency_report must be an hflctl status read")
    if value.get("uid") != PRODUCT_DEVICE_UID or value.get("model_uid") != PRODUCT_MODEL_UID:
        raise ValueError("latency_report is not the exact product 8ch device")
    channels = _require_int(value.get("channels"), "channels")
    if channels != PRODUCT_CHANNELS:
        raise ValueError("latency_report channels must be 8")

    rate = _require_number(value.get("nominal_rate"), "nominal_rate")
    if rate not in ALLOWED_SAMPLE_RATES:
        raise ValueError("latency_report nominal_rate must be 44100 or 48000")
    hfla_frames = _require_int(value.get("hfla_frames"), "hfla_frames")
    revision = _require_int(value.get("hflr"), "hflr")
    if revision < 1:
        raise ValueError("latency_report hflr must be >= 1")
    if not 0 <= hfla_frames <= 10 * rate:
        raise ValueError("latency_report hfla_frames exceeds the 10*rate contract ceiling")
    hfla_ms = _require_number(value.get("hfla_ms"), "hfla_ms")
    if not MIN_LATENCY_MS <= hfla_ms <= MAX_LATENCY_MS:
        raise ValueError("latency_report hfla_ms outside the 0..3000 product envelope")
    expected_ms = hfla_frames * 1000.0 / rate
    if not math.isclose(hfla_ms, expected_ms, rel_tol=0.0, abs_tol=0.51):
        raise ValueError("latency_report hfla_ms does not match hfla_frames at nominal_rate")

    global_frames = _require_int(value.get("stream_latency_global_frames"),
                                 "stream_latency_global_frames")
    output_frames = _require_int(value.get("stream_latency_output_frames"),
                                 "stream_latency_output_frames")
    if not (global_frames == output_frames == hfla_frames):
        raise ValueError("latency_report stream scopes do not both match hfla")
    if value.get("latency_scopes_match") is not True or value.get("control_scope_match") is not True:
        raise ValueError("latency_report latency/control scopes are not both confirmed matching")
    running = _require_bool(value.get("device_is_running"), "device_is_running")

    return {
        "verified": True,
        "tool": "hflctl",
        "command": "status",
        "uid": PRODUCT_DEVICE_UID,
        "model_uid": PRODUCT_MODEL_UID,
        "channels": PRODUCT_CHANNELS,
        "nominal_rate": rate,
        "hfla_frames": hfla_frames,
        "hfla_ms": hfla_ms,
        "hflr": revision,
        "stream_latency_global_frames": global_frames,
        "stream_latency_output_frames": output_frames,
        "latency_scopes_match": True,
        "control_scope_match": True,
        "device_is_running": running,
    }


def latency_comparison(latency_samples: int, sample_rate: int, latency_report: dict) -> dict:
    """Signed difference between the negotiated nominal plan and the report."""
    negotiated = negotiated_latency_ms(latency_samples, sample_rate)
    reported = float(latency_report["hfla_ms"])
    return {
        "programmed_kind": "negotiated_protocol_latency_ms",
        "programmed_ms": negotiated,
        "reported_kind": "core_audio_hfla_ms",
        "reported_ms": reported,
        "signed_difference_ms": round(negotiated - reported),
        "sign_meaning": "positive means the negotiated plan is later than the reported stream latency",
    }


def plan_telemetry(latency_samples: int, sample_rate: int, latency_report=None) -> dict:
    """Calculated scheduling plan, separated from any acoustic measurement."""
    normalized = validate_latency_report(latency_report) if latency_report is not None else None
    negotiated = negotiated_latency_ms(latency_samples, sample_rate)
    plan = {
        "preparation_ms": PREPARATION_MS,
        "negotiated_latency_samples": latency_samples,
        "sample_rate": sample_rate,
        "negotiated_latency_ms": negotiated,
        "planned_presentation_ms": negotiated + PREPARATION_MS,
        "report_verified": normalized is not None,
        "programmed_model": {
            "kind": "nominal_plan",
            "basis": "python_first_pcm_receipt + negotiated_protocol_latency_ms + shared_preparation_ms",
        },
    }
    if normalized is not None:
        plan["acoustic_measurement"] = {
            "kind": "core_audio_stream_latency_property",
            "source": "hflctl_status_read",
            "hfla_ms": normalized["hfla_ms"],
            "hfla_frames": normalized["hfla_frames"],
            "hflr": normalized["hflr"],
        }
        plan["programmed_vs_reported_ms"] = latency_comparison(
            latency_samples, sample_rate, normalized)
        plan["residual_claimed_zero"] = False
        plan["unknown_components"] = [
            "python_capture_to_receipt",
            "converter",
            "tap_and_acoustic_path",
            "network_and_receiver_playout",
        ]
    return plan
