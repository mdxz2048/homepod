"""Decode the user's acoustic recording and inspect the three known tone bands."""
import argparse
import json
from pathlib import Path

import av
import numpy as np
from scipy import signal


def decode(path, rate=16000):
    samples = []
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        info = {'codec': stream.codec_context.name, 'sample_rate': stream.codec_context.sample_rate,
                'channels': stream.codec_context.channels,
                'container_duration_seconds': container.duration / av.time_base if container.duration else None}
        resampler = av.AudioResampler(format='fltp', layout='mono', rate=rate)
        for frame in container.decode(stream):
            for converted in resampler.resample(frame):
                samples.append(converted.to_ndarray().reshape(-1))
        for converted in resampler.resample(None):
            samples.append(converted.to_ndarray().reshape(-1))
    return np.concatenate(samples).astype(np.float64), info


def envelopes(audio, rate):
    output = {}
    for role, frequency in [('front', 701), ('rear-left', 1297), ('rear-right', 2011)]:
        filt = signal.butter(4, [frequency - 150, frequency + 150], fs=rate, btype='bandpass', output='sos')
        filtered = signal.sosfiltfilt(filt, audio)
        envelope = np.abs(signal.hilbert(filtered))
        envelope = signal.sosfiltfilt(signal.butter(2, 250, fs=rate, output='sos'), envelope)
        output[role] = np.maximum(envelope, 0)
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('recording')
    args = parser.parse_args()
    root = Path('artifacts/recording-analysis')
    root.mkdir(exist_ok=True)
    rate = 16000
    audio, info = decode(args.recording, rate)
    envs = envelopes(audio, rate)
    result = {'recording': str(args.recording), 'metadata': info, 'decoded_duration_seconds': len(audio) / rate,
              'peak_sample': float(np.max(np.abs(audio))), 'peaks': {}}
    arrays = {'audio': audio, 'rate': np.array(rate)}
    for role, env in envs.items():
        height = max(np.quantile(env, 0.999) * 0.08, np.median(env) * 8)
        peaks, props = signal.find_peaks(env, height=height, prominence=height / 2, distance=int(0.65 * rate))
        result['peaks'][role] = [{'time': round(float(i / rate), 5), 'amplitude': round(float(env[i]), 6)} for i in peaks]
        arrays[role] = env
    np.savez_compressed(root / 'decoded.npz', **arrays)
    (root / 'inspection.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()
