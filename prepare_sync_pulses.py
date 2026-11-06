"""Distinct-frequency, sample-aligned pulses for an acoustic sync experiment."""
from array import array
import argparse
import hashlib
import json
import math
from pathlib import Path

from prepare_51 import RATE, ORDER, write_master, read_master, write_stereo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recording', action='store_true', help='30-second measurement sequence with separated non-harmonic tones')
    args = parser.parse_args()
    duration = 30 if args.recording else 15
    root = Path('artifacts/sync-recording30' if args.recording else 'artifacts/sync15')
    root.mkdir(exist_ok=True)
    channels = [array('h', [0]) * (duration * RATE) for _ in range(6)]
    frequencies = (701, 1297, 2011) if args.recording else (440, 660, 880)
    roles = dict(zip(('front', 'rear-left', 'rear-right'), zip((2, 4, 5), frequencies)))
    events = []

    def pulse(start, names):
        begin = round(start * RATE)
        length = round(0.08 * RATE)
        for name in names:
            channel, frequency = roles[name]
            for sample in range(length):
                attack = min(1.0, sample / (0.001 * RATE))
                release = min(1.0, (length - sample) / (0.005 * RATE))
                value = 0.3 * attack * release * math.sin(2 * math.pi * frequency * sample / RATE)
                channels[channel][begin + sample] = round(32767 * value)
        events.append({'source_time_seconds': start, 'roles': names, 'expected_onset_difference_ms': 0})

    if args.recording:
        pulse(2, ['front'])
        pulse(3, ['rear-left'])
        pulse(4, ['rear-right'])
        for second in range(6, 29):
            pulse(second, list(roles))
    else:
        pulse(0.5, ['front'])
        pulse(1.0, ['rear-left'])
        pulse(1.5, ['rear-right'])
        for second in range(3, 7):
            pulse(second, ['front', 'rear-left'])
        for second in range(7, 11):
            pulse(second, ['front', 'rear-right'])
        for second in range(11, 15):
            pulse(second, list(roles))
    master = root / 'master-5.1.wav'
    write_master(master, channels)
    decoded = read_master(master)
    assert all(a == b for a, b in zip(channels, decoded))
    outputs = {}
    for role, (channel, _) in roles.items():
        filename = f'{role}.wav'
        write_stereo(root / filename, decoded[channel], decoded[channel])
        outputs[role] = filename
    for event in events:
        first_samples = []
        begin = round(event['source_time_seconds'] * RATE)
        for role in event['roles']:
            channel = roles[role][0]
            first_samples.append(next(i for i in range(200) if decoded[channel][begin + i]))
        assert max(first_samples) - min(first_samples) <= 1, 'Source onsets not aligned'
    manifest = {'version': 1, 'kind': 'generated_discrete_5.1_test',
                'purpose': 'simultaneous different-content pulses; acoustic onset alignment requires measurement',
                'source_sha256': hashlib.sha256(master.read_bytes()).hexdigest(),
                'sample_rate': RATE, 'duration_seconds': duration, 'frames': RATE * duration,
                'channel_order': ORDER, 'outputs': outputs, 'events': events,
                'frequencies_hz': {role: frequency for role, (_, frequency) in roles.items()},
                'source_onsets_verified_within_one_sample': True, 'acoustic_sync_verified': False}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(f'{duration}-second sync bundle prepared. Source onsets verified within one sample.')


if __name__ == '__main__':
    main()
