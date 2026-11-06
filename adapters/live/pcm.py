"""Strict HPCM v1 decoder. Binary media never shares the App JSONL channel."""
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
MAX_HEADER = 16384
MAX_PAYLOAD = 65536


def integer(value, low=0, high=(1 << 64) - 1):
    if type(value) is not int or not low <= value <= high:
        raise LiveFailure("invalid HPCM integer")
    return value


def finite_json(data):
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
        return json.loads(data.decode("utf-8", "strict"), object_pairs_hook=pairs,
                          parse_constant=constant, parse_float=floating)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise LiveFailure("invalid HPCM JSON header") from exc


@dataclass(frozen=True)
class Frame:
    header: dict
    payload: bytes


async def read_frame(reader):
    # readexactly handles short reads; EOF at any point is a live failure.
    try:
        magic, hlength, plength = PREFIX.unpack(await reader.readexactly(PREFIX.size))
        if magic != b"HPCM" or not 1 <= hlength <= MAX_HEADER or plength > MAX_PAYLOAD:
            raise LiveFailure("invalid HPCM framing or frame size")
        header = finite_json(await reader.readexactly(hlength))
        if (not isinstance(header, dict) or type(header.get("v")) is not int or header["v"] != 1
                or header.get("kind") not in ("ready", "pcm", "stopped", "error")):
            raise LiveFailure("invalid HPCM version or kind")
        if header["kind"] != "pcm" and plength:
            raise LiveFailure("control frame cannot contain PCM")
        return Frame(header, await reader.readexactly(plength))
    except (EOFError, struct.error) as exc:
        raise LiveFailure("unexpected capture host EOF") from exc


class PCMValidator:
    """Session/continuity validation, retaining raw clock metadata unchanged."""
    def __init__(self, session, start_id):
        if str(uuid.UUID(session)).lower() != session.lower():
            raise ValueError("hyphenated session UUID required")
        self.session, self.start_id = session, start_id
        self.sequence = self.frames = 0
        self.source_sequence = None
        self.source_snapshot = None
        self.first_host = self.first_source_frame = self.source_rate = self.timebase = None
        self.first_media_frame = None
        self.clipped_samples = 0
        self.first_source = self.last_source = None

    def correlated(self, header, command_id=None):
        if header.get("session") != self.session or header.get("id") != (self.start_id if command_id is None else command_id):
            raise LiveFailure("stale or uncorrelated capture frame")

    def pcm(self, frame):
        h = frame.header
        self.correlated(h)
        count = integer(h.get("outputFrames"), 1, 4096)
        if (h.get("kind") != "pcm" or type(h.get("outputRate")) is not int or h["outputRate"] != 44100
                or type(h.get("outputChannels")) is not int or h["outputChannels"] != 2
                or integer(h.get("sequence")) != self.sequence
                or integer(h.get("outputFrameStart")) != self.frames
                or len(frame.payload) != count * 8):
            raise LiveFailure("capture output format, sequence or payload mismatch")
        source = h.get("source")
        if not isinstance(source, dict):
            raise LiveFailure("native source clock metadata missing")
        rate = source.get("sourceRate")
        if type(rate) not in (int, float) or not math.isfinite(rate) or not 8000 <= rate <= 192000:
            raise LiveFailure("invalid actual capture sample rate")
        if type(source.get("sourceChannels")) is not int or source["sourceChannels"] != 2:
            raise LiveFailure("capture is not the supported stereo format")
        seq = integer(source.get("sourceSequence"))
        first = integer(source.get("sourceFrameStart"))
        source_frames = integer(source.get("sourceFrames"), 1, 16384)
        host = integer(source.get("hostTime"))
        flags = integer(source.get("flags"), 0, (1 << 32) - 1)
        integer(source.get("nowHostTime"))
        now_flags = integer(source.get("nowFlags"), 0, (1 << 32) - 1)
        numerator = integer(source.get("timebaseNumerator"), 1, (1 << 32) - 1)
        denominator = integer(source.get("timebaseDenominator"), 1, (1 << 32) - 1)
        if integer(source.get("droppedBlocksBefore")) != 0 or flags & 3 != 3 or now_flags & 2 != 2:
            raise LiveFailure("capture gap or invalid native clock")
        for key, valid in (("sampleTime", True), ("nowSampleTime", bool(now_flags & 1))):
            raw = source.get(key)
            if not isinstance(raw, str) or len(raw) > 128:
                raise LiveFailure("native sample time must be a bounded Double string")
            try:
                value = float(raw)
            except ValueError as exc:
                raise LiveFailure("invalid native sample time") from exc
            if valid and not math.isfinite(value):
                raise LiveFailure("invalid native sample time flag")
        for key in ("inputFramesConsumedTotal", "converterLeadingFrames", "converterTrailingFrames"):
            integer(h.get(key))
        if (h.get("primeMethod") != "none" or h.get("converterDelayKnown") is not False
                or h.get("timestampRelation") != "input_block_metadata"):
            raise LiveFailure("unsupported converter clock relation")
        if self.first_host is None:
            self.first_host, self.first_source_frame = host, first
            self.source_rate, self.timebase = rate, (numerator, denominator)
            self.first_media_frame = self.frames
            self.first_source = dict(source)
        if self.source_rate != rate or self.timebase != (numerator, denominator):
            raise LiveFailure("capture format or timebase changed")
        if self.source_sequence is not None:
            if seq < self.source_sequence or (seq == self.source_sequence and source != self.source_snapshot):
                raise LiveFailure("native source metadata regressed or changed")
            if seq > self.source_sequence and (host < self.source_snapshot["hostTime"]
                                               or first < self.source_snapshot["sourceFrameStart"] + self.source_snapshot["sourceFrames"]):
                raise LiveFailure("native capture clock or input index regressed")
        # Relative ticks are safe across processes; absolute epochs are never equated.
        elapsed = (host - self.first_host) * numerator / denominator / 1e9
        media_elapsed = (self.frames - self.first_media_frame) / 44100
        if abs(elapsed - media_elapsed) > .250:
            raise LiveFailure("capture/media clock divergence exceeded 250ms budget")
        samples = array.array("f")
        samples.frombytes(frame.payload)
        if sys.byteorder != "little":
            samples.byteswap()
        if any(not math.isfinite(sample) or abs(sample) > 1 for sample in samples):
            raise LiveFailure("capture PCM exceeds finite normalized range")
        self.source_sequence, self.source_snapshot = seq, dict(source)
        self.last_source = dict(source)
        self.sequence += 1
        self.frames += count
        return samples
