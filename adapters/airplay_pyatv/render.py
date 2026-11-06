"""Bounded finite PCM routing through the actual native library."""
from __future__ import annotations

import array
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import struct
import wave

from bindings.python.flow_core import CaptureOutput, Engine, RoutedBlock

MAX_SECONDS = 30
MAX_OUTPUTS = 8
MAX_SAMPLES = 16_000_000


@dataclass(frozen=True)
class RenderedOutput:
    output_id: int
    sample_rate: int
    channels: int
    frames: int
    blocks: tuple[RoutedBlock, ...]
    pcm_be: bytes


@dataclass(frozen=True)
class RenderedBatch:
    origin_ns: int
    epoch: int
    frames: int
    outputs: dict[int, RenderedOutput]

    def report(self) -> dict:
        return {
            "native_core_used": True,
            "playback_origin_ns": self.origin_ns,
            "epoch": self.epoch,
            "frames": self.frames,
            "outputs": [{"output_id": key, "channels": out.channels,
                         "frames": out.frames, "pcm_sha256": hashlib.sha256(out.pcm_be).hexdigest(),
                         "first_presentation_ns": out.blocks[0].presentation_ns,
                         "last_block_frame": out.blocks[-1].first_frame,
                         "blocks": len(out.blocks)} for key, out in self.outputs.items()],
            "acoustic_sync_verified": False,
        }


def pcm16be(samples) -> bytes:
    """Saturating float32→signed16 big-endian, matching pyatv's actual packet data."""
    return b"".join(struct.pack(">h", max(-32768, min(32767, round(float(value) * 32767)))) for value in samples)


def render_audio(library: str | Path, samples, sample_rate: int, channels: int,
                 routes: dict[int, list[int]], now_ns: int, lead_ns: int,
                 epoch: int = 1, block_frames: int = 352) -> RenderedBatch:
    if not 1 <= sample_rate <= 192000 or not 1 <= channels <= 16 or block_frames <= 0:
        raise ValueError("invalid bounded input format or block size")
    owned = samples if isinstance(samples, array.array) and samples.typecode == "f" else array.array("f", samples)
    if not owned or len(owned) % channels or len(owned) > MAX_SAMPLES:
        raise ValueError("nonempty whole-frame bounded samples required")
    frames = len(owned) // channels
    if frames > MAX_SECONDS * sample_rate or not 1 <= len(routes) <= MAX_OUTPUTS:
        raise ValueError("M1 accepts 1..8 outputs and clips at most 30 seconds")
    total = frames * sum(len(mapping) for mapping in routes.values())
    if total > MAX_SAMPLES:
        raise ValueError("routed batch exceeds finite sample budget")
    captured = {key: CaptureOutput(max(1, frames * len(mapping))) for key, mapping in routes.items()}
    with Engine(library, sample_rate, channels) as engine:
        for key, mapping in routes.items():
            engine.add_output(key, mapping, captured[key])
        engine.prepare()
        origin = engine.start(epoch, now_ns, lead_ns)
        stride = block_frames * channels
        for offset in range(0, len(owned), stride):
            engine.submit(epoch, offset // channels, owned[offset:offset + stride])
        outputs = {}
        for key, capture in captured.items():
            # Preserve owned callback copies before engine.close discards queue data.
            blocks = tuple(capture.blocks)
            data = b"".join(pcm16be(block.samples) for block in blocks)
            outputs[key] = RenderedOutput(key, sample_rate, len(routes[key]), frames, blocks, data)
        return RenderedBatch(origin, epoch, frames, outputs)


def generated_tones(seconds: float = 3.0, channels: int = 3, sample_rate: int = 44100):
    if not math.isfinite(seconds) or not 0 < seconds <= MAX_SECONDS or not 1 <= channels <= 16:
        raise ValueError("finite 0..30 seconds and 1..16 channels required")
    result = array.array("f")
    for frame in range(int(seconds * sample_rate)):
        t = frame / sample_rate
        fade = max(0.0, min(1.0, t / .02, (seconds - t) / .02))
        for channel in range(channels):
            result.append(.12 * fade * math.sin(2 * math.pi * (440 + 220 * channel) * t))
    return result, sample_rate, channels


def load_wav(path: str | Path):
    with wave.open(str(path), "rb") as source:
        rate, channels, frames = source.getframerate(), source.getnchannels(), source.getnframes()
        if (source.getsampwidth() != 2 or source.getcomptype() != "NONE"
                or not 1 <= channels <= 16 or frames <= 0 or frames > rate * MAX_SECONDS
                or frames * channels > MAX_SAMPLES):
            raise ValueError("M1 requires bounded uncompressed signed16 PCM WAV, at most 30s")
        data = source.readframes(frames)
    if len(data) != frames * channels * 2:
        raise ValueError("truncated WAV")
    values = array.array("f", (value[0] / 32768 for value in struct.iter_unpack("<h", data)))
    return values, rate, channels
