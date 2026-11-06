"""Extract an actual six-channel film soundtrack and prepare two routed outputs."""
from array import array
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

import miniaudio
from prepare_51 import RATE, ORDER, write_master, read_master, write_stereo

URL = 'https://media.xiph.org/sintel/sintel-master-51.flac'


def metadata(path):
    comments = []
    info = None
    with path.open('rb') as source:
        if source.read(4) != b'fLaC':
            raise ValueError('Not a FLAC file')
        while True:
            header = source.read(4)
            if len(header) != 4:
                raise ValueError('Truncated FLAC metadata')
            block_type = header[0] & 0x7f
            payload = source.read(int.from_bytes(header[1:], 'big'))
            if block_type == 0:
                value = int.from_bytes(payload[10:18], 'big')
                info = {'sample_rate': value >> 44, 'channels': ((value >> 41) & 7) + 1,
                        'bits_per_sample': ((value >> 36) & 31) + 1,
                        'frames': value & ((1 << 36) - 1)}
            elif block_type == 4:
                vendor_size = struct.unpack_from('<I', payload)[0]
                offset = 4 + vendor_size
                count = struct.unpack_from('<I', payload, offset)[0]
                offset += 4
                for _ in range(count):
                    length = struct.unpack_from('<I', payload, offset)[0]
                    offset += 4
                    comments.append(payload[offset:offset + length].decode('utf-8', 'replace'))
                    offset += length
            if header[0] & 0x80:
                break
    if not info or info['channels'] != 6:
        raise ValueError('Source is not six-channel audio')
    masks = [s.split('=', 1)[1] for s in comments
             if s.upper().startswith('WAVEFORMATEXTENSIBLE_CHANNEL_MASK=')]
    if masks and int(masks[0], 16) not in (0x3f, 0x60f):
        raise ValueError('Unsupported six-channel speaker layout')
    info['declared_channel_mask'] = masks[0] if masks else 'FLAC standard six-channel order'
    info['duration_seconds'] = info['frames'] / info['sample_rate']
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', default='artifacts/downloaded51/sintel-master-51-complete.flac')
    parser.add_argument('--start', type=int, default=660)
    parser.add_argument('--seconds', type=int, default=40)
    args = parser.parse_args()
    source = Path(args.source)
    info = metadata(source)
    if args.start < 0 or args.seconds < 1 or args.start + args.seconds > info['duration_seconds']:
        raise ValueError('Invalid clip interval')
    # Decode six channels at once, maintaining common sample boundaries. Output
    # conversion is 44.1 kHz/16-bit for the current AirPlay sender.
    decoder = miniaudio.stream_file(str(source), nchannels=6, sample_rate=RATE,
                                   output_format=miniaudio.SampleFormat.SIGNED16,
                                   frames_to_read=8192, seek_frame=args.start * RATE)
    samples = array('h')
    needed = args.seconds * RATE * 6
    try:
        while len(samples) < needed:
            samples.extend(next(decoder))
    except StopIteration:
        raise ValueError('Source ended before requested clip was decoded')
    finally:
        decoder.close()
    del samples[needed:]
    channels = [samples[i::6] for i in range(6)]
    root = source.parent / 'sintel-clip'
    root.mkdir(exist_ok=True)
    master = root / 'master-5.1.wav'
    write_master(master, channels)
    decoded = read_master(master)
    assert all(a == b for a, b in zip(channels, decoded)), 'Six-channel PCM changed on WAV round-trip'
    gain = 0.45
    front = array('h', (round(gain * (0.5 * fl + 0.5 * fr + 0.7071 * fc + 0.3162 * lfe))
                        for fl, fr, fc, lfe in zip(*decoded[:4])))
    left = array('h', (round(gain * value) for value in decoded[4]))
    right = array('h', (round(gain * value) for value in decoded[5]))
    write_stereo(root / 'front.wav', front, front)
    write_stereo(root / 'rear.wav', left, right)
    assert left != right and front != left and front != right, 'Outputs are unexpectedly identical'
    manifest = {'version': 1, 'kind': 'downloaded_discrete_5.1_clip',
                'title': 'Sintel - 5.1 soundtrack excerpt',
                'source_url': URL, 'source_catalog': 'https://media.xiph.org/',
                'source': source.name, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'source_metadata': info, 'source_start_seconds': args.start,
                'sample_rate': RATE, 'duration_seconds': args.seconds, 'frames': args.seconds * RATE,
                'channel_order': ORDER, 'outputs': {'front': 'front.wav', 'rear': 'rear.wav'},
                'routing': {'front_mono': {'FL': 0.5, 'FR': 0.5, 'FC': 0.7071, 'LFE': 0.3162},
                            'rear_left': 'BL', 'rear_right': 'BR', 'common_gain': gain},
                'channel_peak': {name: max(map(abs, channel)) for name, channel in zip(ORDER, decoded)},
                'checks': {'source_has_six_channels': True, 'source_pcm_round_trip': True,
                           'different_output_content': True, 'front_no_clipping': True},
                'acoustic_sync_verified': False}
    (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()
