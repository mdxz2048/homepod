"""Build a 30-second spoken physical-speaker identification bundle."""
from array import array
import hashlib
import json
from pathlib import Path
import math
import miniaudio
from prepare_51 import RATE, ORDER, write_master, read_master, write_stereo


def main():
    root = Path('artifacts/position30')
    duration = 30
    channels = [array('h', [0]) * (RATE * duration) for _ in range(6)]
    events = []
    for name, start, channel in [('front', 1, 2), ('left', 7, 4), ('right', 13, 5), ('mixed', 19, 2)]:
        audio = miniaudio.decode_file(str(root / 'speech' / f'{name}.wav'),
                                     output_format=miniaudio.SampleFormat.SIGNED16,
                                     nchannels=1, sample_rate=RATE)
        if len(audio.samples) > (6 if name != 'mixed' else 10) * RATE:
            raise ValueError(f'Spoken label too long: {name}')
        offset = start * RATE
        channels[channel][offset:offset + len(audio.samples)] = audio.samples
        events.append({'role': name, 'start_seconds': start,
                       'duration_seconds': len(audio.samples) / RATE})
    for step in range(18):
        for channel, frequency, start in [(4, 660, 19 + step * 0.5), (5, 990, 19.25 + step * 0.5)]:
            for index in range(round(0.12 * RATE)):
                envelope = math.sin(math.pi * index / (0.12 * RATE)) ** 2
                channels[channel][round(start * RATE) + index] = round(32767 * 0.25 * envelope * math.sin(2 * math.pi * frequency * index / RATE))
    source = root / 'master-5.1.wav'
    write_master(source, channels)
    decoded = read_master(source)
    assert all(a == b for a, b in zip(channels, decoded))
    # Only the center channel is occupied in front for this physical-position test.
    write_stereo(root / 'front.wav', decoded[2], decoded[2])
    write_stereo(root / 'rear.wav', decoded[4], decoded[5])
    write_stereo(root / 'rear-left.wav', decoded[4], decoded[4])
    write_stereo(root / 'rear-right.wav', decoded[5], decoded[5])
    for start, channel in [(1, 2), (7, 4), (13, 5)]:
        window = slice(start * RATE, (start + 6) * RATE)
        assert any(decoded[channel][window])
        assert all(not any(decoded[i][window]) for i in range(6) if i != channel)
    manifest = {'version': 1, 'kind': 'generated_discrete_5.1_test',
                'purpose': 'physical speaker identification; not an acoustic sync measurement',
                'source': source.name, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'sample_rate': RATE, 'duration_seconds': duration, 'frames': RATE * duration,
                'channel_order': ORDER, 'outputs': {'front': 'front.wav', 'rear': 'rear.wav',
                                                  'rear-left': 'rear-left.wav', 'rear-right': 'rear-right.wav'},
                'events': events, 'acoustic_sync_verified': False}
    (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()
