"""Offline multichannel model aligned to MULTICHANNEL_CONTRACT.md v1.

Source-first model with the contract's two layers kept separate:

* capture: only ``identity`` / ``pad_silent`` / ``refused``. It never
  downmixes, upmixes, remaps, applies gain, or folds LFE.
* Flow route planning: ``native`` / ``padded`` / ``layout_remap`` /
  ``downmix`` / ``front_pair`` / ``upmix`` / ``mono_map``.

Contract v1 facts encoded here:

* mono label is ``M`` (not FC);
* 7.1 order is ``FL FR FC LFE SL SR BL BR`` (side before back);
* height layouts are 5.1.2 / 7.1.2 / 7.1.4 with ``TFL/TFR/TRL/TRR``;
* a source narrower than the container is padded with exact ``+0.0`` and
  reported as ``source_padded``;
* a source wider than the container is refused at capture with
  ``source_exceeds_container`` and only downmixed later by Flow;
* coefficients below follow contract §5.3 (float64 formulas, float32 use);
* DoIO accepts 0..4096 frames while buffer Set accepts 15..4096.

No audio I/O, playback, capture, network, SSH, or device access.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Dict, List, Mapping, Optional, Sequence, Tuple


# Exact contract §5.3 constants. Documentation shows six decimals; the
# implementation must use the exact formulas so row L1 is exactly 1.
SQRT_HALF = math.sqrt(0.5)                 # e = 0.707107
A_COEFF = math.sqrt(2.0) - 1.0             # a = 0.414214
B_COEFF = 1.0 - math.sqrt(2.0) / 2.0       # b = 0.292893
C_COEFF = B_COEFF / 2.0                    # c = 0.146447
D_COEFF = 1.0 / (1.0 + SQRT_HALF)          # d = 0.585786
F_COEFF = 1.0 / (2.0 * math.sqrt(2.0))     # f = 0.353553

FIXTURE_AMPLITUDE = 0.25
FIXTURE_DURATION_SECONDS = 1.0

# M and FC share 557 Hz because they are never slots of the same layout; the
# analyzer still requires the source layout in the expected JSON.
FIXTURE_TONES: Dict[str, int] = {
    "M": 557,
    "FL": 317,
    "FR": 431,
    "FC": 557,
    "LFE": 61,
    "SL": 733,
    "SR": 863,
    "BL": 977,
    "BR": 1103,
    "TFL": 1301,
    "TFR": 1451,
    "TRL": 1601,
    "TRR": 1751,
}

ALLOWED_LABELS = (
    "M", "FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR",
    "TFL", "TFR", "TRL", "TRR",
)

R1_LAYOUTS = ("mono", "stereo", "3.0", "4.0_quad", "5.1_side", "5.1_back", "7.1")
RES_LAYOUTS = ("5.1.2", "7.1.2", "7.1.4")
SURROUND_LAYOUTS = ("5.1_side", "5.1_back", "7.1", "5.1.2", "7.1.2", "7.1.4")

# Canonical channel order is contract §3.1 / HAL order, not WAVE mask bit order.
LAYOUTS: Dict[str, Tuple[str, ...]] = {
    "mono": ("M",),
    "stereo": ("FL", "FR"),
    "3.0": ("FL", "FR", "FC"),
    "4.0_quad": ("FL", "FR", "BL", "BR"),
    "5.1_side": ("FL", "FR", "FC", "LFE", "SL", "SR"),
    "5.1_back": ("FL", "FR", "FC", "LFE", "BL", "BR"),
    "7.1": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"),
    "5.1.2": ("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR"),
    "7.1.2": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR"),
    "7.1.4": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR",
              "TFL", "TFR", "TRL", "TRR"),
}

# WAVE speaker-mask carriers used only by the offline fixtures. mono is a
# fixture carrier for the M slot; the real HAL identity is
# kAudioChannelLayoutTag_Mono, not the FC mask.
LAYOUT_MASKS: Dict[str, int] = {
    "mono": 0x00000004,
    "stereo": 0x00000003,
    "3.0": 0x00000007,
    "4.0_quad": 0x00000033,
    "5.1_side": 0x0000060F,
    "5.1_back": 0x0000003F,
    "7.1": 0x0000063F,
    "5.1.2": 0x0000560F,
    "7.1.2": 0x0000563F,
    "7.1.4": 0x0002D63F,
}

CONTRACT_LAYOUT_TOKEN: Dict[str, str] = {
    "mono": "mono",
    "stereo": "stereo",
    "3.0": "3_0",
    "4.0_quad": "4_0",
    "5.1_side": "5_1_side",
    "5.1_back": "5_1_back",
    "7.1": "7_1",
    "5.1.2": "5_1_2",
    "7.1.2": "7_1_2",
    "7.1.4": "7_1_4",
}

MIN_BUFFER_FRAMES = 15
MAX_BUFFER_FRAMES = 4096
MIN_IO_FRAMES = 0
MAX_IO_FRAMES = 4096
ZERO_TIMESTAMP_PERIOD = 16384
DRIVER_REPORTED_BUFFER = 512
MAX_PAYLOAD_V2 = 196608
SUPPORTED_RATES = (44100, 48000)
REQUIRED_ENDPOINT_COUNTS = (1, 2, 3, 6, 8)
RESERVED_ENDPOINT_COUNTS = (4, 10, 12)


class RejectError(ValueError):
    def __init__(self, code: str, detail: str = ""):
        self.code = code
        self.detail = detail
        super().__init__(code if not detail else f"{code}: {detail}")


def normalize_layout_name(name: str) -> str:
    if not isinstance(name, str):
        raise RejectError("unsupported_layout", "layout name must be a string")
    aliases = {
        "mono": "mono", "1.0": "mono", "1ch": "mono",
        "stereo": "stereo", "2.0": "stereo", "2ch": "stereo",
        "3.0": "3.0", "3_0": "3.0",
        "4.0": "4.0_quad", "4_0": "4.0_quad", "4.0_quad": "4.0_quad",
        "quad": "4.0_quad",
        "5.1_side": "5.1_side", "5_1_side": "5.1_side",
        "5.1-side": "5.1_side", "5.1(side)": "5.1_side",
        "5.1_back": "5.1_back", "5_1_back": "5.1_back",
        "5.1-back": "5.1_back", "5.1(back)": "5.1_back",
        "7.1": "7.1", "7_1": "7.1",
        "5.1.2": "5.1.2", "5_1_2": "5.1.2",
        "7.1.2": "7.1.2", "7_1_2": "7.1.2",
        "7.1.4": "7.1.4", "7_1_4": "7.1.4",
    }
    key = name.strip().lower()
    if key in ("5.1", "5.1ch", "6ch"):
        raise RejectError("source_layout_ambiguous",
                          "6ch must state 5.1 side or 5.1 back")
    if key in ("8ch",):
        raise RejectError("source_layout_ambiguous", "8ch may be 7.1 or 5.1.2")
    if key in ("10ch",):
        raise RejectError("source_layout_ambiguous", "10ch may be 7.1.2 or 5.1.4")
    if key in ("12ch",):
        raise RejectError("source_layout_ambiguous", "12ch must state 7.1.4")
    if key == "5.1.4":
        raise RejectError("unsupported_layout", "5.1.4 is not accepted; 10ch is 7.1.2")
    if key not in aliases:
        raise RejectError("unsupported_layout", f"unknown layout {name!r}")
    return aliases[key]


def labels_for(name: str) -> Tuple[str, ...]:
    return LAYOUTS[normalize_layout_name(name)]


def channel_order(name: str) -> Tuple[str, ...]:
    """Contract channelOrder for a layout (assert this, never mask order)."""
    return labels_for(name)


def contract_token(name: str) -> str:
    return CONTRACT_LAYOUT_TOKEN[normalize_layout_name(name)]


def mask_for(name: str) -> int:
    return LAYOUT_MASKS[normalize_layout_name(name)]


def channel_count_for(name: str) -> int:
    return len(labels_for(name))


def validate_labels(labels: Sequence[str], expected_layout: Optional[str] = None,
                    *, require_known: bool = True) -> str:
    values = tuple(labels)
    if not values:
        raise RejectError("unsupported_layout", "empty channel label list")
    if require_known:
        for value in values:
            if value not in ALLOWED_LABELS:
                raise RejectError("unsupported_layout", f"unknown channel label {value!r}")
    if len(set(values)) != len(values):
        raise RejectError("duplicate_label", f"duplicate labels in {values!r}")
    if expected_layout is not None:
        canonical = labels_for(expected_layout)
        if values != canonical:
            raise RejectError("unsupported_layout",
                              f"slot order {values!r} does not match {canonical!r}")
        return normalize_layout_name(expected_layout)
    for name, canonical in LAYOUTS.items():
        if values == canonical:
            return name
    raise RejectError("unsupported_layout",
                      f"labels {values!r} do not match a canonical layout")


def layout_from_mask(mask: int, channel_count: int) -> str:
    if channel_count <= 0 or channel_count > 64:
        raise RejectError("unsupported_layout", f"invalid channel count {channel_count}")
    if mask == 0:
        raise RejectError("unsupported_layout",
                          "channel mask is absent; silence/count cannot identify layout")
    for name, expected_mask in LAYOUT_MASKS.items():
        if mask == expected_mask:
            if len(LAYOUTS[name]) != channel_count:
                raise RejectError("unsupported_layout", "mask/channel count mismatch")
            return name
    raise RejectError("unsupported_layout", f"unregistered channel mask {mask:#x}")


def infer_layout_from_silence(*_args, **_kwargs) -> str:
    raise RejectError("silence_does_not_identify_layout",
                      "cannot infer layout from active/silent channels")


# ---------------------------------------------------------------------------
# Capture layer: identity / pad_silent / refused only
# ---------------------------------------------------------------------------

CAPTURE_KINDS = ("identity", "pad_silent", "refused")
CAPTURE_PROVENANCE = (
    "source_native",
    "source_padded",
    "stereo_passthrough_in_multichannel",
    "source_upstream_mapped",
    "unknown_restricted",
)


@dataclass
class CapturePlan:
    source_layout: str
    container_layout: str
    kind: str
    provenance: str
    placed: List[Dict[str, object]] = field(default_factory=list)
    silent_slots: List[int] = field(default_factory=list)
    transformations: List[str] = field(default_factory=list)
    native_claim: bool = False
    error: Optional[str] = None
    detail: str = ""

    @property
    def refused(self) -> bool:
        return self.kind == "refused"

    def as_dict(self) -> Dict[str, object]:
        return {
            "source_layout": self.source_layout,
            "container_layout": self.container_layout,
            "kind": self.kind,
            "provenance": self.provenance,
            "placed": list(self.placed),
            "silent_slots": list(self.silent_slots),
            "transformations": list(self.transformations),
            "native_claim": self.native_claim,
            "error": self.error,
            "detail": self.detail,
        }


def plan_capture(source_layout: str, container_layout: str, *,
                 authority: str = "decoder", verified: bool = True,
                 upstream_transform: str = "none_known") -> CapturePlan:
    """Plan the capture transform only; never downmix/upmix/remap.

    ``refused`` is a normal result (the caller can inspect ``error``). Use
    :func:`require_capture` when a refusal should raise ``RejectError``.
    """
    source = normalize_layout_name(source_layout)
    container = normalize_layout_name(container_layout)
    source_labels = labels_for(source)
    container_labels = labels_for(container)

    if source == container:
        if upstream_transform != "none_known":
            return CapturePlan(
                source, container, "identity", "source_upstream_mapped",
                placed=[{"sourceLabel": label, "slot": index}
                        for index, label in enumerate(source_labels)],
                transformations=["identity"], native_claim=False,
            )
        native = bool(verified and authority in ("decoder", "device"))
        return CapturePlan(
            source, container, "identity", "source_native",
            placed=[{"sourceLabel": label, "slot": index}
                    for index, label in enumerate(source_labels)],
            transformations=["identity"], native_claim=native,
        )

    if len(source_labels) > len(container_labels):
        return CapturePlan(
            source, container, "refused", "unknown_restricted",
            error="source_exceeds_container",
            detail="capture must not downmix; choose a larger container",
        )

    missing = [label for label in source_labels if label not in container_labels]
    if missing:
        return CapturePlan(
            source, container, "refused", "unknown_restricted",
            error="container_layout_mismatch",
            detail=f"source labels {missing!r} have no same-name container slot",
        )

    placed = [
        {"sourceLabel": label, "slot": container_labels.index(label)}
        for label in source_labels
    ]
    silent = [index for index, label in enumerate(container_labels)
              if label not in set(source_labels)]
    if source == "stereo" and container != "stereo":
        provenance = "stereo_passthrough_in_multichannel"
        transformations = ["stereo_passthrough"]
        native = False
    else:
        provenance = "source_padded"
        if source == "5.1_side" and container == "7.1":
            transformations = ["pad_5_1_side_to_7_1"]
        elif source == "5.1_back" and container == "7.1":
            transformations = ["pad_5_1_back_to_7_1"]
        else:
            transformations = ["pad_silent"]
        native = bool(verified and authority in ("decoder", "device"))
    return CapturePlan(
        source, container, "pad_silent", provenance,
        placed=placed, silent_slots=silent,
        transformations=transformations, native_claim=native,
    )


def require_capture(source_layout: str, container_layout: str, **kwargs) -> CapturePlan:
    plan = plan_capture(source_layout, container_layout, **kwargs)
    if plan.refused:
        raise RejectError(plan.error or "capture_refused", plan.detail)
    return plan


# ---------------------------------------------------------------------------
# Flow route planning: native / padded / layout_remap / downmix / upmix / mono_map
# ---------------------------------------------------------------------------

Matrix = Dict[str, Dict[str, float]]


def empty_matrix(labels: Sequence[str]) -> Matrix:
    return {label: {} for label in labels}


def set_coefficient(matrix: Matrix, output: str, source: str, value: float) -> None:
    if value:
        matrix.setdefault(output, {})[source] = float(value)


def _matrix(target: Sequence[str], rows: Mapping[str, Mapping[str, float]]) -> Matrix:
    matrix = empty_matrix(target)
    for output, row in rows.items():
        if output not in matrix:
            raise RejectError("internal_matrix_error", f"unknown output {output}")
        for source, value in row.items():
            set_coefficient(matrix, output, source, value)
    return matrix


def identity_matrix(layout: str) -> Matrix:
    return {label: {label: 1.0} for label in labels_for(layout)}


def passthrough_matrix(source_layout: str, target_layout: str) -> Matrix:
    source = labels_for(source_layout)
    target = labels_for(target_layout)
    matrix = empty_matrix(target)
    for label in source:
        if label not in target:
            raise RejectError("container_layout_mismatch",
                              f"source label {label} has no slot in {target_layout}")
        set_coefficient(matrix, label, label, 1.0)
    return matrix


def row_l1(row: Mapping[str, float]) -> float:
    return sum(abs(value) for value in row.values())


def max_row_l1(matrix: Matrix) -> float:
    return max((row_l1(row) for row in matrix.values()), default=0.0)


def headroom_db(matrix: Matrix) -> float:
    bound = max_row_l1(matrix)
    return float("inf") if bound == 0 else -20.0 * math.log10(bound)


def _m_mono_2() -> Matrix:
    return _matrix(("FL", "FR"), {"FL": {"M": SQRT_HALF}, "FR": {"M": SQRT_HALF}})


def _m_mono_fc() -> Matrix:
    return _matrix(("FC",), {"FC": {"M": 1.0}})


def _m_mono_40() -> Matrix:
    return _matrix(("FL", "FR", "BL", "BR"),
                   {"FL": {"M": 0.5}, "FR": {"M": 0.5},
                    "BL": {"M": 0.5}, "BR": {"M": 0.5}})


def _m_30_2() -> Matrix:
    return _matrix(("FL", "FR"), {
        "FL": {"FL": D_COEFF, "FC": A_COEFF},
        "FR": {"FR": D_COEFF, "FC": A_COEFF},
    })


def _m_40_2() -> Matrix:
    return _matrix(("FL", "FR"), {
        "FL": {"FL": D_COEFF, "BL": A_COEFF},
        "FR": {"FR": D_COEFF, "BR": A_COEFF},
    })


def _m_51s_2() -> Matrix:
    return _matrix(("FL", "FR"), {
        "FL": {"FL": A_COEFF, "FC": B_COEFF, "SL": B_COEFF},
        "FR": {"FR": A_COEFF, "FC": B_COEFF, "SR": B_COEFF},
    })


def _m_51b_2() -> Matrix:
    return _matrix(("FL", "FR"), {
        "FL": {"FL": A_COEFF, "FC": B_COEFF, "BL": B_COEFF},
        "FR": {"FR": A_COEFF, "FC": B_COEFF, "BR": B_COEFF},
    })


def _m_71_2() -> Matrix:
    return _matrix(("FL", "FR"), {
        "FL": {"FL": A_COEFF, "FC": B_COEFF, "SL": C_COEFF, "BL": C_COEFF},
        "FR": {"FR": A_COEFF, "FC": B_COEFF, "SR": C_COEFF, "BR": C_COEFF},
    })


def _m_71_6() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0}, "FC": {"FC": 1.0},
        "LFE": {"LFE": 1.0},
        "SL": {"SL": 0.5, "BL": 0.5},
        "SR": {"SR": 0.5, "BR": 0.5},
    })


def _m_71_6b() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "BL", "BR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0}, "FC": {"FC": 1.0},
        "LFE": {"LFE": 1.0},
        "BL": {"BL": 0.5, "SL": 0.5},
        "BR": {"BR": 0.5, "SR": 0.5},
    })


def _m_51s_6b() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "BL", "BR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0}, "FC": {"FC": 1.0},
        "LFE": {"LFE": 1.0}, "BL": {"SL": 1.0}, "BR": {"SR": 1.0},
    })


def _m_51b_6() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0}, "FC": {"FC": 1.0},
        "LFE": {"LFE": 1.0}, "SL": {"BL": 1.0}, "SR": {"BR": 1.0},
    })


def _m_40_51s() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0},
        "SL": {"BL": 1.0}, "SR": {"BR": 1.0},
    })


def _m_st_51s() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": SQRT_HALF},
        "FR": {"FR": SQRT_HALF},
        "FC": {"FL": F_COEFF, "FR": F_COEFF},
        "SL": {"FL": 0.5, "FR": -0.5},
        "SR": {"FL": -0.5, "FR": 0.5},
    })


def _m_st_71() -> Matrix:
    matrix = _m_st_51s()
    matrix["BL"] = {}
    matrix["BR"] = {}
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"), matrix)


def _m_512_71() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"), {
        "FL": {"FL": 0.5, "TFL": 0.5},
        "FR": {"FR": 0.5, "TFR": 0.5},
        "FC": {"FC": 1.0}, "LFE": {"LFE": 1.0},
        "SL": {"SL": 1.0}, "SR": {"SR": 1.0},
    })


def _m_512_51s() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": 0.5, "TFL": 0.5},
        "FR": {"FR": 0.5, "TFR": 0.5},
        "FC": {"FC": 1.0}, "LFE": {"LFE": 1.0},
        "SL": {"SL": 1.0}, "SR": {"SR": 1.0},
    })


def _m_712_71() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"), {
        "FL": {"FL": 0.5, "TFL": 0.5},
        "FR": {"FR": 0.5, "TFR": 0.5},
        "FC": {"FC": 1.0}, "LFE": {"LFE": 1.0},
        "SL": {"SL": 1.0}, "SR": {"SR": 1.0},
        "BL": {"BL": 1.0}, "BR": {"BR": 1.0},
    })


def _m_712_51s() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR"), {
        "FL": {"FL": 0.5, "TFL": 0.5},
        "FR": {"FR": 0.5, "TFR": 0.5},
        "FC": {"FC": 1.0}, "LFE": {"LFE": 1.0},
        "SL": {"SL": 0.5, "BL": 0.5},
        "SR": {"SR": 0.5, "BR": 0.5},
    })


def _m_714_712() -> Matrix:
    return _matrix(("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR",
                    "TFL", "TFR"), {
        "FL": {"FL": 1.0}, "FR": {"FR": 1.0}, "FC": {"FC": 1.0},
        "LFE": {"LFE": 1.0}, "SL": {"SL": 1.0}, "SR": {"SR": 1.0},
        "BL": {"BL": 1.0}, "BR": {"BR": 1.0},
        "TFL": {"TFL": 0.5, "TRL": 0.5},
        "TFR": {"TFR": 0.5, "TRR": 0.5},
    })


def _m_714_2() -> Matrix:
    """Reserved-only 7.1.4 -> stereo fold; never an R1 native/downmix claim."""
    left = {
        "FL": B_COEFF,
        "FC": A_COEFF / 2.0,
        "SL": A_COEFF / 4.0,
        "BL": A_COEFF / 4.0,
        "TFL": C_COEFF,
        "TRL": C_COEFF,
    }
    right = {
        "FR": B_COEFF,
        "FC": A_COEFF / 2.0,
        "SR": A_COEFF / 4.0,
        "BR": A_COEFF / 4.0,
        "TFR": C_COEFF,
        "TRR": C_COEFF,
    }
    return _matrix(("FL", "FR"), {"FL": left, "FR": right})


MATRIX_BUILDERS = {
    "M_MONO_2": _m_mono_2,
    "M_MONO_FC": _m_mono_fc,
    "M_MONO_40": _m_mono_40,
    "M_30_2": _m_30_2,
    "M_40_2": _m_40_2,
    "M_51S_2": _m_51s_2,
    "M_51B_2": _m_51b_2,
    "M_71_2": _m_71_2,
    "M_71_6": _m_71_6,
    "M_71_6B": _m_71_6b,
    "M_51S_6B": _m_51s_6b,
    "M_51B_6": _m_51b_6,
    "M_40_51S": _m_40_51s,
    "M_ST_51S": _m_st_51s,
    "M_ST_71": _m_st_71,
    # RES height matrices: reserved QA model only, never R1 hardware claims.
    "M_512_71": _m_512_71,
    "M_512_51S": _m_512_51s,
    "M_712_71": _m_712_71,
    "M_712_51S": _m_712_51s,
    "M_714_712": _m_714_712,
    "M_714_2": _m_714_2,
}

# Contract §5.2 capability table. Codes:
# N native, P padded, P/U default padded + explicit upmix, D downmix,
# R layout remap, M mono map; absent key = route_unsupported ("—").
ROUTE_TABLE: Dict[Tuple[str, str], Tuple[str, Optional[str]]] = {
    ("mono", "mono"): ("N", None),
    ("mono", "stereo"): ("M", "M_MONO_2"),
    ("mono", "3.0"): ("M", "M_MONO_FC"),
    ("mono", "4.0_quad"): ("M", "M_MONO_40"),
    ("mono", "5.1_side"): ("M", "M_MONO_FC"),
    ("mono", "5.1_back"): ("M", "M_MONO_FC"),
    ("mono", "7.1"): ("M", "M_MONO_FC"),

    ("stereo", "stereo"): ("N", None),
    ("stereo", "3.0"): ("P", None),
    ("stereo", "4.0_quad"): ("P", None),
    ("stereo", "5.1_side"): ("PU", "M_ST_51S"),
    ("stereo", "5.1_back"): ("P", None),
    ("stereo", "7.1"): ("PU", "M_ST_71"),

    ("3.0", "3.0"): ("N", None),
    ("3.0", "stereo"): ("D", "M_30_2"),
    ("3.0", "5.1_side"): ("P", None),
    ("3.0", "5.1_back"): ("P", None),
    ("3.0", "7.1"): ("P", None),

    ("4.0_quad", "4.0_quad"): ("N", None),
    ("4.0_quad", "stereo"): ("D", "M_40_2"),
    ("4.0_quad", "5.1_side"): ("R", "M_40_51S"),
    ("4.0_quad", "5.1_back"): ("P", None),
    ("4.0_quad", "7.1"): ("P", None),

    ("5.1_side", "5.1_side"): ("N", None),
    ("5.1_side", "stereo"): ("D", "M_51S_2"),
    ("5.1_side", "5.1_back"): ("R", "M_51S_6B"),
    ("5.1_side", "7.1"): ("P", None),

    ("5.1_back", "5.1_back"): ("N", None),
    ("5.1_back", "stereo"): ("D", "M_51B_2"),
    ("5.1_back", "5.1_side"): ("R", "M_51B_6"),
    ("5.1_back", "7.1"): ("P", None),

    ("7.1", "7.1"): ("N", None),
    ("7.1", "stereo"): ("D", "M_71_2"),
    ("7.1", "5.1_side"): ("D", "M_71_6"),
    ("7.1", "5.1_back"): ("D", "M_71_6B"),

    # RES height layouts: naming/order and reserved matrices only.
    ("5.1.2", "5.1.2"): ("N", None),
    ("5.1.2", "7.1"): ("D", "M_512_71"),
    ("5.1.2", "5.1_side"): ("D", "M_512_51S"),
    ("5.1.2", "7.1.2"): ("P", None),
    ("5.1.2", "7.1.4"): ("P", None),
    ("7.1.2", "7.1.2"): ("N", None),
    ("7.1.2", "7.1"): ("D", "M_712_71"),
    ("7.1.2", "5.1_side"): ("D", "M_712_51S"),
    ("7.1.2", "7.1.4"): ("P", None),
    ("7.1.4", "7.1.4"): ("N", None),
    ("7.1.4", "7.1.2"): ("D", "M_714_712"),
    ("7.1.4", "stereo"): ("D", "M_714_2"),
    ("7.1", "7.1.2"): ("P", None),
    ("7.1", "7.1.4"): ("P", None),
    ("5.1_side", "7.1.2"): ("P", None),
    ("5.1_back", "7.1.2"): ("P", None),
    ("3.0", "7.1.2"): ("P", None),
}

DOWNMIX_LOSSES: Dict[str, Tuple[List[str], List[str]]] = {
    "M_30_2": (["FC"], []),
    "M_40_2": (["BL", "BR"], []),
    "M_51S_2": (["FC", "SL", "SR"], ["LFE"]),
    "M_51B_2": (["FC", "BL", "BR"], ["LFE"]),
    "M_71_2": (["FC", "SL", "SR", "BL", "BR"], ["LFE"]),
    "M_71_6": (["BL", "BR"], []),
    "M_71_6B": (["SL", "SR"], []),
    "M_512_71": (["TFL", "TFR"], []),
    "M_512_51S": (["TFL", "TFR"], []),
    "M_712_71": (["TFL", "TFR"], []),
    "M_712_51S": (["TFL", "TFR", "BL", "BR"], []),
    "M_714_712": (["TRL", "TRR"], []),
    "M_714_2": (["FC", "SL", "SR", "BL", "BR", "TFL", "TFR", "TRL", "TRR"],
                ["LFE"]),
}

REMAP_LOSSES: Dict[str, List[str]] = {
    "M_40_51S": ["BL->SL", "BR->SR"],
    "M_51S_6B": ["SL->BL", "SR->BR"],
    "M_51B_6": ["BL->SL", "BR->SR"],
}


@dataclass
class RoutePlan:
    source_layout: str
    container_layout: str
    mode: str
    matrix: Matrix
    matrix_id: str
    provenance: str
    losses: Dict[str, List[str]] = field(default_factory=dict)
    ui_label: str = ""
    transformations: List[str] = field(default_factory=list)
    metadata: Dict[str, object] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)

    @property
    def native(self) -> bool:
        return self.provenance == "native"

    @property
    def labels(self) -> Tuple[str, ...]:
        return tuple(self.matrix.keys())

    @property
    def channel_order(self) -> Tuple[str, ...]:
        return self.labels

    @property
    def source_channel_count(self) -> int:
        return channel_count_for(self.source_layout)

    @property
    def container_channel_count(self) -> int:
        return channel_count_for(self.container_layout)

    @property
    def source_is_discrete_multichannel(self) -> bool:
        return self.source_channel_count > 2

    @property
    def source_is_native_surround(self) -> bool:
        return self.source_layout in SURROUND_LAYOUTS

    @property
    def container_is_native_for_source(self) -> bool:
        return self.source_layout == self.container_layout

    @property
    def native_layout_claim(self) -> Optional[str]:
        return self.container_layout if self.native else None

    @property
    def report_container_as_native(self) -> bool:
        return self.native

    @property
    def reported_as_native_5_1_or_7_1(self) -> bool:
        return self.native and self.container_layout in SURROUND_LAYOUTS

    def as_dict(self) -> Dict[str, object]:
        return {
            "source_layout": self.source_layout,
            "container_layout": self.container_layout,
            "source_channels": self.source_channel_count,
            "container_channels": self.container_channel_count,
            "channel_order": list(self.channel_order),
            "labels": list(self.labels),
            "mode": self.mode,
            "matrix_id": self.matrix_id,
            "provenance": self.provenance,
            "native": self.native,
            "losses": {key: list(value) for key, value in self.losses.items()},
            "ui_label": self.ui_label,
            "transformations": list(self.transformations),
            "source_is_discrete_multichannel": self.source_is_discrete_multichannel,
            "source_is_native_surround": self.source_is_native_surround,
            "container_is_native_for_source": self.container_is_native_for_source,
            "native_layout_claim": self.native_layout_claim,
            "report_container_as_native": self.report_container_as_native,
            "reported_as_native_5_1_or_7_1": self.reported_as_native_5_1_or_7_1,
            "matrix": self.matrix,
            "max_row_l1": max_row_l1(self.matrix),
            "headroom_db": headroom_db(self.matrix),
            "metadata": self.metadata,
            "warnings": list(self.warnings),
        }


def _ui_label(source: str, target: str, provenance: str) -> str:
    if provenance == "native":
        return f"{target}（源原生）"
    if provenance == "padded":
        if source == "stereo":
            return "立体声（仅前置 L/R，其余静音）"
        return f"{source} 源在 {target} 容器（多出通道静音）"
    if provenance == "layout_remap":
        return f"{source} → {target} 位置重映射（非原生）"
    if provenance == "mono_map":
        return f"{source} → {target} 单声道分配（非原生）"
    if provenance == "upmix":
        return "立体声上混（影院，非原生）"
    if provenance == "downmix" and target == "stereo":
        return f"{source} → 立体声下混（LFE 丢弃）"
    return f"{source} → {target} 下混"


def _padded_plan(source: str, target: str) -> RoutePlan:
    matrix = passthrough_matrix(source, target)
    silent = [label for label in labels_for(target) if label not in labels_for(source)]
    return RoutePlan(
        source, target, "padded", matrix, f"M_PAD_{source}_{target}", "padded",
        losses={"silent": silent},
        ui_label=_ui_label(source, target, "padded"),
        transformations=["pad_silent"],
        metadata={"silent_container_slots": silent},
    )


def _downmix_plan(source: str, target: str, matrix_id: str) -> RoutePlan:
    builder = MATRIX_BUILDERS[matrix_id]
    matrix = builder()
    downmixed, discarded = DOWNMIX_LOSSES.get(matrix_id, ([], []))
    return RoutePlan(
        source, target, "downmix", matrix, matrix_id, "downmix",
        losses={"downmixed": list(downmixed), "discarded": list(discarded)},
        ui_label=_ui_label(source, target, "downmix"),
        transformations=[f"downmix:{matrix_id}"],
        metadata={"matrix_id": matrix_id, "max_row_l1": max_row_l1(matrix)},
    )


def _remap_plan(source: str, target: str, matrix_id: str) -> RoutePlan:
    matrix = MATRIX_BUILDERS[matrix_id]()
    return RoutePlan(
        source, target, "layout_remap", matrix, matrix_id, "layout_remap",
        losses={"remapped": list(REMAP_LOSSES.get(matrix_id, []))},
        ui_label=_ui_label(source, target, "layout_remap"),
        transformations=[f"layout_remap:{matrix_id}"],
        metadata={"matrix_id": matrix_id, "max_row_l1": max_row_l1(matrix)},
    )


def _mono_plan(source: str, target: str, matrix_id: str) -> RoutePlan:
    # Keep every target slot present so channelOrder and container count agree;
    # slots without a mono destination stay exact +0.0 (empty row).
    raw = MATRIX_BUILDERS[matrix_id]()
    matrix = {label: dict(raw.get(label, {})) for label in labels_for(target)}
    return RoutePlan(
        source, target, "mono_map", matrix, matrix_id, "mono_map",
        losses={"mapped": ["M"]},
        ui_label=_ui_label(source, target, "mono_map"),
        transformations=[f"mono_map:{matrix_id}"],
        metadata={"matrix_id": matrix_id, "max_row_l1": max_row_l1(matrix)},
    )


def _upmix_plan(source: str, target: str, matrix_id: str) -> RoutePlan:
    matrix = MATRIX_BUILDERS[matrix_id]()
    upmixed = [label for label in labels_for(target) if label not in labels_for(source)]
    return RoutePlan(
        source, target, "upmix", matrix, matrix_id, "upmix",
        losses={"upmixed": upmixed},
        ui_label=_ui_label(source, target, "upmix"),
        transformations=[f"upmix:{matrix_id}"],
        metadata={"matrix_id": matrix_id, "max_row_l1": max_row_l1(matrix),
                  "lfe_synthesized": False},
    )


def _native_plan(source: str, target: str) -> RoutePlan:
    return RoutePlan(
        source, target, "native", identity_matrix(target), f"M_ID_{target}", "native",
        losses={}, ui_label=_ui_label(source, target, "native"),
        transformations=["identity"],
        metadata={"max_row_l1": 1.0},
    )


def build_route(source_layout: str, target_layout: str, mode: str = "auto") -> RoutePlan:
    """Build a Flow route plan (not a capture transform).

    ``mode`` is ``auto`` or one of ``identity``/``passthrough``/``downmix``/
    ``remap``/``upmix``. A narrower capture container must be refused with
    :func:`plan_capture`; this function plans after capture succeeded.
    """
    source = normalize_layout_name(source_layout)
    target = normalize_layout_name(target_layout)
    if mode not in ("auto", "identity", "passthrough", "downmix", "remap", "upmix"):
        raise RejectError("unsupported_mode", f"unknown route mode {mode!r}")

    if mode == "upmix":
        if source != "stereo" or target not in ("5.1_side", "7.1"):
            raise RejectError("transform_unavailable",
                              "only M_ST_51S / M_ST_71 are registered")
        return _upmix_plan(source, target,
                           "M_ST_51S" if target == "5.1_side" else "M_ST_71")

    cell = ROUTE_TABLE.get((source, target))
    if cell is None:
        raise RejectError("route_unsupported",
                          f"no R1 matrix for {source} -> {target}")
    code, matrix_id = cell

    if mode == "identity" and code != "N":
        raise RejectError("mode_mismatch", "identity requires equal layouts")
    if mode == "passthrough" and code not in ("P", "PU"):
        raise RejectError("mode_mismatch", f"{source} -> {target} is not padded")
    if mode == "downmix" and code != "D":
        raise RejectError("mode_mismatch", f"{source} -> {target} is not a downmix")
    if mode == "remap" and code != "R":
        raise RejectError("mode_mismatch", f"{source} -> {target} is not a remap")

    if code == "N":
        return _native_plan(source, target)
    if code in ("P", "PU"):
        return _padded_plan(source, target)
    if code == "R":
        assert matrix_id is not None
        return _remap_plan(source, target, matrix_id)
    if code == "D":
        assert matrix_id is not None
        return _downmix_plan(source, target, matrix_id)
    if code == "M":
        assert matrix_id is not None
        return _mono_plan(source, target, matrix_id)
    raise RejectError("internal_route_error", code)


def endpoint_layout_for(source_layout: str, speaker_count: int) -> str:
    source = normalize_layout_name(source_layout)
    if speaker_count not in REQUIRED_ENDPOINT_COUNTS + RESERVED_ENDPOINT_COUNTS:
        raise RejectError("unsupported_endpoint_count", str(speaker_count))
    if speaker_count == 1:
        return "mono"
    if speaker_count == 2:
        return "stereo"
    if speaker_count == 3:
        return "3.0"
    if speaker_count == 4:
        return "4.0_quad"
    if speaker_count == 6:
        return "5.1_back" if source in ("5.1_back", "4.0_quad") else "5.1_side"
    if speaker_count == 8:
        return "7.1"
    if speaker_count == 10:
        return "7.1.2"
    return "7.1.4"


def build_endpoint_route(source_layout: str, speaker_count: int) -> RoutePlan:
    target = endpoint_layout_for(source_layout, speaker_count)
    plan = build_route(source_layout, target, "auto")
    plan.metadata["endpoint_count"] = speaker_count
    plan.metadata["endpoint_layout"] = target
    return plan


def endpoint_matrix(sources: Sequence[str] = ("mono", "stereo", "3.0", "4.0_quad",
                                              "5.1_side", "5.1_back", "7.1"),
                    counts: Sequence[int] = REQUIRED_ENDPOINT_COUNTS
                    ) -> Dict[str, Dict[int, Dict[str, object]]]:
    result: Dict[str, Dict[int, Dict[str, object]]] = {}
    for source in sources:
        row: Dict[int, Dict[str, object]] = {}
        for count in counts:
            try:
                plan = build_endpoint_route(source, count)
            except RejectError as error:
                row[count] = {"error": error.code}
                continue
            row[count] = {"target_layout": plan.container_layout, "mode": plan.mode,
                          "matrix_id": plan.matrix_id, "labels": list(plan.labels),
                          "matrix": plan.matrix,
                          "transformations": list(plan.transformations)}
        result[source] = row
    return result


def expected_tones(plan: RoutePlan, tones: Mapping[str, int] = FIXTURE_TONES,
                   amplitude: float = FIXTURE_AMPLITUDE) -> Dict[str, Dict[int, float]]:
    output: Dict[str, Dict[int, float]] = {label: {} for label in plan.labels}
    for output_label, row in plan.matrix.items():
        for source_label, coefficient in row.items():
            frequency = tones.get(source_label)
            if frequency is None:
                continue
            output[output_label][frequency] = (
                output[output_label].get(frequency, 0.0) + abs(coefficient) * amplitude)
    return output


def validate_route_claims(plan: RoutePlan) -> None:
    if not plan.native and plan.report_container_as_native:
        raise RejectError("false_native_claim", "non-native route cannot be native")
    if plan.provenance != "native" and plan.reported_as_native_5_1_or_7_1:
        raise RejectError("false_native_claim",
                          f"{plan.provenance} route cannot be native 5.1/7.1")
    if plan.source_layout in ("mono", "stereo") and plan.native and plan.container_layout != plan.source_layout:
        raise RejectError("false_native_claim",
                          "mono/stereo passed into a wider container is not native")


def validate_capture_claims(plan: CapturePlan) -> None:
    if plan.kind not in CAPTURE_KINDS:
        raise RejectError("capture_kind_invalid", plan.kind)
    if plan.provenance not in CAPTURE_PROVENANCE:
        raise RejectError("capture_provenance_invalid", plan.provenance)
    if plan.kind == "refused" and plan.native_claim:
        raise RejectError("false_native_claim", "refused capture cannot be native")
    if plan.provenance == "stereo_passthrough_in_multichannel" and plan.native_claim:
        raise RejectError("false_native_claim",
                          "stereo passthrough is never native multichannel")
    forbidden = {"downmix", "upmix", "remap", "gain", "lfe_fold"}
    if forbidden.intersection(plan.transformations):
        raise RejectError("capture_transform_invalid",
                          "capture layer must not downmix/upmix/remap")


def validate_descriptor(descriptor: Mapping[str, object]) -> None:
    source = normalize_layout_name(str(descriptor["source_layout"]))
    container = normalize_layout_name(str(descriptor["container_layout"]))
    if bool(descriptor.get("report_container_as_native", False)) and source != container:
        raise RejectError("false_native_claim", "non-identity route cannot be native")
    if bool(descriptor.get("reported_as_native_5_1_or_7_1", False)) and source != container:
        raise RejectError("false_native_claim", "passthrough/downmix is not native")
    if source in ("mono", "stereo") and descriptor.get("reported_as_native_5_1_or_7_1"):
        raise RejectError("false_native_claim", "mono/stereo is never native 5.1/7.1")


def validate_acoustic_claim(layout: str, endpoint_count: int, *, measured: bool = False) -> None:
    normalized = normalize_layout_name(layout)
    required = {"mono": 1, "stereo": 2, "3.0": 3, "4.0_quad": 4,
                "5.1_side": 6, "5.1_back": 6, "7.1": 8,
                "5.1.2": 8, "7.1.2": 10, "7.1.4": 12}[normalized]
    if endpoint_count < required:
        raise RejectError("acoustic_endpoints_insufficient",
                          f"{normalized} requires {required} endpoints")
    if not measured:
        raise RejectError("acoustic_not_measured",
                          "endpoint count alone is not an acoustic result")


def acoustic_claim_for(source_layout: str, endpoint_count: int) -> str:
    plan = build_endpoint_route(source_layout, endpoint_count)
    if plan.provenance == "native":
        return plan.container_layout
    return f"{plan.container_layout}_{plan.provenance}"


@dataclass
class DeviceClock:
    uid: str
    rate: int = 48000
    latency_frames: int = 0
    revision: int = 1
    epoch: int = 0
    alive: bool = True
    buffer_frames: int = DRIVER_REPORTED_BUFFER
    zero_timestamp_period: int = ZERO_TIMESTAMP_PERIOD
    driver_reported_buffer: int = DRIVER_REPORTED_BUFFER

    def _require_alive(self) -> None:
        if not self.alive:
            raise RejectError("latency_revision_changed", "stale rediscovered device")

    def assert_revision(self, revision: int) -> None:
        self._require_alive()
        if revision != self.revision:
            raise RejectError("latency_revision_changed",
                              f"expected {revision}, current {self.revision}")

    def set_latency(self, frames: int, expected_revision: Optional[int] = None) -> int:
        self._require_alive()
        if expected_revision is not None:
            self.assert_revision(expected_revision)
        if not isinstance(frames, int) or frames < 0 or frames > 10 * self.rate:
            raise RejectError("unsupported_latency", "0..10*rate only")
        if frames == self.latency_frames:
            return self.revision
        self.latency_frames = frames
        self.revision += 1
        return self.revision

    def set_rate(self, rate: int) -> int:
        self._require_alive()
        if rate not in SUPPORTED_RATES:
            raise RejectError("unsupported_format", "44100/48000 only")
        if rate == self.rate:
            return self.revision
        seconds = self.latency_frames / float(self.rate)
        self.rate = rate
        self.latency_frames = int(round(seconds * rate))
        self.revision += 1
        self.epoch += 1
        return self.revision

    def set_buffer(self, frames: int) -> None:
        if not isinstance(frames, int) or not (MIN_BUFFER_FRAMES <= frames <= MAX_BUFFER_FRAMES):
            raise RejectError("unsupported_buffer", "15..4096 only")
        self.buffer_frames = frames

    def accept_io_frames(self, frames: int) -> None:
        # Contract §7.2: DoIO must accept host-provided 0..4096 frames.
        if not isinstance(frames, int) or not (MIN_IO_FRAMES <= frames <= MAX_IO_FRAMES):
            raise RejectError("unsupported_io_frames", "0..4096 only")

    def rediscover(self) -> "DeviceClock":
        self.alive = False
        return DeviceClock(self.uid, self.rate, self.latency_frames, 1, self.epoch + 1,
                           True, self.buffer_frames, self.zero_timestamp_period,
                           self.driver_reported_buffer)
