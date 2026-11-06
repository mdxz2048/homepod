"""Analyze manually verified A/V onset timestamps from ONE recording clock.

CSV columns: video_seconds,audio_seconds. Positive offset means sound is late.
No recording access, audio playback, or external processes. This does not extract
events: provide onset timestamps verified against original recorded frames/audio.
"""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics


def analyze(rows, uncertainty_ms, expected_spacing_s=3., spacing_tolerance_s=.25):
    if not math.isfinite(uncertainty_ms) or uncertainty_ms <= 0:
        raise ValueError('Provide a positive uncertainty including frame, onset, and distance errors')
    if len(rows) < 3:
        raise ValueError('At least three independently matched events required')
    pairs = [(float(row['video_seconds']), float(row['audio_seconds'])) for row in rows]
    if any(not math.isfinite(v) or v < 0 for pair in pairs for v in pair):
        raise ValueError('Event timestamps must be finite and nonnegative')
    for before, after in zip(pairs, pairs[1:]):
        for channel in (0, 1):
            spacing = after[channel] - before[channel]
            if abs(spacing - expected_spacing_s) > spacing_tolerance_s:
                raise ValueError('Missing/mispaired events or wrong fixture spacing; inspect raw recording')
    offsets = [(audio - video) * 1000 for video, audio in pairs]
    return {'status': 'measurement_summary_not_acceptance', 'events': len(pairs),
            'sign': 'positive_audio_late', 'offsets_ms': offsets,
            'median_ms': statistics.median(offsets),
            'min_ms': min(offsets), 'max_ms': max(offsets),
            'span_ms': max(offsets) - min(offsets),
            'declared_uncertainty_ms': uncertainty_ms,
            'warning': 'No automatic browser adoption verdict; common-clock provenance and calibration required'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    parser.add_argument('--uncertainty-ms', required=True, type=float)
    args = parser.parse_args()
    with args.csv.open(newline='', encoding='utf-8-sig') as handle:
        print(json.dumps(analyze(list(csv.DictReader(handle)), args.uncertainty_ms), indent=2))
