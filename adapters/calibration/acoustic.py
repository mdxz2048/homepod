"""Acoustic probes and measured residuals in the host monotonic clock domain.

Residual = microphone arrival - scheduled AirPlay presentation. The input
node's hardware sample timestamp is used, never callback receipt wall time.
Calibration covers the sender/receiver/room path; capture-host conversion and
video-player compliance still require an end-to-end lip-sync check.
"""
import asyncio
import math
import time

RATE = 44100
OFFSETS = (1.0, 2.7, 4.4)
VERSION = 1


def chirp(rate=RATE, code=None):
    import numpy as np
    duration = .09 if code is None else .14
    low, high = (900, 6200) if code is None else (650 + code * 800, 1300 + code * 800)
    t = np.arange(round(duration * rate)) / rate
    phase = 2 * np.pi * (low * t + (high - low) / (duration * 2) * t * t)
    return (.24 * np.sin(phase) * np.hanning(len(t))).astype('float32')


PROBE_SECONDS = 1.0
PROBE_REPEATS = 6
PROBE_GAP = .6
PROBE_PERIOD = PROBE_SECONDS + PROBE_GAP
CONTINUOUS_SECONDS = PROBE_REPEATS * PROBE_SECONDS + (PROBE_REPEATS - 1) * PROBE_GAP
CONTINUOUS_START = 1.0
CONTINUOUS_WINDOWS = tuple(index * PROBE_PERIOD for index in range(PROBE_REPEATS))
PROBE_PEAK = .5
MATCH_RADIUS_MS = 550
PROBE_KINDS = ('sweep', 'linear', 'pink')
KIND_ALIASES = {'sweep': 'sweep', 'log': 'sweep', 'log-sweep': 'sweep',
                'linear': 'linear', 'lin': 'linear', 'linear-sweep': 'linear',
                'pink': 'pink', 'white': 'pink', 'noise': 'pink'}
PROBE_ASSETS = {'sweep': 'log-sweep', 'linear': 'linear-sweep', 'pink': 'pink-noise'}


def normalize_kind(kind):
    try:
        return KIND_ALIASES[kind]
    except (KeyError, TypeError):
        return 'sweep'


def _asset_path(name, rate):
    from pathlib import Path
    if rate not in (44100, 48000):
        raise ValueError('unsupported probe asset rate')
    path = Path(__file__).resolve().parent / 'assets' / f'{name}-{rate}.wav'
    if not path.is_file():
        raise ValueError(f'missing bundled probe asset: {path.name}')
    return path


def _read_asset(name, rate):
    import numpy as np
    from scipy.io import wavfile
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', wavfile.WavFileWarning)
        measured_rate, samples = wavfile.read(_asset_path(name, rate))
    if measured_rate != rate:
        raise ValueError('probe asset sample rate does not match its filename')
    integer = samples.dtype.kind == 'i'
    samples = np.asarray(samples, dtype='float64')
    if samples.ndim > 1:
        samples = samples[:, 0]
    if integer:
        samples /= 32768.0
    return samples


def _taper(x, rate):
    """A short cosine edge keeps the external WAV from clicking."""
    import numpy as np
    x = np.asarray(x, dtype='float64').copy()
    n = max(1, round(.01 * rate))
    if len(x) < 2 * n:
        n = max(1, len(x) // 2)
    edge = .5 - .5 * np.cos(np.pi * np.arange(n) / n)
    x[:n] *= edge
    x[-n:] *= edge[::-1]
    return x


def _normalize_unit(x):
    import numpy as np
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    if peak <= 1e-9:
        raise ValueError('bundled probe asset is silent')
    return (x * (PROBE_PEAK / peak)).astype('float64')


def probe_units(rate=RATE, kind='sweep'):
    """Six one-second units loaded from bundled external files."""
    import numpy as np
    if rate not in (44100, 48000):
        raise ValueError('invalid probe asset rate')
    kind = normalize_kind(kind)
    source = _read_asset(PROBE_ASSETS[kind], rate)
    count = round(PROBE_SECONDS * rate)
    if kind == 'pink':
        if len(source) < count * PROBE_REPEATS:
            raise ValueError('pink-noise asset is too short')
        raw = [source[index * count:(index + 1) * count] for index in range(PROBE_REPEATS)]
    else:
        if len(source) < count:
            raise ValueError('sweep asset is too short')
        raw = [source[:count] for _ in range(PROBE_REPEATS)]
    return [_normalize_unit(_taper(unit, rate)) for unit in raw]


def probe_signal(rate=RATE, code=0, kind='sweep'):
    """The exact repeated waveform played through the Flow device."""
    import numpy as np
    if type(code) is not int or not 0 <= code <= 7:
        raise ValueError('invalid continuous probe code')
    units = probe_units(rate, kind)
    gap = np.zeros(round(rate * PROBE_GAP), dtype='float64')
    parts = []
    for index, unit in enumerate(units):
        parts.append(unit)
        if index != len(units) - 1:
            parts.append(gap)
    signal = np.concatenate(parts)
    expected = round(rate * CONTINUOUS_SECONDS)
    if len(signal) != expected:
        raise ValueError('probe duration mismatch')
    return signal.astype('float32')


def inverse_filter(rate=RATE):
    """The precomputed inverse that accompanies the downloaded log sweep."""
    return _read_asset('log-sweep-inverse', rate)


def continuous_signal(rate=RATE, code=0):
    """Compatibility alias; the current probe is the bundled log sweep."""
    return probe_signal(rate, code, 'sweep')


class ProbeRejected(ValueError):
    """Analysis rejection that carries the measurements behind the decision."""

    def __init__(self, message, metrics):
        super().__init__(message)
        self.metrics = metrics


def _analyze_continuous(audio, rate, first_ns, injection_ns, nominal_ms,
                        expected_latency_ms, code, frame_at_time, time_at_frame, kind='sweep',
                        probe_rate=None):
    import numpy as np
    from scipy.signal import butter, sosfiltfilt, correlate, fftconvolve, find_peaks, resample_poly
    kind = normalize_kind(kind)
    source_rate = probe_rate if probe_rate in (44100, 48000) else RATE
    import hashlib
    asset_digest = hashlib.sha256(_asset_path(PROBE_ASSETS[kind], source_rate).read_bytes()).hexdigest()
    metrics = {'sample_rate': rate, 'code': code, 'band_hz': [300, 6000], 'probe_kind': kind,
               'probe_rate': probe_rate, 'probe_asset': PROBE_ASSETS[kind],
               'probe_sha256': asset_digest, 'repeats': PROBE_REPEATS,
               'unit_seconds': PROBE_SECONDS}
    if injection_ns is None or code is None:
        raise ValueError('连续测量缺少测试信号或注入时钟。')
    def reject(message):
        raise ProbeRejected(message, metrics)

    if type(rate) not in (int, float) or rate not in (44100, 48000, 96000):
        reject('录音采样率不受支持。')
    raw = np.asarray(audio, dtype='float64')
    raw_rms = float(np.sqrt(np.mean(raw * raw))) if len(raw) else 0.0
    metrics['recording'] = {'seconds': len(raw) / rate, 'rms': raw_rms,
                            'peak': float(np.max(np.abs(raw))) if len(raw) else 0.0}
    band = butter(4, (300, 6000), btype='bandpass', fs=rate, output='sos')
    audio = sosfiltfilt(band, raw)
    units = probe_units(source_rate, kind)
    if source_rate != rate:
        units = [resample_poly(unit, rate, source_rate)[:round(PROBE_SECONDS * rate)]
                 for unit in units]
    units = [sosfiltfilt(butter(4, (300, 6000), btype='bandpass', fs=rate, output='sos'), unit)
             for unit in units]
    inverse = inverse_filter(source_rate) if kind == 'sweep' else None
    if inverse is not None:
        if source_rate != rate:
            inverse = resample_poly(inverse, rate, source_rate)[:round(PROBE_SECONDS * rate)]
        inverse = sosfiltfilt(butter(4, (300, 6000), btype='bandpass', fs=rate, output='sos'), inverse)
    metrics['band'] = {'recording_rms': float(np.sqrt(np.mean(audio * audio))) if len(audio) else 0.0,
                       'unit_rms': float(np.sqrt(np.mean(units[0] * units[0]))) if units else 0.0}
    target = nominal_ms if expected_latency_ms is None else expected_latency_ms

    def correlation(start, template):
        template = np.asarray(template, dtype='float64')
        segment = audio[start:start + len(template)]
        if start < 0 or len(segment) != len(template):
            return -1.0
        segment = segment - segment.mean(); centred = template - template.mean()
        denominator = np.sqrt(np.dot(segment, segment) * np.dot(centred, centred))
        return float(abs(np.dot(segment, centred)) / max(denominator, 1e-20))

    def measure(index, speed):
        unit = units[index]
        length = max(8, round(len(unit) * speed))
        template = resample_poly(unit, length, len(unit))
        expected_start = injection_ns + (CONTINUOUS_START * speed + index * PROBE_PERIOD * speed + target / 1000) * 1e9
        lo = round(frame_at_time(expected_start - MATCH_RADIUS_MS * 1e6))
        hi = round(frame_at_time(expected_start + (PROBE_SECONDS * speed + MATCH_RADIUS_MS / 1000) * 1e9))
        if lo < 0 or hi <= lo or hi > len(audio):
            return None
        window = audio[lo:hi]
        if kind == 'sweep':
            filt = resample_poly(inverse, length, len(inverse))
            output = fftconvolve(window, filt, mode='full')
            peaks, _ = find_peaks(np.abs(output), distance=max(1, round(.002 * rate)))
            if not len(peaks):
                return None
            def peak_residual(pos):
                arrival = lo + pos - (length - 1)
                return (time_at_frame(arrival) - expected_start) / 1e6
            usable = [pos for pos in peaks if abs(peak_residual(pos)) <= MATCH_RADIUS_MS]
            if not usable:
                return None
            ordered = sorted(usable, key=lambda pos: abs(output[pos]), reverse=True)
            strongest = ordered[0]
            # A room reflection can be nearly as large as the direct path.
            # Take the earliest strong peak as direct instead of rejecting the
            # whole unit merely because a later reflection is loud.
            strong = [pos for pos in ordered if abs(output[pos]) >= .85 * abs(output[strongest])]
            peak = min(strong)
            arrival = lo + peak - (length - 1)
            score = correlation(arrival, template)
            second = abs(output[ordered[1]]) / max(abs(output[ordered[0]]), 1e-20) if len(ordered) > 1 else 0.0
            direct_ratio = abs(output[peak]) / max(abs(output[strongest]), 1e-20)
            background = float(np.median(np.abs(output))) + 1e-20
            psr = float(abs(output[peak]) / background)
        else:
            corr = correlate(window, template, mode='valid', method='fft')
            squares = np.concatenate(([0.], np.cumsum(window * window)))
            energy = float(np.dot(template, template))
            moving = np.maximum(squares[len(template):] - squares[:-len(template)], 0)
            normalized = np.abs(corr) / np.sqrt(np.maximum(moving * energy, 1e-20))
            peaks, _ = find_peaks(normalized, distance=max(1, round(.002 * rate)))
            if not len(peaks):
                return None
            def peak_residual(pos):
                return (time_at_frame(lo + pos) - expected_start) / 1e6
            usable = [pos for pos in peaks if abs(peak_residual(pos)) <= MATCH_RADIUS_MS]
            if not usable:
                return None
            ordered = sorted(usable, key=lambda pos: normalized[pos], reverse=True)
            strongest = ordered[0]
            strong = [pos for pos in ordered if normalized[pos] >= .85 * normalized[strongest]]
            peak = min(strong)
            arrival = lo + peak
            score = float(normalized[peak])
            second = float(normalized[ordered[1]] / max(normalized[ordered[0]], 1e-20)) if len(ordered) > 1 else 0.0
            direct_ratio = float(normalized[peak] / max(normalized[strongest], 1e-20))
            psr = float(normalized[peak] / max(float(np.median(normalized)), 1e-12))
        residual = (time_at_frame(arrival) - expected_start) / 1e6
        metrics.setdefault('matches', []).append({
            'index': index, 'samples': length, 'best': score, 'second_ratio': second,
            'psr': psr, 'direct_ratio': direct_ratio, 'residual_ms': float(residual),
            'speed': float(speed)})
        if abs(residual) > MATCH_RADIUS_MS + 2 or score < limits['score'] or psr < limits['psr']:
            return None
        return residual, score, second, psr

    def evaluate(speed):
        found = []
        for index in range(PROBE_REPEATS):
            result = measure(index, speed)
            if result is not None:
                found.append((index, *result))
        if len(found) < limits['units']:
            return None
        values = [item[1] for item in found]
        spread = max(values) - min(values)
        line = np.polyfit([item[0] * PROBE_PERIOD for item in found], values, 1)
        drift = float(line[0])
        confidence = min(item[2] for item in found)
        utility = len(found) * 20 - spread - abs(drift) * 4 + confidence * 5
        return {'speed': speed, 'found': found, 'spread': spread, 'drift': drift,
                'confidence': confidence, 'utility': utility}

    limits = {'score': .15, 'psr': 3.0, 'units': 4}

    def run_search():
        best = None
        for speed in (1.0, .995, .9975, 1.0025, 1.005, .99, 1.01,
                      44100 / 48000, 48000 / 44100, .96, 1.04):
            candidate = evaluate(speed)
            if candidate is not None and (best is None or candidate['utility'] > best['utility']):
                best = candidate
        if best is None:
            return None
        anchor = best['speed']
        for step in (-.004, -.003, -.002, -.0015, -.001, -.0007, -.0004,
                     .0004, .0007, .001, .0015, .002, .003, .004):
            candidate = evaluate(anchor * (1 + step))
            if candidate is not None and candidate['utility'] > best['utility']:
                best = candidate
        return best

    def summarize(best):
        found = sorted(best['found'])
        times = [item[0] * PROBE_PERIOD for item in found]
        residuals = [item[1] for item in found]
        spread = max(residuals) - min(residuals)
        line = np.polyfit(times, residuals, 1)
        return found, residuals, float(spread), float(line[0]), line

    def publish(best, found, residuals, spread, drift):
        metrics['speed'] = float(best['speed'])
        metrics['residuals_ms'] = [float(value) for value in residuals]
        metrics['spread_ms'] = float(spread)
        metrics['drift_ms_per_second'] = float(drift)
        metrics['valid_units'] = len(found)

    best = run_search()
    had_candidate = best is not None
    found = residuals = line = None
    spread = drift = None
    if best is not None:
        found, residuals, spread, drift, line = summarize(best)
        publish(best, found, residuals, spread, drift)
    if best is None or spread > 12 or abs(drift) > 1.5:
        # A strong reflection or a distant microphone can leave the direct
        # path below the waveform-correlation floor even though the inverse
        # filter still gives sharp peaks. Retry with PSR-based acceptance and
        # stricter drift/spread, so the normal path stays unchanged.
        if best is not None:
            metrics['strict_result'] = {
                'speed': float(best['speed']), 'spread_ms': float(spread),
                'drift_ms_per_second': float(drift), 'valid_units': len(found)}
        metrics.pop('matches', None)
        limits.update(score=.05, psr=20.0, units=5)
        weak = run_search()
        weak_ok = False
        if weak is not None:
            wfound, wres, wspread, wdrift, wline = summarize(weak)
            publish(weak, wfound, wres, wspread, wdrift)
            if (len(wfound) >= 5 and wspread <= 10 and abs(wdrift) <= 1.0
                    and weak['confidence'] >= .05):
                best = weak
                found, residuals, spread, drift, line = wfound, wres, wspread, wdrift, wline
                weak_ok = True
                metrics['fallback'] = 'weak-signal'
        if not weak_ok:
            if had_candidate or weak is not None:
                reject('整段测试的延迟波动或漂移过大，请检查网络并重新测试。')
            reject('六段外部测试音都未能定位，请检查麦克风、音量和环境噪声。')
    publish(best, found, residuals, spread, drift)
    start_delay = float(line[1])
    residual = start_delay + target - nominal_ms
    return {'version': 4, 'residual_ms': residual, 'measured_ms': nominal_ms + residual,
            'nominal_ms': nominal_ms, 'spread_ms': spread, 'confidence': best['confidence'],
            'sample_count': len(found), 'matched_duration_seconds': CONTINUOUS_SECONDS,
            'drift_ms_per_second': drift, 'window_residuals_ms': [float(x) for x in residuals],
            'speed': float(best['speed']), 'probe_asset': PROBE_ASSETS[kind],
            'probe_sha256': asset_digest}


class ProbeCapture:
    """Paced synthetic input through the same live hub and transport as cinema."""
    def __init__(self, hub, report):
        self.hub, self.state = hub, report
        self.stopping = False
        self.task = None

    async def start(self):
        self.task = asyncio.create_task(self._produce())
        await asyncio.wait_for(self.hub.first_block.wait(), 3)

    async def _produce(self):
        import numpy as np
        signal = np.zeros(RATE * 7, dtype='float32')
        tone = chirp()
        for offset in OFFSETS:
            at = round(offset * RATE)
            signal[at:at + len(tone)] = tone
        origin = time.monotonic_ns()
        frame = 0
        try:
            while True:
                remaining = origin / 1e9 + frame / RATE - time.monotonic()
                if remaining > 0:
                    await asyncio.sleep(remaining)
                mono = signal[frame:frame + 352]
                if len(mono) < 352:
                    mono = np.pad(mono, (0, 352 - len(mono)))
                await self.hub.push(np.repeat(mono, 2).tolist(),
                                    receipt_ns=origin + frame * 1_000_000_000 // RATE)
                frame += 352
        except asyncio.CancelledError:
            raise
        except Exception as error:
            await self.hub.fail(error)

    async def stop(self):
        self.stopping = True
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
        return True

    def report(self):
        return {'input_closed': self.stopping, 'probe_version': VERSION,
                'probe_offsets_seconds': list(OFFSETS)}


def analyze_recording(path, rate, first_sample_ns, presentation_ns, nominal_ms,
                      injection_ns=None, code=None, expected_latency_ms=None, clock_path=None,
                      signal_version=1, diagnostics_path=None, probe_kind='white', probe_rate=None):
    import numpy as np
    from scipy.signal import correlate, find_peaks
    if (type(rate) not in (int, float) or rate not in (44100, 48000, 96000)
            or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0
                   for v in (first_sample_ns, presentation_ns, nominal_ms))):
        raise ValueError('无效的录音时钟或采样率，请重新测试。')
    from pathlib import Path
    size = Path(path).stat().st_size
    if not 0 < size <= rate * 90 * 4 or size % 4:
        raise ValueError('录音长度无效。')
    audio = np.fromfile(path, dtype='<f4')
    if not np.isfinite(audio).all() or np.mean(np.abs(audio) >= .99) > .005:
        raise ValueError('麦克风录音过载，请调低测试音量后重试。')
    if code is not None and (type(code) is not int or not 0 <= code <= 7):
        raise ValueError('无效的测试码')
    if injection_ns is not None and (not math.isfinite(injection_ns) or injection_ns <= 0):
        raise ValueError('无效的测试注入时钟')
    clock = None
    if clock_path is not None:
        import json
        if Path(clock_path).stat().st_size > 1_000_000:
            raise ValueError('录音时钟记录过长')
        records = json.loads(Path(clock_path).read_text())
        if not isinstance(records, list) or not records or len(records) > 20000:
            raise ValueError('录音时钟不完整')
        clock = np.array([[r['frame'], r['ns']] for r in records], dtype='float64')
        steps = np.diff(clock[:, 1]) - np.diff(clock[:, 0]) / rate * 1e9
        # Continuity only matters where the probe actually is. Continuity
        # microphones often resync their clock in the first second of capture;
        # that transient precedes the injected signal and must not reject it.
        step_ns = (clock[:-1, 1] + clock[1:, 1]) / 2
        window = np.ones(len(steps), dtype=bool)
        if injection_ns is not None:
            window = (step_ns >= injection_ns - .25e9) & (step_ns <= injection_ns + 12e9)
        if (not np.isfinite(clock).all() or clock[0, 0] != 0
                or np.any(np.diff(clock[:, 0]) <= 0) or np.any(np.diff(clock[:, 1]) <= 0)
                or (signal_version in (3, 4) and window.any()
                    and np.max(np.abs(steps[window] - np.median(steps[window]))) > 3e6)
                or clock[-1, 0] >= len(audio)):
            raise ValueError('录音硬件时钟不连续，请重新测试。')
    def frame_at_time(ns):
        if clock is None:
            return (ns - first_sample_ns) / 1e9 * rate
        block = max(0, int(np.searchsorted(clock[:, 1], ns, side='right')) - 1)
        return clock[block, 0] + (ns - clock[block, 1]) / 1e9 * rate

    def time_at_frame(frame):
        if clock is None:
            return first_sample_ns + frame / rate * 1e9
        block = max(0, int(np.searchsorted(clock[:, 0], frame, side='right')) - 1)
        return clock[block, 1] + (frame - clock[block, 0]) / rate * 1e9

    if signal_version in (3, 4):
        try:
            return _analyze_continuous(audio, rate, first_sample_ns, injection_ns, nominal_ms,
                                       expected_latency_ms, code, frame_at_time, time_at_frame,
                                       probe_kind, probe_rate)
        except ProbeRejected as error:
            if diagnostics_path:
                import json
                from pathlib import Path as _Path
                try:
                    _Path(diagnostics_path).write_text(json.dumps(
                        {'error': str(error), 'metrics': error.metrics}, ensure_ascii=False, indent=2))
                except OSError:
                    pass
            raise
    if signal_version != 1:
        raise ValueError('unsupported acoustic signal version')
    template = chirp(rate, code).astype('float64')
    template -= template.mean()
    energy = np.dot(template, template)
    residuals, scores = [], []
    for offset in OFFSETS:
        expected = (presentation_ns - first_sample_ns) / 1e9 + offset
        if injection_ns is not None:
            expected = (injection_ns - first_sample_ns) / 1e9 + offset + (expected_latency_ms if expected_latency_ms is not None else nominal_ms) / 1000
        expected_ns = first_sample_ns + expected * 1e9
        lo = round(frame_at_time(expected_ns - .25e9))
        hi = round(frame_at_time(expected_ns + .75e9))
        if lo < 0 or hi + len(template) > len(audio):
            raise ValueError('录音未完整覆盖测试音，请重新测试。')
        window = audio[lo:hi + len(template)].astype('float64')
        corr = correlate(window, template, mode='valid', method='fft')
        squares = np.concatenate(([0.], np.cumsum(window * window)))
        means = np.concatenate(([0.], np.cumsum(window)))
        n = len(template)
        power = np.maximum(0, squares[n:] - squares[:-n] - (means[n:] - means[:-n]) ** 2 / n)
        score = np.abs(corr) / np.sqrt(np.maximum(power * energy, 1e-20))
        peaks, _ = find_peaks(score, distance=round(.015 * rate))
        if not len(peaks):
            raise ValueError('没有听到测试音，请检查麦克风和音箱。')
        ordered = sorted(peaks, key=lambda p: score[p], reverse=True)
        peak = ordered[0]
        if score[peak] < .20 or (len(ordered) > 1 and score[ordered[1]] > score[peak] * .85):
            raise ValueError('测试音不够清晰或回声过强，请保持安静并重试。')
        arrival_ns = time_at_frame(lo + peak)
        waveform_end_ns = time_at_frame(lo + peak + len(template) - 1)
        waveform_ns = (len(template) - 1) / rate * 1e9
        if abs(waveform_end_ns - arrival_ns - waveform_ns) > 2e6:
            raise ValueError('测试音期间录音中断，请重新测试。')
        residuals.append((arrival_ns - expected_ns) / 1e6)
        scores.append(float(score[peak]))
    spread = max(residuals) - min(residuals)
    if spread > 12:
        raise ValueError('三次测量的波动超过 12 ms，请检查网络并重试。')
    residual = float(np.median(residuals))
    if injection_ns is not None and expected_latency_ms is not None:
        residual += expected_latency_ms - nominal_ms
    return {'version': VERSION, 'residual_ms': residual,
            'measured_ms': nominal_ms + residual, 'nominal_ms': nominal_ms,
            'spread_ms': spread, 'confidence': min(scores), 'sample_count': len(residuals)}


def compensation_plan(residuals):
    if (not residuals or any(type(v) not in (int, float) or not math.isfinite(v)
                            or not -250 <= v <= 750 for v in residuals.values())):
        raise ValueError('invalid acoustic residuals')
    common = max(0., max(residuals.values()))
    return common, {key: round((common - value) * RATE / 1000)
                    for key, value in residuals.items()}
