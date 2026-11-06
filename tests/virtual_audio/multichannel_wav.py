"""Deterministic multichannel WAV fixtures and narrow-band measurement.

No playback, capture, network, or device access. WAVE_FORMAT_EXTENSIBLE is
written with the canonical channel mask so label/slot identity can be checked
offline.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import struct
from typing import Dict, List, Mapping, Optional, Sequence, Tuple

import multichannel_model as model


PCM_GUID = bytes.fromhex("0100000000001000800000aa00389b71")
FLOAT_GUID = bytes.fromhex("0300000000001000800000aa00389b71")


class WavError(ValueError):
    pass


class ClippingError(ValueError):
    pass


@dataclass
class WavData:
    rate: int
    channels: int
    mask: int
    bits: int
    format_tag: int
    samples: List[List[float]]
    source_path: Optional[Path] = None

    @property
    def frames(self) -> int:
        return len(self.samples[0]) if self.samples else 0

    @property
    def layout(self) -> Optional[str]:
        if self.mask == 0:
            return None
        try:
            return model.layout_from_mask(self.mask, self.channels)
        except model.RejectError:
            return None


def synthesize(tones: Mapping[int, float], rate: int, frames: int) -> List[float]:
    """Sum sine tones starting at phase zero.

    Fixture durations are integer seconds and frequencies are integer Hz, so
    every tone has an integer number of cycles and the endpoints are silent.
    """
    if frames <= 0:
        raise WavError("frame count must be positive")
    for frequency in tones:
        if frequency <= 0 or frequency >= rate / 2:
            raise WavError(f"tone {frequency} Hz is outside (0, Nyquist)")
    result = [0.0] * frames
    two_pi_over_rate = 2.0 * math.pi / rate
    for frequency, amplitude in tones.items():
        if amplitude == 0:
            continue
        step = two_pi_over_rate * frequency
        for index in range(frames):
            result[index] += amplitude * math.sin(step * index)
    return result


def source_samples(
    labels: Sequence[str],
    tone_map: Mapping[str, int],
    *,
    rate: int = 48000,
    duration: float = model.FIXTURE_DURATION_SECONDS,
    amplitude: float = model.FIXTURE_AMPLITUDE,
) -> Dict[str, List[float]]:
    frames = int(rate * duration)
    if abs(frames / rate - duration) > 1e-9:
        raise WavError("duration must produce an integer frame count")
    result: Dict[str, List[float]] = {}
    for label in labels:
        result[label] = synthesize({tone_map[label]: amplitude}, rate, frames)
    return result


def _interleave(samples: Mapping[str, Sequence[float]], labels: Sequence[str]) -> List[float]:
    if not labels:
        raise WavError("no channels")
    frames = len(samples[labels[0]])
    interleaved: List[float] = []
    for index in range(frames):
        for label in labels:
            interleaved.append(samples[label][index])
    return interleaved


def write_wav(
    path: Path,
    rate: int,
    labels: Sequence[str],
    samples: Mapping[str, Sequence[float]],
    *,
    mask: Optional[int] = None,
) -> Dict[str, object]:
    """Write a 16-bit WAVE_FORMAT_EXTENSIBLE file in canonical label order."""
    labels = tuple(labels)
    if len(samples) != len(labels):
        raise WavError("sample/label count mismatch")
    if mask is None:
        layout = model.validate_labels(labels)
        mask = model.mask_for(layout)
    channels = len(labels)
    bits = 16
    block_align = channels * bits // 8
    byte_rate = rate * block_align

    peak = 0.0
    for label in labels:
        for value in samples[label]:
            if not math.isfinite(value):
                raise WavError("non-finite sample")
            peak = max(peak, abs(value))
    if peak > 1.0 + 1e-9:
        raise ClippingError(f"peak {peak:.6f} exceeds full scale")

    pcm = bytearray()
    for index in range(len(samples[labels[0]])):
        for label in labels:
            value = samples[label][index]
            quantized = int(round(value * 32767.0))
            quantized = max(-32768, min(32767, quantized))
            pcm += struct.pack("<h", quantized)

    fmt = struct.pack(
        "<HHIIHHH", 0xFFFE, channels, rate, byte_rate, block_align, bits, 22
    )
    fmt += struct.pack("<HI", bits, mask)
    fmt += PCM_GUID
    assert len(fmt) == 40

    riff_size = 4 + (8 + len(fmt)) + (8 + len(pcm))
    data = bytearray()
    data += b"RIFF"
    data += struct.pack("<I", riff_size)
    data += b"WAVE"
    data += b"fmt "
    data += struct.pack("<I", len(fmt))
    data += fmt
    data += b"data"
    data += struct.pack("<I", len(pcm))
    data += pcm

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(data))
    return {
        "path": str(path),
        "rate": rate,
        "channels": channels,
        "mask": mask,
        "frames": len(samples[labels[0]]),
        "peak": peak,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def _parse_fmt(body: bytes) -> Tuple[int, int, int, int, int, int, int]:
    if len(body) < 16:
        raise WavError("short fmt chunk")
    tag, channels, rate, byte_rate, block_align, bits = struct.unpack_from(
        "<HHIIHH", body, 0
    )
    mask = 0
    format_tag = tag
    if tag == 0xFFFE:
        if len(body) < 40:
            raise WavError("short extensible fmt chunk")
        valid_bits, mask = struct.unpack_from("<HI", body, 18)
        subformat = body[24:40]
        if subformat == PCM_GUID:
            format_tag = 1
        elif subformat == FLOAT_GUID:
            format_tag = 3
        else:
            raise WavError("unsupported WAVE subformat")
        bits = valid_bits or bits
    return format_tag, channels, rate, byte_rate, block_align, bits, mask


def _decode_pcm(body: bytes, format_tag: int, bits: int, channels: int) -> List[List[float]]:
    if channels <= 0:
        raise WavError("invalid channel count")
    if format_tag == 1 and bits == 16:
        count = len(body) // 2
        values = struct.unpack("<%dh" % count, body[: count * 2])
        flat = [value / 32768.0 for value in values]
    elif format_tag == 1 and bits == 24:
        count = len(body) // 3
        flat = []
        for index in range(count):
            chunk = body[index * 3: index * 3 + 3]
            value = int.from_bytes(chunk, "little", signed=False)
            if value & 0x800000:
                value -= 1 << 24
            flat.append(value / 8388608.0)
    elif format_tag == 1 and bits == 32:
        count = len(body) // 4
        values = struct.unpack("<%di" % count, body[: count * 4])
        flat = [value / 2147483648.0 for value in values]
    elif format_tag == 3 and bits == 32:
        count = len(body) // 4
        flat = list(struct.unpack("<%df" % count, body[: count * 4]))
    else:
        raise WavError(f"unsupported PCM tag={format_tag} bits={bits}")
    frames = len(flat) // channels
    result = [[0.0] * frames for _ in range(channels)]
    for index in range(frames):
        for channel in range(channels):
            result[channel][index] = flat[index * channels + channel]
    return result


def read_wav(path: Path) -> WavData:
    data = Path(path).read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise WavError("not a RIFF/WAVE file")
    position = 12
    fmt = None
    payload = None
    while position + 8 <= len(data):
        chunk_id = data[position: position + 4]
        size = struct.unpack_from("<I", data, position + 4)[0]
        body_start = position + 8
        body_end = body_start + size
        if body_end > len(data):
            raise WavError("truncated chunk")
        body = data[body_start:body_end]
        if chunk_id == b"fmt ":
            fmt = _parse_fmt(body)
        elif chunk_id == b"data":
            payload = body
        position = body_end + (size & 1)
    if fmt is None or payload is None:
        raise WavError("missing fmt or data chunk")
    format_tag, channels, rate, _byte_rate, block_align, bits, mask = fmt
    expected_align = channels * bits // 8
    if block_align != expected_align:
        raise WavError("block alignment does not match channels/bits")
    samples = _decode_pcm(payload, format_tag, bits, channels)
    return WavData(
        rate=rate,
        channels=channels,
        mask=mask,
        bits=bits,
        format_tag=format_tag,
        samples=samples,
        source_path=Path(path),
    )


def project_amplitude(samples: Sequence[float], rate: int, frequency: float) -> float:
    """Least-squares sine/cosine projection at a known frequency."""
    if not samples:
        return 0.0
    count = len(samples)
    mean = sum(samples) / count
    omega = 2.0 * math.pi * frequency / rate
    real = 0.0
    imag = 0.0
    for index, value in enumerate(samples):
        centered = value - mean
        real += centered * math.cos(omega * index)
        imag += centered * math.sin(omega * index)
    return 2.0 * math.hypot(real, imag) / count


def peak(samples: Sequence[float]) -> float:
    return max((abs(value) for value in samples), default=0.0)


def rms(samples: Sequence[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(sum(value * value for value in samples) / len(samples))


def dc(samples: Sequence[float]) -> float:
    return sum(samples) / len(samples) if samples else 0.0


def render_plan(
    path: Path,
    plan: model.RoutePlan,
    tone_map: Mapping[str, int] = model.FIXTURE_TONES,
    *,
    rate: int = 48000,
    duration: float = model.FIXTURE_DURATION_SECONDS,
    amplitude: float = model.FIXTURE_AMPLITUDE,
) -> Dict[str, object]:
    """Render a deterministic source fixture through a route matrix to WAV."""
    source_labels = model.labels_for(plan.source_layout)
    sources = source_samples(
        source_labels,
        tone_map,
        rate=rate,
        duration=duration,
        amplitude=amplitude,
    )
    frames = len(sources[source_labels[0]])
    outputs: Dict[str, List[float]] = {}
    for output_label, row in plan.matrix.items():
        buffer = [0.0] * frames
        for source_label, coefficient in row.items():
            if coefficient == 0:
                continue
            source = sources[source_label]
            for index in range(frames):
                buffer[index] += coefficient * source[index]
        outputs[output_label] = buffer

    peak_value = max(peak(values) for values in outputs.values())
    if peak_value > 1.0 + 1e-9:
        raise ClippingError(
            f"route {plan.source_layout}->{plan.container_layout} peak {peak_value:.6f}"
        )
    info = write_wav(path, rate, plan.labels, outputs, mask=model.mask_for(plan.container_layout))
    info.update(
        {
            "source_layout": plan.source_layout,
            "container_layout": plan.container_layout,
            "mode": plan.mode,
            "matrix": plan.matrix,
            "max_row_l1": model.max_row_l1(plan.matrix),
        }
    )
    return info


def file_sha256(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

