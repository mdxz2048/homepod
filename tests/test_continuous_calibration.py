"""External-probe DSP checks with known room/path delays; never plays audio."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
from scipy.signal import butter, resample_poly, sosfiltfilt
from adapters.calibration.acoustic import (CONTINUOUS_SECONDS, PROBE_PERIOD, PROBE_REPEATS,
    analyze_recording, probe_signal, probe_units)


class ContinuousChecks(unittest.TestCase):
    def recording(self, rate=48000, kind='sweep', delay_ms=314, noise=.0003, speed=1.0):
        source_rate = rate if rate in (44100, 48000) else 48000
        audio = np.random.default_rng(42).normal(0, noise, round(rate * 17)).astype('float32')
        tone = probe_signal(source_rate, 0, kind)
        if speed != 1.0:
            tone = resample_poly(tone, round(len(tone) * speed), len(tone))
        if source_rate != rate:
            tone = resample_poly(tone, rate, source_rate)
        # injection is one second after the first captured frame; AirPlay is
        # nominally two seconds. The sample at 1.0 in the render buffer arrives
        # at 1.0*speed when the render path runs fast or slow.
        start = round((3 + speed + delay_ms / 1000) * rate)
        audio[start:start + len(tone)] += .3 * tone.astype('float32')
        return audio

    def analyze(self, audio, rate=48000, kind='sweep', clock=None, probe_rate=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'probe.f32'; audio.astype('<f4').tofile(path)
            clock_path = None
            if clock is not None:
                clock_path = Path(directory) / 'clock.json'; clock_path.write_text(json.dumps(clock))
            return analyze_recording(path, rate, 10e9, 11e9, 2000,
                injection_ns=11e9, code=0, expected_latency_ms=2000,
                clock_path=clock_path, signal_version=4, probe_kind=kind,
                probe_rate=probe_rate or rate)

    def test_bundled_assets_are_external_and_have_the_expected_shape(self):
        directory = Path(__file__).parents[1] / 'adapters/calibration/assets'
        expected = {
            'log-sweep-44100.wav': '0c8f8e9508b98c8ebea59812a801363d67ea34464a084088a5512a4b6e26086e',
            'log-sweep-48000.wav': '83d0e2d9a2dba5879c37b937504b1646911771d9ccb1dfe08904872ae8fad736',
            'linear-sweep-44100.wav': '4a7d79855613155d053b0a2ce6d30a834f3b61cad2ce60350667fcf6e8eb0804',
            'linear-sweep-48000.wav': '1323fb32a0472919bada616832c53c0c1c512924ad9382a9ac0f0b631851cb6b',
            'log-sweep-inverse-44100.wav': '835bf4304feeafd09ea12cd7ca37f5e3db936ae29707aa96c20533e6d32138fe',
            'log-sweep-inverse-48000.wav': '84983cf4b5a72f093f0c09b145bb8d4c7421031a4dc0f79937aa73811ec938c4',
            'pink-noise-44100.wav': 'c53984c74fb6afc4fb99e14d5a6f9a5a104b2524f7a94bd4ceae206029aabafc',
            'pink-noise-48000.wav': '400d677f608fde77a1a0bd307bfb1aafb15a7dc50e5293bd47f17bbdcffdd7a1',
        }
        for name, digest in expected.items():
            self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), digest)
        for rate in (44100, 48000):
            for kind in ('sweep', 'linear', 'pink'):
                units = probe_units(rate, kind)
                self.assertEqual(len(units), PROBE_REPEATS)
                self.assertTrue(all(len(unit) == rate for unit in units))
                self.assertAlmostEqual(max(abs(unit).max() for unit in units), .5, places=6)
                self.assertEqual(len(probe_signal(rate, 0, kind)), round(rate * CONTINUOUS_SECONDS))

    def test_all_three_external_probes_recover_known_delay_at_three_rates(self):
        for rate in (44100, 48000, 96000):
            probe_rate = rate if rate in (44100, 48000) else 48000
            for kind in ('sweep', 'linear', 'pink'):
                result = self.analyze(self.recording(rate, kind, 37.25), rate, kind, probe_rate=probe_rate)
                self.assertAlmostEqual(result['residual_ms'], 37.25, delta=.18)
                self.assertEqual(result['matched_duration_seconds'], 9)
                self.assertEqual(result['sample_count'], 6)
                self.assertEqual(result['version'], 4)
                self.assertLess(result['spread_ms'], .2)

    def test_actual_capture_and_airplay_resampling(self):
        rate = 48000
        tone = probe_signal(rate, 0, 'sweep')
        tone = resample_poly(resample_poly(tone, 147, 160), 160, 147)
        audio = np.zeros(rate * 18, dtype='float32')
        start = round(4.314 * rate); audio[start:start + len(tone)] += .3 * tone
        result = self.analyze(audio)
        self.assertAlmostEqual(result['residual_ms'], 314, delta=.3)

    def test_different_output_and_microphone_rates(self):
        for source_rate, input_rate in ((44100, 48000), (48000, 96000), (48000, 44100)):
            result = self.analyze(self.recording(input_rate, 'sweep', 313.5), input_rate,
                                  probe_rate=source_rate)
            self.assertAlmostEqual(result['residual_ms'], 313.5, delta=.35)

    def test_small_speed_offset_is_estimated_instead_of_becoming_latency(self):
        for kind in ('sweep', 'linear', 'pink'):
            with self.subTest(kind=kind):
                result = self.analyze(self.recording(48000, kind, 314, speed=.997), 48000, kind)
                self.assertAlmostEqual(result['residual_ms'], 314, delta=.5)
                self.assertAlmostEqual(result['speed'], .997, delta=.002)

    def test_homepod_rolloff_noise_and_reflection_keep_a_usable_result(self):
        audio = self.recording(48000, 'sweep', 312.5, noise=.0012)
        audio = sosfiltfilt(butter(3, 2200, fs=48000, output='sos'), audio).astype('float32')
        result = self.analyze(audio.astype('float32'))
        self.assertAlmostEqual(result['residual_ms'], 312.5, delta=.4)
        self.assertGreater(result['confidence'], .45)

    def test_one_dropped_unit_is_tolerated_but_not_a_broken_capture(self):
        audio = self.recording(48000, 'sweep', 314, noise=.0005)
        start = round((4 + 314 / 1000) * 48000 + 2 * PROBE_PERIOD * 48000)
        audio[start:start + 48000] = 0
        result = self.analyze(audio)
        self.assertEqual(result['sample_count'], 5)
        self.assertAlmostEqual(result['residual_ms'], 314, delta=.2)

    def test_later_strong_reflection_uses_the_earlier_direct_arrival(self):
        direct = self.recording(48000, 'sweep', 314, noise=0)
        reflection = self.recording(48000, 'sweep', 316, noise=0) * .95
        result = self.analyze((direct + reflection).astype('float32'))
        self.assertAlmostEqual(result['residual_ms'], 314, delta=.4)
        self.assertLess(result['spread_ms'], 1.0)

    def test_silence_noise_clipping_and_truncated_passage_are_rejected(self):
        for audio in (np.zeros(816000), np.random.default_rng(3).normal(0, .1, 816000),
                      np.ones(816000), self.recording()[:480000]):
            with self.assertRaises(ValueError): self.analyze(audio)

    def test_hardware_clock_interruption_is_rejected(self):
        rate = 48000; audio = self.recording()
        clock = [{'frame': frame, 'ns': 10e9 + frame / rate * 1e9 + (8e6 if frame >= 6 * rate else 0)}
                 for frame in range(0, len(audio), 1024)]
        with self.assertRaises(ValueError): self.analyze(audio, clock=clock)


if __name__ == '__main__': unittest.main()
