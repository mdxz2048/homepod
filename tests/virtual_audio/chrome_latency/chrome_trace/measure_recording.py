#!/usr/bin/env python3
"""Single-camera acoustic A/B measurement helper (assist only, not a pass claim).

Reads one camera recording that captured the fixture screen + audible beeps,
then estimates flash onsets from video brightness and beep onsets from audio
energy. For each paired event it reports the audio-minus-video delta and the
P95 of the per-event absolute deltas.

This is a helper, not an oracle. Camera A/V muxing, room acoustics, autofocus
and compression all add error; confirm a sample of onsets by hand in an editor
before treating the P95 as the experiment result.

Usage:
    python3 measure_recording.py recording.mov -o acoustic_analysis.json \
        [--events-file events.json]
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    return sorted_values[max(1, math.ceil(p / 100.0 * len(sorted_values))) - 1]


def audio_onsets(path, sr, window_ms, hop_ms, threshold_factor, cooldown_s):
    import array
    raw = run(["ffmpeg", "-loglevel", "error", "-i", str(path),
               "-ac", "1", "-ar", str(sr), "-f", "f32le", "pipe:1"])
    samples = array.array("f")
    samples.frombytes(raw)
    if len(samples) == 0:
        raise SystemExit("recording has no audio track")
    window = max(1, int(window_ms / 1000 * sr))
    hop = max(1, int(hop_ms / 1000 * sr))
    energies = []
    for start in range(0, max(1, len(samples) - window + 1), hop):
        chunk = samples[start:start + window]
        rms = math.sqrt(sum(v * v for v in chunk) / len(chunk))
        energies.append((start / sr, rms))
    floor = min(e for _, e in energies) + 1e-9
    threshold = max(floor * threshold_factor, 0.01)
    cooldown = cooldown_s
    onsets = []
    last = -cooldown - 1
    for time_s, e in energies:
        if e > threshold and time_s - last > cooldown:
            onsets.append(time_s)
            last = time_s
    return onsets, float(threshold)


def video_onsets(path, sample_fps, threshold_factor):
    raw = run(["ffmpeg", "-loglevel", "error", "-i", str(path),
               "-vf", f"scale=48:27:flags=bilinear,format=gray,fps={sample_fps}",
               "-f", "rawvideo", "pipe:1"])
    frame_n = 48 * 27
    if len(raw) % frame_n != 0:
        raise SystemExit(f"unexpected video frame size (got {len(raw)} bytes)")
    means = []
    for i in range(0, len(raw), frame_n):
        chunk = raw[i:i + frame_n]
        means.append(sum(chunk) / frame_n)
    frames = len(means)
    if frames == 0:
        return [], 0.0
    baseline = sum(means) / frames
    threshold = max(baseline * threshold_factor, baseline + 40, 70)
    onsets = []
    last = -1e9
    for idx, m in enumerate(means):
        if m > threshold and (idx - last) > sample_fps * 0.5:
            onsets.append(idx / sample_fps)
            last = idx
    return onsets, float(threshold)


def pair(events, audio, video):
    pairs = []
    used = set()
    for index, a in enumerate(audio):
        if not video:
            break
        best = min(range(len(video)), key=lambda j: abs(video[j] - a))
        if best in used:
            continue
        used.add(best)
        pairs.append({
            "index": len(pairs) + 1,
            "audio_onset_s": round(a, 6),
            "video_onset_s": round(video[best], 6),
            "delta_s": round(a - video[best], 6),
        })
    if events is not None and isinstance(events, list):
        for pair, event in zip(pairs, events):
            pair["expected_index"] = event.get("index")
    return pairs


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("recording")
    p.add_argument("-o", "--output", default="acoustic_analysis.json")
    p.add_argument("--events-file", default=None)
    p.add_argument("--sample-rate", type=int, default=16000)
    p.add_argument("--window-ms", type=int, default=10)
    p.add_argument("--hop-ms", type=int, default=5)
    p.add_argument("--audio-threshold-factor", type=float, default=8.0)
    p.add_argument("--video-sample-fps", type=float, default=8.0)
    p.add_argument("--video-threshold-factor", type=float, default=1.5)
    p.add_argument("--cooldown-s", type=float, default=0.8)
    args = p.parse_args(argv)

    events = None
    if args.events_file:
        manifest = json.loads(Path(args.events_file).read_text(encoding="utf-8"))
        events = manifest.get("events")

    beeps, audio_threshold = audio_onsets(
        Path(args.recording), args.sample_rate, args.window_ms, args.hop_ms,
        args.audio_threshold_factor, args.cooldown_s)
    flashes, video_threshold = video_onsets(
        Path(args.recording), args.video_sample_fps, args.video_threshold_factor)
    pairs = pair(events, beeps, flashes)
    deltas = sorted(abs(pair["delta_s"]) for pair in pairs)

    result = {
        "schema": "hpf-acoustic-analysis.v1",
        "recording": str(args.recording),
        "detected_beep_onsets": [round(v, 6) for v in beeps],
        "detected_flash_onsets": [round(v, 6) for v in flashes],
        "audio_threshold": audio_threshold,
        "video_threshold": video_threshold,
        "paired_events": pairs,
        "paired_count": len(pairs),
        "p50_delta_s": percentile(deltas, 50),
        "p95_delta_s": percentile(deltas, 95),
        "comparison": "compensation_experiment_av_skew",
        "interpretation_guard": (
            "stays near 0 when the player honors the budget; grows toward the "
            "configured budget when the player ignores it. Camera error and "
            "room acoustics remain; confirm by hand before using."),
        "method_guard": "assist only, not an automated pass claim",
    }
    text = json.dumps(result, indent=2, ensure_ascii=True)
    Path(args.output).write_text(text, encoding="utf-8")
    print(text)
    if len(pairs) < 1:
        print("WARNING: no paired events detected; do not treat as evidence.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
