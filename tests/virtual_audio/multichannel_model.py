"""Offline source-first routing model (provisional QA reference).

This model is intentionally self-contained: no audio I/O, playback, capture,
network, or device access. It is the reference used by the offline fixtures and
tests in this directory.

IMPORTANT: the architect's frozen MULTICHANNEL_CONTRACT.md v1 differs from this
provisional model in several places. The differences are listed in
docs/collaboration/virtual-audio/MULTICHANNEL_ACCEPTANCE.md and must be
resolved before this model is used as contract acceptance evidence.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Dict, List, Mapping, Optional, Sequence, Tuple


SQRT_HALF = math.sqrt(0.5)
FIXTURE_AMPLITUDE = 0.25
FIXTURE_DURATION_SECONDS = 1.0

FIXTURE_TONES: Dict[str, int] = {
    "FC": 557,
    "FL": 317,
    "FR": 431,
    "LFE": 61,
    "SL": 733,
    "SR": 863,
    "BL": 977,
    "BR": 1103,
    "TFL": 1301,
    "TFR": 1451,
    "TBL": 1601,
    "TBR": 1751,
}

ALLOWED_LABELS = (
    "FC", "FL", "FR", "LFE", "SL", "SR", "BL", "BR",
    "TFL", "TFR", "TBL", "TBR",
)
SURROUND_LAYOUTS = ("5.1_side", "5.1_back", "7.1", "7.1.2", "7.1.4")

# Provisional order used by this offline model. See contract conflict section:
# the frozen contract uses 7.1 = FL FR FC LFE SL SR BL BR and mono label M.
LAYOUTS: Dict[str, Tuple[str, ...]] = {
    "mono": ("FC",),
    "stereo": ("FL", "FR"),
    "3.0": ("FL", "FR", "FC"),
    "4.0_quad": ("FL", "FR", "BL", "BR"),
    "5.1_side": ("FL", "FR", "FC", "LFE", "SL", "SR"),
    "5.1_back": ("FL", "FR", "FC", "LFE", "BL", "BR"),
    "7.1": ("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"),
    "7.1.2": ("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR"),
    "7.1.4": ("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR",
              "TFL", "TFR", "TBL", "TBR"),
}

LAYOUT_MASKS: Dict[str, int] = {
    "mono": 0x00000004,
    "stereo": 0x00000003,
    "3.0": 0x00000007,
    "4.0_quad": 0x00000033,
    "5.1_side": 0x0000060F,
    "5.1_back": 0x0000003F,
    "7.1": 0x0000063F,
    "7.1.2": 0x0000363F,
    "7.1.4": 0x0000F63F,
}

MIN_BUFFER_FRAMES = 15
MAX_BUFFER_FRAMES = 4096
ZERO_TIMESTAMP_PERIOD = 16384
DRIVER_REPORTED_BUFFER = 512
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
        "4.0": "4.0_quad", "4.0_quad": "4.0_quad", "quad": "4.0_quad",
        "5.1_side": "5.1_side", "5.1-side": "5.1_side", "5.1(side)": "5.1_side",
        "5.1_back": "5.1_back", "5.1-back": "5.1_back", "5.1(back)": "5.1_back",
        "7.1": "7.1", "7.1.2": "7.1.2", "7_1_2": "7.1.2",
        "7.1.4": "7.1.4", "7_1_4": "7.1.4",
    }
    key = name.strip().lower()
    if key in ("5.1", "5.1ch", "6ch"):
        raise RejectError("ambiguous_layout", "6ch must state 5.1 side or 5.1 back")
    if key in ("8ch",):
        raise RejectError("ambiguous_layout", "8ch may be 7.1 or 5.1.2")
    if key in ("10ch",):
        raise RejectError("ambiguous_layout", "10ch may be 7.1.2 or 5.1.4")
    if key == "5.1.4":
        raise RejectError("unsupported_layout", "5.1.4 is not accepted; 10ch is 7.1.2")
    if key not in aliases:
        raise RejectError("unsupported_layout", f"unknown layout {name!r}")
    return aliases[key]


def labels_for(name: str) -> Tuple[str, ...]:
    return LAYOUTS[normalize_layout_name(name)]


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


Matrix = Dict[str, Dict[str, float]]


def empty_matrix(labels: Sequence[str]) -> Matrix:
    return {label: {} for label in labels}


def set_coefficient(matrix: Matrix, output: str, source: str, value: float) -> None:
    if value:
        matrix.setdefault(output, {})[source] = float(value)


def identity_matrix(layout: str) -> Matrix:
    return {label: {label: 1.0} for label in labels_for(layout)}


def passthrough_matrix(source_layout: str, target_layout: str) -> Matrix:
    source = labels_for(source_layout)
    target = labels_for(target_layout)
    matrix = empty_matrix(target)
    for label in source:
        if label not in target:
            raise RejectError("layout_mismatch",
                              f"source label {label} has no slot in {target_layout}")
        set_coefficient(matrix, label, label, 1.0)
    return matrix


def mono_to_stereo_matrix() -> Matrix:
    matrix = empty_matrix(("FL", "FR"))
    set_coefficient(matrix, "FL", "FC", SQRT_HALF)
    set_coefficient(matrix, "FR", "FC", SQRT_HALF)
    return matrix


def upmix_matrix(container_layout: str) -> Matrix:
    target = normalize_layout_name(container_layout)
    if target not in ("5.1_side", "5.1_back", "7.1"):
        raise RejectError("mode_mismatch", "stereo upmix fallback is 5.1/7.1 only")
    matrix = empty_matrix(labels_for(target))
    set_coefficient(matrix, "FL", "FL", 1.0)
    set_coefficient(matrix, "FR", "FR", 1.0)
    set_coefficient(matrix, "FC", "FL", 0.5)
    set_coefficient(matrix, "FC", "FR", 0.5)
    set_coefficient(matrix, "LFE", "FL", 0.5)
    set_coefficient(matrix, "LFE", "FR", 0.5)
    if target == "5.1_side":
        left, right = "SL", "SR"
    elif target == "5.1_back":
        left, right = "BL", "BR"
    else:
        left, right = "SL", "SR"
    set_coefficient(matrix, left, "FL", 0.5)
    set_coefficient(matrix, left, "FR", -0.5)
    set_coefficient(matrix, right, "FL", -0.5)
    set_coefficient(matrix, right, "FR", 0.5)
    return matrix


def _cap_rows(matrix: Matrix) -> Tuple[Matrix, Dict[str, float]]:
    scaled: Matrix = {}
    gains: Dict[str, float] = {}
    for output, row in matrix.items():
        l1 = sum(abs(value) for value in row.values())
        gain = 1.0 if l1 <= 1.0 else 1.0 / l1
        gains[output] = gain
        scaled[output] = {source: value * gain for source, value in row.items() if value}
    return scaled, gains


def _fold_destinations(label: str, target: Sequence[str]) -> List[Tuple[str, float]]:
    target_set = set(target)
    if label == "FC":
        if "FL" in target_set and "FR" in target_set:
            return [("FL", SQRT_HALF), ("FR", SQRT_HALF)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label in ("FL", "FR"):
        return [("FC", 1.0)] if "FC" in target_set else []
    if label == "TFL":
        if "TFL" in target_set:
            return [("TFL", 1.0)]
        if "FL" in target_set:
            return [("FL", 1.0)]
        if "SL" in target_set:
            return [("SL", 1.0)]
        if "BL" in target_set:
            return [("BL", 1.0)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label == "TFR":
        if "TFR" in target_set:
            return [("TFR", 1.0)]
        if "FR" in target_set:
            return [("FR", 1.0)]
        if "SR" in target_set:
            return [("SR", 1.0)]
        if "BR" in target_set:
            return [("BR", 1.0)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label == "TBL":
        if "TBL" in target_set:
            return [("TBL", 1.0)]
        if "BL" in target_set:
            return [("BL", 1.0)]
        if "SL" in target_set:
            return [("SL", 1.0)]
        if "FL" in target_set:
            return [("FL", SQRT_HALF)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label == "TBR":
        if "TBR" in target_set:
            return [("TBR", 1.0)]
        if "BR" in target_set:
            return [("BR", 1.0)]
        if "SR" in target_set:
            return [("SR", 1.0)]
        if "FR" in target_set:
            return [("FR", SQRT_HALF)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label in ("SL", "BL"):
        if label in target_set:
            return [(label, 1.0)]
        if "SL" in target_set:
            return [("SL", 1.0)]
        if "BL" in target_set:
            return [("BL", 1.0)]
        if "FL" in target_set:
            return [("FL", SQRT_HALF)]
        return [("FC", 1.0)] if "FC" in target_set else []
    if label in ("SR", "BR"):
        if label in target_set:
            return [(label, 1.0)]
        if "SR" in target_set:
            return [("SR", 1.0)]
        if "BR" in target_set:
            return [("BR", 1.0)]
        if "FR" in target_set:
            return [("FR", SQRT_HALF)]
        return [("FC", 1.0)] if "FC" in target_set else []
    return []


def downmix_matrix(source_layout: str, target_layout: str, *,
                   lfe_policy: str = "omit", lfe_coefficient: float = 0.5
                   ) -> Tuple[Matrix, Dict[str, object]]:
    source = labels_for(source_layout)
    target = labels_for(target_layout)
    if lfe_policy not in ("omit", "fold"):
        raise RejectError("unsupported_policy", f"unknown LFE policy {lfe_policy!r}")
    if not (0.0 <= lfe_coefficient <= 1.0):
        raise RejectError("unsupported_policy", "LFE coefficient must be in [0,1]")
    matrix = empty_matrix(target)
    for label in source:
        if label == "LFE":
            if "LFE" in target:
                set_coefficient(matrix, "LFE", label, 1.0)
            elif lfe_policy == "fold":
                if "FL" in target and "FR" in target:
                    set_coefficient(matrix, "FL", label, lfe_coefficient)
                    set_coefficient(matrix, "FR", label, lfe_coefficient)
                elif "FC" in target:
                    set_coefficient(matrix, "FC", label, lfe_coefficient)
            continue
        if label in target:
            set_coefficient(matrix, label, label, 1.0)
            continue
        for destination, coefficient in _fold_destinations(label, target):
            set_coefficient(matrix, destination, label, coefficient)
    capped, gains = _cap_rows(matrix)
    if "LFE" in target:
        lfe_action = "passthrough_to_target"
    elif lfe_policy == "fold":
        lfe_action = "folded"
    else:
        lfe_action = "omitted"
    meta = {
        "source_layout": normalize_layout_name(source_layout),
        "target_layout": normalize_layout_name(target_layout),
        "lfe_policy": lfe_policy,
        "lfe_coefficient": 0.0 if lfe_policy == "omit" else lfe_coefficient,
        "lfe_action": lfe_action,
        "row_gains": gains,
        "raw_max_row_l1": max((sum(abs(v) for v in row.values())
                               for row in matrix.values()), default=0.0),
        "max_row_l1": max_row_l1(capped),
    }
    return capped, meta


def row_l1(row: Mapping[str, float]) -> float:
    return sum(abs(value) for value in row.values())


def max_row_l1(matrix: Matrix) -> float:
    return max((row_l1(row) for row in matrix.values()), default=0.0)


def headroom_db(matrix: Matrix) -> float:
    bound = max_row_l1(matrix)
    return float("inf") if bound == 0 else -20.0 * math.log10(bound)


@dataclass
class RoutePlan:
    source_layout: str
    container_layout: str
    mode: str
    matrix: Matrix
    provenance: str
    transformations: List[str] = field(default_factory=list)
    metadata: Dict[str, object] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)

    @property
    def labels(self) -> Tuple[str, ...]:
        return tuple(self.matrix.keys())

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
        return self.container_layout if self.container_is_native_for_source else None

    @property
    def report_container_as_native(self) -> bool:
        return self.container_is_native_for_source and self.source_channel_count > 2

    @property
    def reported_as_native_5_1_or_7_1(self) -> bool:
        return (self.container_is_native_for_source
                and self.source_layout in ("5.1_side", "5.1_back", "7.1", "7.1.2", "7.1.4"))

    def as_dict(self) -> Dict[str, object]:
        return {
            "source_layout": self.source_layout,
            "container_layout": self.container_layout,
            "source_channels": self.source_channel_count,
            "container_channels": self.container_channel_count,
            "labels": list(self.labels),
            "mode": self.mode,
            "provenance": self.provenance,
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


def _identity_plan(source: str) -> RoutePlan:
    provenance = "stereo_identity" if source == "stereo" else "discrete_pcm"
    if source == "mono":
        provenance = "mono_identity"
    return RoutePlan(source, source, "identity", identity_matrix(source),
                     provenance, metadata={"max_row_l1": 1.0})


def build_route(source_layout: str, container_layout: str, mode: str = "auto",
                *, lfe_policy: str = "omit", lfe_coefficient: float = 0.5) -> RoutePlan:
    source = normalize_layout_name(source_layout)
    container = normalize_layout_name(container_layout)
    if mode not in ("auto", "identity", "passthrough", "upmix", "downmix"):
        raise RejectError("unsupported_mode", f"unknown route mode {mode!r}")
    if mode == "identity":
        if source != container:
            raise RejectError("mode_mismatch", "identity requires equal layouts")
        return _identity_plan(source)
    if mode == "upmix":
        if source == "stereo":
            matrix = upmix_matrix(container)
            return RoutePlan(source, container, "upmix", matrix, "stereo_upmix_v1",
                             ["stereo_upmix_v1"],
                             {"max_row_l1": max_row_l1(matrix)})
        if source == "mono" and container == "stereo":
            matrix = mono_to_stereo_matrix()
            return RoutePlan(source, container, "upmix", matrix, "mono_to_stereo_v1",
                             ["mono_to_stereo_v1"], {"max_row_l1": max_row_l1(matrix)})
        raise RejectError("mode_mismatch", "upmix fallback is stereo->5.1/7.1 or mono->stereo")
    source_labels = labels_for(source)
    target_labels = labels_for(container)
    subset = set(source_labels).issubset(set(target_labels))
    if source == container:
        return _identity_plan(source)
    if source == "mono" and container == "stereo":
        matrix = mono_to_stereo_matrix()
        return RoutePlan(source, container, "upmix", matrix, "mono_to_stereo_v1",
                         ["mono_to_stereo_v1"], {"max_row_l1": max_row_l1(matrix)})
    if subset:
        if mode not in ("auto", "passthrough"):
            raise RejectError("mode_mismatch", "wider container supports passthrough only")
        matrix = passthrough_matrix(source, container)
        extras = [label for label in target_labels if label not in source_labels]
        return RoutePlan(
            source, container, "passthrough", matrix,
            ("stereo_passthrough_in_multichannel" if source == "stereo" and container != "stereo"
             else "discrete_pcm_passthrough"),
            (["stereo_passthrough"] if source == "stereo" and container != "stereo"
             else ["source_slots_passthrough"]),
            {"max_row_l1": max_row_l1(matrix), "silent_container_slots": extras},
        )
    if len(target_labels) < len(source_labels):
        if mode not in ("auto", "downmix"):
            raise RejectError("mode_mismatch", "narrower target requires downmix")
        matrix, meta = downmix_matrix(source, container, lfe_policy=lfe_policy,
                                      lfe_coefficient=lfe_coefficient)
        transformations = ["downmix_to_target_v1"]
        if source in ("7.1", "7.1.2", "7.1.4") and container in ("5.1_side", "5.1_back"):
            transformations.append("surround_fold_v1")
        if source in ("7.1.2", "7.1.4"):
            transformations.append("height_fold_v1")
        if "LFE" not in target_labels:
            transformations.append("lfe_omitted" if lfe_policy == "omit" else "lfe_folded")
        return RoutePlan(source, container, "downmix", matrix,
                         "discrete_pcm_downmixed", transformations, meta)
    if len(target_labels) == len(source_labels):
        raise RejectError("layout_mismatch",
                          f"{source} and {container} have different slot identity")
    raise RejectError("layout_mismatch",
                      f"wider target {container} does not contain all {source} labels")


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


def build_endpoint_route(source_layout: str, speaker_count: int, *,
                         lfe_policy: str = "omit", lfe_coefficient: float = 0.5) -> RoutePlan:
    target = endpoint_layout_for(source_layout, speaker_count)
    plan = build_route(source_layout, target, "auto", lfe_policy=lfe_policy,
                       lfe_coefficient=lfe_coefficient)
    plan.metadata["endpoint_count"] = speaker_count
    plan.metadata["endpoint_layout"] = target
    return plan


def endpoint_matrix(sources: Sequence[str] = ("mono", "stereo", "4.0_quad",
                                              "5.1_side", "5.1_back", "7.1"),
                    counts: Sequence[int] = REQUIRED_ENDPOINT_COUNTS
                    ) -> Dict[str, Dict[int, Dict[str, object]]]:
    result: Dict[str, Dict[int, Dict[str, object]]] = {}
    for source in sources:
        row: Dict[int, Dict[str, object]] = {}
        for count in counts:
            plan = build_endpoint_route(source, count)
            row[count] = {"target_layout": plan.container_layout, "mode": plan.mode,
                          "labels": list(plan.labels), "matrix": plan.matrix,
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
    if plan.report_container_as_native and plan.source_layout != plan.container_layout:
        raise RejectError("false_native_claim", "non-identity route cannot be native")
    if plan.reported_as_native_5_1_or_7_1 and plan.mode != "identity":
        raise RejectError("false_native_claim", "non-identity route cannot be native")
    if (plan.source_layout in ("mono", "stereo")
            and plan.container_channel_count > plan.source_channel_count):
        if plan.provenance not in ("stereo_passthrough_in_multichannel",
                                   "stereo_upmix_v1", "mono_to_stereo_v1",
                                   "discrete_pcm_passthrough"):
            raise RejectError("false_native_claim",
                              "narrow source in wider container must declare passthrough/upmix")


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
                "5.1_side": 6, "5.1_back": 6, "7.1": 8, "7.1.2": 10, "7.1.4": 12}[normalized]
    if endpoint_count < required:
        raise RejectError("acoustic_endpoints_insufficient",
                          f"{normalized} requires {required} endpoints")
    if not measured:
        raise RejectError("acoustic_not_measured",
                          "endpoint count alone is not an acoustic result")


def acoustic_claim_for(source_layout: str, endpoint_count: int) -> str:
    plan = build_endpoint_route(source_layout, endpoint_count)
    if plan.mode in ("identity", "passthrough"):
        return plan.source_layout
    if plan.mode == "upmix":
        return f"{plan.container_layout}_upmix"
    return f"{plan.container_layout}_downmix"


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
        if not isinstance(frames, int) or not (MIN_BUFFER_FRAMES <= frames <= MAX_BUFFER_FRAMES):
            raise RejectError("unsupported_io_frames", "15..4096 only")

    def rediscover(self) -> "DeviceClock":
        self.alive = False
        return DeviceClock(self.uid, self.rate, self.latency_frames, 1, self.epoch + 1,
                           True, self.buffer_frames, self.zero_timestamp_period,
                           self.driver_reported_buffer)

