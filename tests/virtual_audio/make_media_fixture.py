"""Generate local HTMLMedia A/V fixture; never play, capture, install, or use network."""
import argparse
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import wave

RATE = 48000
FPS = 30
DURATION = 11
EVENTS = (2, 5, 8)


def create(output: Path, ffmpeg=None):
    output.mkdir(parents=True, exist_ok=False)
    pcm = bytearray(RATE * DURATION * 2)
    for onset in EVENTS:
        for i in range(int(.040 * RATE)):
            # Soft edges reduce accidental codec pre-echo / transient clipping.
            envelope = min(1, i / 96, (1920 - i) / 96)
            sample = round(8000 * envelope * math.sin(2 * math.pi * 1500 * i / RATE))
            struct.pack_into('<h', pcm, (onset * RATE + i) * 2, sample)
    with wave.open(str(output / 'reference.wav'), 'wb') as wav:
        wav.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        wav.writeframes(pcm)
    manifest = {'rate': RATE, 'fps': FPS, 'duration_s': DURATION,
                'event_seconds': EVENTS, 'flash_frames': 3,
                'pulse_duration_ms': 40, 'video_created': False,
                'status': 'fixture_only_not_a_measurement',
                'audio_codec_note': 'AAC priming/pre-echo must be calibrated using encoded file baseline'}
    if ffmpeg:
        executable = shutil.which(ffmpeg)
        if not executable:
            raise ValueError('Explicit ffmpeg executable not found; no download attempted')
        enable = '+'.join(f'between(n,{t * FPS},{t * FPS + 2})' for t in EVENTS)
        subprocess.run([executable, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                        f'color=black:size=640x360:rate={FPS}:duration={DURATION}',
                        '-i', str(output / 'reference.wav'), '-vf',
                        f"drawbox=color=white:t=fill:enable='{enable}'",
                        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
                        '-b:a', '192k', '-movflags', '+faststart',
                        str(output / 'sync.mp4')], check=True, timeout=120)
        manifest['video_created'] = True
    (output / 'fixture.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (output / 'index.html').write_text('''<!doctype html><meta charset="utf-8">
<title>HomePod Flow HTMLMedia synchronization fixture</title>
<style>body{background:#333;color:white;font:18px system-ui}video{width:min(90vw,960px)}</style>
<h1>HTMLMedia A/V fixture</h1>
<p>Manual playback only. Start at low volume. Use the same file for every output path.</p>
<video controls preload="metadata" src="sync.mp4"></video>
<p>Three white flashes and matching pulses at 2, 5, 8 seconds. This page does not measure synchronization.</p>
''', encoding='utf-8')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New local directory')
    parser.add_argument('--ffmpeg', help='Explicit executable; omit to generate WAV/manifest/page only')
    args = parser.parse_args()
    print(json.dumps(create(args.output, args.ffmpeg), indent=2))
