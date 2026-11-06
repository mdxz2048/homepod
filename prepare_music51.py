"""Route a downloaded, publisher-provided surround music preview to three speakers."""
from array import array
import hashlib
import json
from pathlib import Path

import av
import numpy as np

from prepare_51 import RATE, write_master, write_stereo


def main():
    root = Path('artifacts/music51')
    source = root / 'odyssey-emphasis-excerpt.ac3'
    frames = []
    with av.open(str(source)) as container:
        stream = container.streams.audio[0]
        layout = stream.codec_context.layout
        names = [channel.name for channel in layout.channels]
        if len(names) != 6 or not all(c in names for c in ['FL', 'FR', 'FC', 'LFE']):
            raise ValueError(f'Expected real 5.1 layout, found {names}')
        metadata = {'codec': stream.codec_context.name, 'sample_rate': stream.codec_context.sample_rate,
                    'layout': layout.name, 'channel_order': names}
        resampler = av.AudioResampler(format='fltp', layout=layout, rate=RATE)
        for frame in container.decode(stream):
            frames.extend(converted.to_ndarray() for converted in resampler.resample(frame))
        frames.extend(converted.to_ndarray() for converted in resampler.resample(None))
    full = np.concatenate(frames, axis=1)
    start, duration = 10, 60
    clip = full[:, start * RATE:(start + duration) * RATE]
    if clip.shape[1] != duration * RATE:
        raise ValueError('Downloaded preview is shorter than requested excerpt')
    by_name = dict(zip(names, clip))
    left_name = 'SL' if 'SL' in by_name else 'BL'
    right_name = 'SR' if 'SR' in by_name else 'BR'
    canonical = np.stack([by_name[c] for c in ['FL', 'FR', 'FC', 'LFE', left_name, right_name]])
    gain = 0.45
    front = gain * (0.5 * by_name['FL'] + 0.5 * by_name['FR'] + 0.7071 * by_name['FC'] + 0.3162 * by_name['LFE'])
    left, right = gain * by_name[left_name], gain * by_name[right_name]
    if max(np.max(np.abs(front)), np.max(np.abs(left)), np.max(np.abs(right))) >= 1:
        raise ValueError('Routed audio would clip')

    def pcm(values):
        return array('h', np.rint(np.clip(values, -1, 32767 / 32768) * 32768).astype(np.int16).tolist())

    master = root / 'master-5.1.wav'
    write_master(master, [pcm(channel) for channel in canonical])
    front_pcm, left_pcm, right_pcm = pcm(front), pcm(left), pcm(right)
    write_stereo(root / 'front.wav', front_pcm, front_pcm)
    write_stereo(root / 'rear-left.wav', left_pcm, left_pcm)
    write_stereo(root / 'rear-right.wav', right_pcm, right_pcm)
    assert left_pcm != right_pcm and front_pcm != left_pcm and front_pcm != right_pcm
    manifest = {'version': 1, 'kind': 'downloaded_discrete_5.1_music', 'title': 'Odyssey - Emphasis',
                'source_url': 'https://www.hirez.one/streaming/odyssey/odyssey-metastasia-emphasis.ac3',
                'publisher_page': 'https://surroundmusic.one/streaming/',
                'source_metadata': metadata, 'source_start_seconds': start,
                'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'sample_rate': RATE, 'duration_seconds': duration, 'frames': duration * RATE,
                'channel_order': names, 'rendered_master_channel_order': ['FL', 'FR', 'FC', 'LFE', 'BL', 'BR'],
                'outputs': {'front': 'front.wav', 'rear-left': 'rear-left.wav', 'rear-right': 'rear-right.wav'},
                'routing': {'front': '0.45*(0.5*FL+0.5*FR+0.7071*FC+0.3162*LFE)',
                            'rear-left': f'0.45*{left_name}', 'rear-right': f'0.45*{right_name}'},
                'output_peak': {'front': float(np.max(np.abs(front))),
                                'rear-left': float(np.max(np.abs(left))), 'rear-right': float(np.max(np.abs(right)))},
                'checks': {'six_channel_source_verified': True, 'different_output_content': True,
                           'no_output_clipping': True}, 'acoustic_sync_verified': False}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
