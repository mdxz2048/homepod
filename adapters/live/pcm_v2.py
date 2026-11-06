"""Strict standalone HPCM v2 decoder for multichannel live capture.

HPCM v1 (``adapters.live.pcm``) is untouched. This module only accepts
``v=2`` frames, validates the v2 layout/transform/provenance contract and
returns interleaved Float32 samples. It performs no capture, playback,
device access or routing.
"""
from __future__ import annotations

import array
from dataclasses import dataclass
import json
import math
import struct
import sys
import uuid

from .hub import LiveFailure

PREFIX = struct.Struct("<4sII")
MAX_HEADER_V2 = 16384
MAX_PAYLOAD_V2 = 196608  # 12 channels * 4096 frames * 4 bytes
MAX_FRAMES = 4096
OUTPUT_RATE = 44100
R1_CHANNELS = frozenset((1, 2, 3, 4, 6, 8))

# Canonical order *is* the HPCM payload interleave order (contract §3.1).
LAYOUTS = {
    "mono": ("M",),
    "stereo": ("FL", "FR"),
    "3_0": ("FL", "FR", "FC"),
    "4_0": ("FL", "FR", "BL", "BR"),
    "5_1_side": ("FL", "FR", "FC", "LFE", "SL", "SR"),
    "5_1_back": ("FL", "FR", "FC", "LFE", "BL", "BR"),
    "7_1": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"),
    "5_1_2": ("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR"),
    "7_1_2": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR"),
    "7_1_4": ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR",
              "TFL", "TFR", "TRL", "TRR"),
}
RES_LAYOUTS = frozenset(("5_1_2", "7_1_2", "7_1_4"))
SOURCE_ONLY_LAYOUTS = frozenset(("5_1_ambiguous", "unknown"))

CANONICAL_DEVICE_UID = {
    "mono": "com.homepodflow.virtual-audio.mono.v1",
    "stereo": "com.homepodflow.virtual-audio.stereo.v1",
    "3_0": "com.homepodflow.virtual-audio.surround30.v1",
    "4_0": "com.homepodflow.virtual-audio.quad40.v1",
    "5_1_side": "com.homepodflow.virtual-audio.surround51s.v1",
    "5_1_back": "com.homepodflow.virtual-audio.surround51b.v1",
    "7_1": "com.homepodflow.virtual-audio.surround71.v1",
}

SOURCE_AUTHORITIES = frozenset(("decoder", "player_output", "device",
                                "user_override", "none"))
SOURCE_ORIGINS = frozenset(("decoder", "player_output", "os_mix",
                            "user_override", "unknown"))
UPSTREAM_TRANSFORMS = frozenset((
    "none_known", "player_map_possible", "player_downmix_possible",
    "player_upmix_possible", "os_mix_possible", "unknown",
))
PROVENANCE = frozenset((
    "source_native", "source_padded", "stereo_passthrough_in_multichannel",
    "source_upstream_mapped", "unknown_restricted",
))
TRANSFORMATIONS = frozenset((
    "identity", "pad_silent", "pad_5_1_side_to_7_1",
    "pad_5_1_back_to_7_1", "stereo_passthrough", "upstream_player_map",
    "front_pair_only",
))
CONTROL_KINDS = frozenset(("ready", "stopped", "error"))


class PCMV2Error(LiveFailure):
    """HPCM v2 failure carrying a contract error code."""

    def __init__(self, code, message):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def _integer(value, low=0, high=(1 << 64) - 1, field="integer"):
    if type(value) is not int or not low <= value <= high:
        raise PCMV2Error("invalid_header", f"invalid {field}")
    return value


def _string(value, field, limit=512, allow_empty=False):
    if (not isinstance(value, str) or len(value) > limit
            or (not allow_empty and not value)):
        raise PCMV2Error("invalid_header", f"invalid {field}")
    return value


def _boolean(value, field):
    if type(value) is not bool:
        raise PCMV2Error("invalid_header", f"invalid {field}")
    return value


def _strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate header key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("nonfinite header")

    def floating(text):
        value = float(text)
        if not math.isfinite(value):
            raise ValueError("nonfinite header")
        return value

    try:
        return json.loads(data.decode("utf-8", "strict"),
                          object_pairs_hook=pairs,
                          parse_constant=constant, parse_float=floating)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise PCMV2Error("invalid_header", "invalid HPCM v2 JSON header") from exc


@dataclass(frozen=True)
class FrameV2:
    header: dict
    payload: bytes


async def read_frame_v2(reader):
    """Read exactly one HPCM v2 frame; never resynchronise on bad input."""
    try:
        magic, header_length, payload_length = PREFIX.unpack(
            await reader.readexactly(PREFIX.size))
    except (EOFError, struct.error) as exc:
        raise PCMV2Error("truncated_frame", "unexpected EOF in HPCM v2 prefix") from exc
    if magic != b"HPCM":
        raise PCMV2Error("invalid_framing", "bad HPCM magic")
    if not 1 <= header_length <= MAX_HEADER_V2:
        raise PCMV2Error("payload_too_large", "HPCM v2 header length out of range")
    if payload_length > MAX_PAYLOAD_V2:
        raise PCMV2Error("payload_too_large", "HPCM v2 payload length out of range")
    try:
        header = _strict_json(await reader.readexactly(header_length))
    except EOFError as exc:
        raise PCMV2Error("truncated_frame", "truncated HPCM v2 header") from exc
    if not isinstance(header, dict):
        raise PCMV2Error("invalid_header", "HPCM v2 header must be an object")
    version = header.get("v")
    if type(version) is not int:
        raise PCMV2Error("invalid_header", "HPCM v2 version must be an integer")
    if version != 2:
        raise PCMV2Error("unsupported_version",
                         f"HPCM v{version} is not accepted by the v2 decoder")
    kind = header.get("kind")
    if kind not in ("ready", "pcm", "stopped", "error"):
        raise PCMV2Error("invalid_header", "invalid HPCM v2 kind")
    if kind != "pcm" and payload_length:
        raise PCMV2Error("payload_mismatch", "control frame cannot contain PCM")
    try:
        payload = await reader.readexactly(payload_length)
    except EOFError as exc:
        raise PCMV2Error("truncated_frame", "truncated HPCM v2 payload") from exc
    return FrameV2(header, payload)


def _ordered_labels(value, field):
    if not isinstance(value, list) or not value:
        raise PCMV2Error("invalid_header", f"invalid {field}")
    result = []
    for label in value:
        if not isinstance(label, str) or not label or len(label) > 32:
            raise PCMV2Error("channel_map_mismatch", f"bad label in {field}")
        result.append(label)
    if len(set(result)) != len(result):
        raise PCMV2Error("channel_map_mismatch", f"duplicate label in {field}")
    return tuple(result)


class PCMV2Validator:
    """Session/continuity/layout validation; raw clock fields stay intact."""

    def __init__(self, session, start_id):
        if str(uuid.UUID(session)).lower() != session.lower():
            raise ValueError("hyphenated session UUID required")
        self.session, self.start_id = session, start_id
        self.sequence = self.frames = 0
        self.total_input = None
        self.output_channels = self.output_layout = None
        self.output_channel_order = None
        self.source_sequence = self.source_snapshot = None
        self.last_input_total = None
        self.first_host = self.first_source_frame = self.source_rate = None
        self.timebase = None
        self._layout_state = None
        self.first_source = self.last_source = None

    def correlated(self, header, command_id=None):
        expected = self.start_id if command_id is None else command_id
        if header.get("session") != self.session or header.get("id") != expected:
            raise PCMV2Error("stale_session", "stale or uncorrelated HPCM v2 frame")

    def _layout(self, token, field):
        if not isinstance(token, str) or token in SOURCE_ONLY_LAYOUTS:
            if token == "5_1_ambiguous":
                raise PCMV2Error("source_layout_ambiguous",
                                 "5.1 side/back is ambiguous")
            raise PCMV2Error("unsupported_layout", f"unknown {field}")
        if token not in LAYOUTS or token in RES_LAYOUTS:
            raise PCMV2Error("unsupported_layout", f"unsupported {field}")
        return token

    def _container(self, raw, channels, layout, order):
        if not isinstance(raw, dict):
            raise PCMV2Error("invalid_header", "container descriptor missing")
        uid = _string(raw.get("deviceUID"), "container.deviceUID")
        if _integer(raw.get("channels"), 1, 12, "container.channels") != channels:
            raise PCMV2Error("container_layout_mismatch",
                             "container channels differ from outputChannels")
        if raw.get("layout") != layout:
            raise PCMV2Error("container_layout_mismatch",
                             "container layout differs from outputLayout")
        container_order = _ordered_labels(raw.get("channelOrder"),
                                          "container.channelOrder")
        if container_order != order:
            raise PCMV2Error("container_layout_mismatch",
                             "container channel order differs from output order")
        if raw.get("authority") != "device":
            raise PCMV2Error("invalid_header", "container authority must be device")
        _boolean(raw.get("verified"), "container.verified")
        canonical = CANONICAL_DEVICE_UID.get(layout)
        if uid in CANONICAL_DEVICE_UID.values() and uid != canonical:
            raise PCMV2Error("device_mismatch",
                             "known deviceUID does not match container layout")
        return (uid, channels, layout, container_order)

    def _source_clock(self, source, source_rate):
        source_frames = _integer(source.get("sourceFrames"), 1, 16384, "sourceFrames")
        source_start = _integer(source.get("sourceFrameStart"),
                                field="sourceFrameStart")
        host = _integer(source.get("hostTime"), field="hostTime")
        flags = _integer(source.get("flags"), 0, (1 << 32) - 1, "flags")
        _integer(source.get("nowHostTime"), field="nowHostTime")
        now_flags = _integer(source.get("nowFlags"), 0, (1 << 32) - 1, "nowFlags")
        numerator = _integer(source.get("timebaseNumerator"), 1,
                             (1 << 32) - 1, "timebaseNumerator")
        denominator = _integer(source.get("timebaseDenominator"), 1,
                               (1 << 32) - 1, "timebaseDenominator")
        if (_integer(source.get("droppedBlocksBefore"),
                     field="droppedBlocksBefore") != 0
                or flags & 3 != 3 or now_flags & 2 != 2):
            raise PCMV2Error("input_discontinuity",
                             "source gap or invalid native clock")
        for key, valid in (("sampleTime", True),
                           ("nowSampleTime", bool(now_flags & 1))):
            raw = source.get(key)
            if not isinstance(raw, str) or len(raw) > 128:
                raise PCMV2Error("invalid_header",
                                 "native sample time must be a bounded Double string")
            try:
                value = float(raw)
            except ValueError as exc:
                raise PCMV2Error("invalid_header", "invalid native sample time") from exc
            if valid and not math.isfinite(value):
                raise PCMV2Error("input_discontinuity",
                                 "non-finite native sample time")
        return source_frames, source_start, host, (numerator, denominator)

    def _transform(self, raw, layout, order, source_layout, source_order,
                   provenance):
        """Validate capture transform placement; returns silent channel indexes."""
        if not isinstance(raw, dict):
            raise PCMV2Error("invalid_header", "captureTransform missing")
        kind = raw.get("kind")
        if kind not in ("identity", "pad_silent", "refused"):
            raise PCMV2Error("invalid_header", "invalid captureTransform kind")
        if kind == "refused":
            raise PCMV2Error("transform_unavailable",
                             "refused transform cannot carry PCM")
        channel_count = len(order)
        placed = raw.get("placed")
        silent = raw.get("silentSlots")
        transforms = raw.get("transformations")
        if not isinstance(placed, list) or not isinstance(silent, list):
            raise PCMV2Error("invalid_header", "invalid captureTransform lists")
        if (not isinstance(transforms, list) or not transforms
                or any(not isinstance(item, str) or item not in TRANSFORMATIONS
                       for item in transforms)):
            raise PCMV2Error("invalid_header", "invalid captureTransformations")
        if len(set(transforms)) != len(transforms):
            raise PCMV2Error("invalid_header", "duplicate capture transformation")

        mapping, used = {}, set()
        for entry in placed:
            if not isinstance(entry, dict):
                raise PCMV2Error("invalid_header", "invalid placed entry")
            label = entry.get("sourceLabel")
            slot = _integer(entry.get("slot"), 0, channel_count - 1,
                            "placed.slot")
            if not isinstance(label, str) or label in mapping or slot in used:
                raise PCMV2Error("channel_map_mismatch",
                                 "duplicate or invalid placed mapping")
            if label not in source_order:
                raise PCMV2Error("channel_map_mismatch",
                                 "placed label is not in sourceChannelOrder")
            mapping[label], _ = slot, used.add(slot)

        silent_slots = set()
        for slot in silent:
            value = _integer(slot, 0, channel_count - 1, "silentSlots")
            if value in silent_slots:
                raise PCMV2Error("channel_map_mismatch", "duplicate silent slot")
            silent_slots.add(value)
        if kind == "identity" and not placed and not silent_slots:
            # Contract allows an empty placed list for identity; it means the
            # implicit same-name, same-slot mapping.
            mapping = {label: index for index, label in enumerate(order)}
            used = set(range(channel_count))
        if used & silent_slots or used | silent_slots != set(range(channel_count)):
            raise PCMV2Error("channel_map_mismatch",
                             "placed/silent slots do not partition the container")

        if kind == "identity":
            if source_order != order or len(source_order) != channel_count:
                raise PCMV2Error("channel_map_mismatch",
                                 "identity transform changes channel order")
            if placed and mapping != {label: index
                                      for index, label in enumerate(order)}:
                raise PCMV2Error("channel_map_mismatch",
                                 "identity transform must map label to same slot")
            if silent_slots:
                raise PCMV2Error("channel_map_mismatch",
                                 "identity transform cannot silence channels")
            if transforms != ["identity"]:
                raise PCMV2Error("invalid_header",
                                 "identity transform needs ['identity']")
        else:
            if len(source_order) >= channel_count:
                raise PCMV2Error(
                    "source_exceeds_container" if len(source_order) > channel_count
                    else "channel_map_mismatch",
                    "pad_silent needs a strict source subset")
            if set(mapping) != set(source_order):
                raise PCMV2Error("channel_map_mismatch",
                                 "pad_silent must place every source label")
            for label, slot in mapping.items():
                if order[slot] != label:
                    raise PCMV2Error("container_layout_mismatch",
                                     "source label has no same-name container slot")
            if silent_slots != set(range(channel_count)) - used:
                raise PCMV2Error("channel_map_mismatch",
                                 "silentSlots must be the unplaced container slots")

        if provenance == "source_native":
            if (kind != "identity" or source_layout != layout
                    or source_order != order):
                raise PCMV2Error("channel_map_mismatch",
                                 "source_native requires identical layout/order")
        elif provenance == "source_padded":
            if kind != "pad_silent" or source_layout == "stereo":
                raise PCMV2Error("channel_map_mismatch",
                                 "source_padded requires pad_silent and non-stereo source")
            if source_layout == "5_1_side" and layout == "7_1":
                expected = ["pad_5_1_side_to_7_1"]
            elif source_layout == "5_1_back" and layout == "7_1":
                expected = ["pad_5_1_back_to_7_1"]
            else:
                expected = ["pad_silent"]
            if transforms != expected:
                raise PCMV2Error("invalid_header",
                                 "transformations do not match padded layouts")
        elif provenance == "stereo_passthrough_in_multichannel":
            if (kind != "pad_silent" or source_layout != "stereo"
                    or source_order != ("FL", "FR") or channel_count <= 2
                    or mapping != {"FL": 0, "FR": 1}
                    or transforms != ["stereo_passthrough"]):
                raise PCMV2Error("channel_map_mismatch",
                                 "invalid stereo passthrough transform")
        elif provenance == "unknown_restricted":
            raise PCMV2Error("unsupported_layout",
                             "unknown_restricted is not implemented in R1")
        return silent_slots

    def pcm(self, frame):
        h = frame.header
        self.correlated(h)
        if h.get("kind") != "pcm":
            raise PCMV2Error("invalid_header", "not a PCM frame")
        rate = h.get("outputRate")
        if type(rate) is not int or rate != OUTPUT_RATE:
            raise PCMV2Error("unsupported_format",
                             "HPCM v2 R1 outputRate must be 44100")
        count = _integer(h.get("outputFrames"), 1, MAX_FRAMES, "outputFrames")
        channels = _integer(h.get("outputChannels"), 1, 12, "outputChannels")
        if channels not in R1_CHANNELS:
            raise PCMV2Error("unsupported_channels",
                             "outputChannels is not an R1 container")
        layout = self._layout(h.get("outputLayout"), "outputLayout")
        order = _ordered_labels(h.get("outputChannelOrder"),
                                "outputChannelOrder")
        if len(order) != channels:
            raise PCMV2Error("channel_map_mismatch",
                             "outputChannelOrder length differs from outputChannels")
        if order != LAYOUTS[layout]:
            raise PCMV2Error("channel_map_mismatch",
                             "outputChannelOrder differs from canonical layout order")

        container = self._container(h.get("container"), channels, layout, order)

        source = h.get("source")
        if not isinstance(source, dict):
            raise PCMV2Error("invalid_header", "source descriptor missing")
        source_rate = source.get("sourceRate")
        if (type(source_rate) not in (int, float) or isinstance(source_rate, bool)
                or not math.isfinite(source_rate)
                or not 8000 <= source_rate <= 192000):
            raise PCMV2Error("invalid_header", "invalid sourceRate")
        source_layout = self._layout(source.get("sourceLayout"), "sourceLayout")
        source_order = _ordered_labels(source.get("sourceChannelOrder"),
                                       "sourceChannelOrder")
        source_channels = _integer(source.get("sourceChannels"), 1, 12,
                                   "sourceChannels")
        if source_channels not in R1_CHANNELS:
            raise PCMV2Error("unsupported_channels",
                             "sourceChannels is not an R1 source")
        if source_channels != len(source_order):
            raise PCMV2Error("channel_map_mismatch",
                             "sourceChannels differs from sourceChannelOrder length")
        if source_order != LAYOUTS[source_layout]:
            raise PCMV2Error("channel_map_mismatch",
                             "sourceChannelOrder differs from canonical source layout")

        source_frames, source_start, host, timebase = self._source_clock(
            source, source_rate)
        seq = _integer(source.get("sourceSequence"), field="sourceSequence")
        authority = source.get("sourceLayoutAuthority")
        if authority not in SOURCE_AUTHORITIES:
            raise PCMV2Error("invalid_header", "invalid sourceLayoutAuthority")
        origin = source.get("sourceOrigin")
        if origin not in SOURCE_ORIGINS:
            raise PCMV2Error("invalid_header", "invalid sourceOrigin")
        verified = _boolean(source.get("sourceLayoutVerified"),
                            "sourceLayoutVerified")
        native = _boolean(source.get("nativeClaim"), "nativeClaim")
        upstream = source.get("upstreamTransform")
        if upstream not in UPSTREAM_TRANSFORMS:
            raise PCMV2Error("invalid_header", "invalid upstreamTransform")
        evidence = source.get("evidence")
        if evidence is not None:
            _string(evidence, "source.evidence")
        if verified and not evidence:
            raise PCMV2Error("invalid_header",
                             "verified source layout requires evidence")

        provenance = h.get("provenance")
        if provenance not in PROVENANCE:
            raise PCMV2Error("invalid_header", "invalid provenance")
        if native:
            if not verified or provenance not in ("source_native", "source_padded"):
                raise PCMV2Error("invalid_header",
                                 "nativeClaim requires verified native provenance")
            if provenance == "source_native" and authority not in ("decoder", "device"):
                raise PCMV2Error("invalid_header",
                                 "nativeClaim requires decoder/device authority")
            if (provenance == "source_native" and authority == "device"
                    and source_layout != layout):
                raise PCMV2Error("invalid_header",
                                 "device-authority nativeClaim needs matching layout")
            if provenance == "source_padded" and authority != "decoder":
                raise PCMV2Error("invalid_header",
                                 "padded nativeClaim requires decoder authority")
        if provenance in ("stereo_passthrough_in_multichannel",
                          "source_upstream_mapped", "unknown_restricted") and native:
            raise PCMV2Error("invalid_header",
                             "non-native provenance cannot claim native")
        silent_channels = self._transform(h.get("captureTransform"), layout,
                                          order, source_layout, source_order,
                                          provenance)

        total = _integer(h.get("inputFramesConsumedTotal"),
                         field="inputFramesConsumedTotal")
        leading = _integer(h.get("converterLeadingFrames"),
                           field="converterLeadingFrames")
        trailing = _integer(h.get("converterTrailingFrames"),
                            field="converterTrailingFrames")
        if (h.get("primeMethod") != "none"
                or h.get("converterDelayKnown") is not False
                or h.get("timestampRelation") != "input_block_metadata"):
            raise PCMV2Error("invalid_header",
                             "unsupported converter clock relation")
        if leading > MAX_FRAMES or trailing > MAX_FRAMES:
            raise PCMV2Error("invalid_header",
                             "converter prime frames out of range")

        if _integer(h.get("sequence"), field="sequence") != self.sequence:
            raise PCMV2Error("frame_continuity",
                             "HPCM v2 sequence is not strictly continuous")
        if _integer(h.get("outputFrameStart"),
                    field="outputFrameStart") != self.frames:
            raise PCMV2Error("frame_continuity",
                             "outputFrameStart is not continuous")
        if len(frame.payload) != count * channels * 4:
            raise PCMV2Error("payload_mismatch",
                             "payloadLength != frames*channels*4")

        state = (channels, layout, order, container, source_layout,
                 source_order, source_channels, source_rate, timebase,
                 provenance, authority, origin, upstream,
                 tuple(sorted(silent_channels)),
                 tuple(h["captureTransform"]["transformations"]))
        if self._layout_state is None:
            self._layout_state = state
        elif state != self._layout_state:
            if (channels, layout, order) != self._layout_state[:3]:
                raise PCMV2Error("source_layout_changed",
                                 "output container changed inside session")
            if (source_layout, source_order, source_channels) != self._layout_state[4:7]:
                raise PCMV2Error("source_layout_changed",
                                 "source layout changed inside session")
            if (source_rate, timebase) != self._layout_state[7:9]:
                raise PCMV2Error("input_discontinuity",
                                 "source rate or timebase changed inside session")
            if container[0] != self._layout_state[3][0]:
                raise PCMV2Error("device_mismatch",
                                 "container device changed inside session")
            if container != self._layout_state[3]:
                raise PCMV2Error("container_layout_mismatch",
                                 "container descriptor changed inside session")
            raise PCMV2Error("source_layout_changed",
                             "capture transform/provenance changed inside session")

        if self.total_input is None:
            self.total_input = total
        elif total < self.total_input:
            raise PCMV2Error("input_discontinuity",
                             "inputFramesConsumedTotal regressed")

        if self.first_host is None:
            self.first_host, self.first_source_frame = host, source_start
            self.source_rate, self.timebase = source_rate, timebase
            self.first_source = dict(source)
        if self.source_sequence is not None:
            if seq < self.source_sequence:
                raise PCMV2Error("input_discontinuity",
                                 "sourceSequence regressed")
            if seq == self.source_sequence and source != self.source_snapshot:
                raise PCMV2Error("input_discontinuity",
                                 "source metadata changed without a new sequence")
            if (seq > self.source_sequence
                    and (host < self.source_snapshot["hostTime"]
                         or source_start < (self.source_snapshot["sourceFrameStart"]
                                            + self.source_snapshot["sourceFrames"]))):
                raise PCMV2Error("input_discontinuity",
                                 "native capture clock or input index regressed")

        samples = array.array("f")
        samples.frombytes(frame.payload)
        if sys.byteorder != "little":
            samples.byteswap()
        for index, sample in enumerate(samples):
            if not math.isfinite(sample) or abs(sample) > 1:
                raise PCMV2Error("invalid_pcm_range",
                                 "capture PCM is non-finite or outside [-1,1]")
            if index % channels in silent_channels and sample != 0.0:
                raise PCMV2Error("silent_slot_nonzero",
                                 "pad_silent slot contains non-zero PCM")

        self.source_sequence, self.source_snapshot = seq, dict(source)
        self.last_source = dict(source)
        self.total_input = total
        self.sequence += 1
        self.frames += count
        self.output_channels = channels
        self.output_layout = layout
        self.output_channel_order = order
        return samples
