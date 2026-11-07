#!/usr/bin/env python3
"""Generate a reproducible HomePod Flow A/B fixture: one MP4 asset that carries
simultaneous full-screen quadrant flashes and short beeps in the SAME encoded
file, plus an ordinary <video> page. No WebAudio and no JS timers.

Dependencies: Python 3 stdlib only, plus ffmpeg (ffmpeg.org) on PATH.
Media is generated on demand; it must never be committed to the repository.

By construction the flash and beep onsets share one media timeline, so the
encoded asset is A/V in sync. Any observed offset in a single-camera recording
is therefore introduced by the playback chain (player compensation, virtual
device budget, network speakers), which is exactly what the 0 s vs 2 s A/B is
meant to expose.

Example:
    python3 make_fixture.py --out-dir /tmp/hpf-fixture
    python3 make_fixture.py --out-dir /tmp/hpf-fixture --events 10 --event-interval 2.0
"""

from __future__ import annotations

import argparse
import array
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Generate synchronized flash+beep MP4 fixture and player page.")
    p.add_argument("--out-dir", default=None,
                   help="Directory for outputs. Defaults to a fresh temp dir so media "
                        "is never written into the repository by accident.")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--sample-rate", type=int, default=48000)
    p.add_argument("--event-start", type=float, default=1.0,
                   help="Time of the first flash/beep onset, seconds.")
    p.add_argument("--event-interval", type=float, default=3.0)
    p.add_argument("--events", type=int, default=8)
    p.add_argument("--beep-duration-ms", type=int, default=80)
    p.add_argument("--beep-frequency", type=int, default=1000)
    p.add_argument("--flash-duration", type=float, default=0.25)
    p.add_argument("--tail", type=float, default=1.5,
                   help="Seconds of black after the last event.")
    p.add_argument("--ffmpeg", default="ffmpeg")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args(argv)


def build_events(args, duration):
    return [
        {
            "index": i,
            "flash_onset_s": round(args.event_start + i * args.event_interval, 6),
            "beep_onset_s": round(args.event_start + i * args.event_interval, 6),
            "flash_duration_s": round(args.flash_duration, 6),
            "beep_duration_s": round(args.beep_duration_ms / 1000.0, 6),
            "beep_frequency_hz": args.beep_frequency,
        }
        for i in range(args.events)
    ]


def write_wav(path: Path, events, args, total_samples: int):
    """Write a mono 16-bit WAV with one short faded sine burst per event."""
    import wave

    samples = array.array("h", [0]) * total_samples
    beep_n = int(round(args.beep_duration_ms / 1000.0 * args.sample_rate))
    fade_n = min(int(round(0.005 * args.sample_rate)), max(1, beep_n // 2))
    amplitude = 0.5 * 32767
    for event in events:
        start = int(round(event["beep_onset_s"] * args.sample_rate))
        if start < 0 or start + beep_n > total_samples:
            raise SystemExit(f"beep sample range out of bounds for event {event['index']}")
        for j in range(beep_n):
            t = j / args.sample_rate
            envelope = 1.0
            if j < fade_n:
                envelope = j / fade_n
            elif j >= beep_n - fade_n:
                envelope = (beep_n - 1 - j) / fade_n
            envelope = max(0.0, min(1.0, envelope))
            freq = event["beep_frequency_hz"]
            value = amplitude * envelope * math.sin(2.0 * math.pi * freq * t)
            samples[start + j] = int(round(value))

    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(args.sample_rate)
        wav.writeframes(samples.tobytes())


def panel_layout(args):
    """Four simultaneous full-quadrant flash panels with distinct base colors."""
    half_w = args.width // 2
    half_h = args.height // 2
    panels = [
        {"name": "TL", "x": 0, "y": 0, "w": half_w, "h": half_h, "base": "0x330000", "flash": "white"},
        {"name": "TR", "x": half_w, "y": 0, "w": args.width - half_w, "h": half_h,
         "base": "0x003300", "flash": "white"},
        {"name": "BL", "x": 0, "y": half_h, "w": half_w, "h": args.height - half_h,
         "base": "0x000033", "flash": "white"},
        {"name": "BR", "x": half_w, "y": half_h, "w": args.width - half_w,
         "h": args.height - half_h, "base": "0x333300", "flash": "white"},
    ]
    return panels


def build_filter(args, events, panels) -> str:
    """Chain drawbox filters on top of the lavfi color source."""
    parts = []
    for panel in panels:
        parts.append(
            "drawbox=x={x}:y={y}:w={w}:h={h}:color={color}:t=fill".format(
                x=panel["x"], y=panel["y"], w=panel["w"], h=panel["h"], color=panel["base"]))
    for event in events:
        a = event["flash_onset_s"]
        b = round(a + args.flash_duration, 6)
        for panel in panels:
            parts.append(
                "drawbox=x={x}:y={y}:w={w}:h={h}:color={color}:t=fill"
                ":enable='between(t,{a},{b})'".format(
                    x=panel["x"], y=panel["y"], w=panel["w"], h=panel["h"],
                    color=panel["flash"], a=a, b=b))
    return ",".join(parts)


def run_ffmpeg(args, video_filter: str, wav_path: Path, out_video: Path, duration):
    cmd = [
        args.ffmpeg, "-y", "-hide_banner",
    ]
    if args.quiet:
        cmd += ["-loglevel", "error"]
    cmd += [
        "-f", "lavfi",
        "-i", f"color=c=black:s={args.width}x{args.height}:r={args.fps}:d={duration:0.6f}",
        "-i", str(wav_path),
        "-filter_complex", f"[0:v]{video_filter}[vout]",
        "-map", "[vout]",
        "-map", "1:a",
        "-c:v", "libx264",
        "-preset", "medium",
        "-pix_fmt", "yuv420p",
        "-g", str(args.fps),
        "-bf", "0",
        "-c:a", "aac",
        "-b:a", "128k",
        "-t", f"{duration:0.6f}",
        str(out_video),
    ]
    try:
        completed = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise SystemExit(
            f"could not run ffmpeg: {exc}. Pass --ffmpeg /path/to/ffmpeg if it is "
            "not on PATH (e.g. /opt/homebrew/bin/ffmpeg).")
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr.decode("utf-8", "replace")[-4000:])
        raise SystemExit(f"ffmpeg failed with exit code {completed.returncode}")


def write_player(out_dir: Path, video_name: str):
    html = """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>HPF AV-latency A/B fixture</title>
  <style>
    html, body { margin: 0; padding: 0; background: #000; width: 100%; height: 100%; overflow: hidden; }
    video { width: 100vw; height: 100vh; object-fit: contain; background: #000; }
    .note { position: fixed; left: 8px; bottom: 8px; color: #666; font: 12px/1.4 monospace; }
  </style>
</head>
<body>
  <!-- Ordinary HTML video only. Audio and video live in one encoded asset.
       No WebAudio, no Canvas, no JS timers: JS here is inert/absent by design. -->
  <video src="VIDEO_NAME" controls playsinline loop></video>
  <div class="note">HPF A/B fixture: simultaneous quadrant flashes + short beeps in one MP4.</div>
</body>
</html>
""".replace("VIDEO_NAME", video_name)
    (out_dir / "player.html").write_text(html, encoding="utf-8")


def main(argv):
    args = parse_args(argv)
    out_dir = Path(args.out_dir) if args.out_dir else Path(tempfile.mkdtemp(prefix="hpf-fixture-"))
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.events < 1 or args.event_start < 0 or args.event_interval <= 0 or args.tail < 0:
        raise SystemExit("invalid event geometry")
    duration = args.event_start + (args.events - 1) * args.event_interval + \
        args.flash_duration + args.tail
    total_samples = int(math.ceil(duration * args.sample_rate))

    events = build_events(args, duration)
    panels = panel_layout(args)
    wav_path = out_dir / "beeps.wav"
    video_path = out_dir / "fixture.mp4"
    write_wav(wav_path, events, args, total_samples)
    run_ffmpeg(args, build_filter(args, events, panels), wav_path, video_path, duration)
    write_player(out_dir, video_path.name)

    manifest = {
        "schema": "hpf-chrome-latency-fixture.v1",
        "generator": "make_fixture.py",
        "arguments": vars(args),
        "duration_s": round(duration, 6),
        "width": args.width,
        "height": args.height,
        "fps": args.fps,
        "sample_rate": args.sample_rate,
        "audio_channels": 1,
        "audio_codec": "aac",
        "video_codec": "libx264",
        "player": "player.html",
        "video": video_path.name,
        "audio_intermediate": wav_path.name,
        "asset_av_sync_s": 0.0,
        "panels": panels,
        "events": events,
        "note": "media is generated on demand and must never be committed to git.",
    }
    (out_dir / "events.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=True), encoding="utf-8")
    print(f"fixture_dir={out_dir}")
    print(f"video={video_path}")
    print(f"events={out_dir / 'events.json'}")
    print(f"player=file://{out_dir / 'player.html'}")
    print(f"duration_s={duration:0.3f} events={args.events}")


if __name__ == "__main__":
    main(sys.argv[1:])
