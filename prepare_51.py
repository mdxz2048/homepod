"""Build an original six-channel identification/sync signal and route its PCM.

Master WAV uses WAVE_FORMAT_EXTENSIBLE, mask 0x3f: FL FR FC LFE BL BR.
The three physical speaker layout folds front channels to one mono speaker.
"""
from array import array
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import wave

import miniaudio

RATE = 44100
SECONDS = 40
ORDER = ['FL', 'FR', 'FC', 'LFE', 'BL', 'BR']
ROOT = Path('artifacts/surround51')


def write_master(path, channels):
    interleaved = array('h', [0]) * (len(channels[0]) * 6)
    for index, channel in enumerate(channels):
        interleaved[index::6] = channel
    if sys.byteorder != 'little':
        interleaved.byteswap()
    pcm = interleaved.tobytes()
    guid_pcm = bytes.fromhex('0100000000001000800000aa00389b71')
    fmt = struct.pack('<HHIIHHHHI', 0xfffe, 6, RATE, RATE * 12, 12, 16, 22, 16, 0x3f) + guid_pcm
    path.write_bytes(b'RIFF' + struct.pack('<I', 4 + 8 + len(fmt) + 8 + len(pcm)) + b'WAVE'
                     + b'fmt ' + struct.pack('<I', len(fmt)) + fmt
                     + b'data' + struct.pack('<I', len(pcm)) + pcm)


def read_master(path):
    raw = path.read_bytes()
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        raise ValueError('Not a WAV')
    offset, fmt, pcm = 12, None, None
    while offset + 8 <= len(raw):
        tag = raw[offset:offset + 4]
        size = struct.unpack_from('<I', raw, offset + 4)[0]
        body = raw[offset + 8:offset + 8 + size]
        if tag == b'fmt ':
            fmt = body
        elif tag == b'data':
            pcm = body
        offset += 8 + size + size % 2
    if fmt is None or pcm is None:
        raise ValueError('Missing WAV chunks')
    encoding, count, rate, _, align, bits = struct.unpack_from('<HHIIHH', fmt)
    if (encoding, count, rate, align, bits) != (0xfffe, 6, RATE, 12, 16):
        raise ValueError('Unexpected master format')
    if struct.unpack_from('<I', fmt, 20)[0] != 0x3f:
        raise ValueError('Unexpected channel mask')
    samples = array('h')
    samples.frombytes(pcm)
    if sys.byteorder != 'little':
        samples.byteswap()
    return [samples[i::6] for i in range(6)]


def write_stereo(path, left, right):
    samples = array('h', [0]) * (len(left) * 2)
    samples[0::2], samples[1::2] = left, right
    if sys.byteorder != 'little':
        samples.byteswap()
    with wave.open(str(path), 'wb') as output:
        output.setparams((2, 2, RATE, 0, 'NONE', 'not compressed'))
        output.writeframes(samples.tobytes())


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    channels = [array('h', [0]) * (RATE * SECONDS) for _ in ORDER]
    events = []

    def speech(name, start, channel):
        audio = miniaudio.decode_file(str(ROOT / 'speech' / f'{name}.wav'),
                                     output_format=miniaudio.SampleFormat.SIGNED16,
                                     nchannels=1, sample_rate=RATE)
        offset = round(start * RATE)
        for index, value in enumerate(audio.samples):
            if offset + index < len(channels[channel]):
                channels[channel][offset + index] = round(value * 0.65)
        events.append({'kind': 'speech', 'channel': ORDER[channel], 'time': start, 'phrase': name})

    def tone(start, duration, channel, frequency, amplitude=0.2):
        offset = round(start * RATE)
        frames = round(duration * RATE)
        for index in range(frames):
            envelope = min(1, index / (RATE * 0.005), (frames - index) / (RATE * 0.005))
            value = round(32767 * amplitude * envelope * math.sin(2 * math.pi * frequency * index / RATE))
            channels[channel][offset + index] += value

    for name, start, channel in [('FL', 2, 0), ('FR', 5, 1), ('FC', 8, 2),
                                  ('BL', 14, 4), ('BR', 17, 5), ('MIX', 20, 2)]:
        speech(name, start, channel)
    tone(12, 0.8, 3, 70, 0.22)
    events.append({'kind': 'LFE tone', 'channel': 'LFE', 'time': 12, 'frequency': 70})
    for step in range(12):
        start = 20 + step * 0.5
        tone(start, 0.18, 0, [262, 330, 392][step % 3], 0.06)
        tone(start, 0.18, 1, [392, 330, 262][step % 3], 0.06)
        tone(start, 0.12, 4, [523, 659, 784][step % 3], 0.13)
        tone(start + 0.25, 0.12, 5, [784, 659, 523][step % 3], 0.13)
    for cycle in range(5):
        start = 28 + cycle * 2
        for position, channel in enumerate([2, 4, 5]):
            at = start + position * 0.1
            tone(at, 0.025, channel, 1800, 0.2)
            events.append({'kind': 'sync marker', 'channel': ORDER[channel], 'time': at,
                           'cycle': cycle, 'expected_offset_ms': position * 100})
    master = ROOT / 'master-5.1.wav'
    write_master(master, channels)
    # Decode the written six-channel source before routing; outputs are not
    # independently generated tracks.
    decoded = read_master(master)
    assert all(a == b for a, b in zip(channels, decoded)), 'Master PCM round-trip failed'
    front = array('h')
    for fl, fr, fc, lfe in zip(*decoded[:4]):
        value = round(0.5 * fl + 0.5 * fr + 0.7071 * fc + 0.3162 * lfe)
        if not -32768 <= value <= 32767:
            raise ValueError('Front downmix clipped')
        front.append(value)
    write_stereo(ROOT / 'front.wav', front, front)
    write_stereo(ROOT / 'rear.wav', decoded[4], decoded[5])
    for channel, start in [(0, 2), (1, 5), (2, 8), (3, 12), (4, 14), (5, 17)]:
        window = slice(start * RATE, (start + 2) * RATE)
        assert any(decoded[channel][window]), 'Missing channel identification signal'
        assert all(not any(decoded[other][window]) for other in range(6) if other != channel), 'Channel leakage'
    with wave.open(str(ROOT / 'rear.wav')) as rear_file:
        samples = array('h', rear_file.readframes(rear_file.getnframes()))
        if sys.byteorder != 'little':
            samples.byteswap()
        assert samples[0::2] == decoded[4] and samples[1::2] == decoded[5]
    manifest = {'version': 1, 'kind': 'generated_discrete_5.1_test', 'sample_rate': RATE,
                'duration_seconds': SECONDS, 'frames': RATE * SECONDS,
                'channel_order': ORDER, 'channel_mask': '0x3f',
                'source': master.name, 'source_sha256': hashlib.sha256(master.read_bytes()).hexdigest(),
                'outputs': {'front': 'front.wav', 'rear': 'rear.wav'},
                'routing': {'front_mono': {'FL': 0.5, 'FR': 0.5, 'FC': 0.7071, 'LFE': 0.3162},
                            'rear_left': 'BL', 'rear_right': 'BR'},
                'events': events,
                'checks': {'source_pcm_round_trip': True, 'identification_channel_isolation': True,
                           'rear_output_matches_source_surrounds': True, 'front_no_clipping': True},
                'acoustic_sync_verified': False}
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in manifest.items() if k != 'events'}, indent=2))


if __name__ == '__main__':
    main()
