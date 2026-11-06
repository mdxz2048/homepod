import json
from pathlib import Path
import tempfile
import unittest
import wave

from analyze_events import analyze
from make_media_fixture import create, RATE, EVENTS


class FixtureTests(unittest.TestCase):
    def test_events_are_exact_samples_and_no_autoplay(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'fixture'
            result = create(target)
            self.assertFalse(result['video_created'])
            self.assertNotIn('autoplay', (target / 'index.html').read_text())
            self.assertEqual(json.loads((target / 'fixture.json').read_text())['fps'], 30)
            with wave.open(str(target / 'reference.wav')) as source:
                self.assertEqual(source.getnframes(), RATE * 11)
                for event in EVENTS:
                    source.setpos(event * RATE - 100)
                    self.assertEqual(source.readframes(100), b'\0\0' * 100)
                    self.assertNotEqual(source.readframes(100), b'\0\0' * 100)

    def test_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileExistsError):
                create(Path(directory))


class AnalysisTests(unittest.TestCase):
    def test_sign_and_summary(self):
        result = analyze([{'video_seconds': t, 'audio_seconds': t + .12} for t in EVENTS], 20)
        self.assertAlmostEqual(result['median_ms'], 120)
        self.assertEqual(result['status'], 'measurement_summary_not_acceptance')

    def test_mispair_or_missing_rejected(self):
        with self.assertRaises(ValueError):
            analyze([{'video_seconds': t, 'audio_seconds': a} for t, a in [(2, 2), (5, 8), (8, 11)]], 20)

    def test_insufficient_events_and_bad_time_rejected(self):
        for rows in [[], [{'video_seconds': t, 'audio_seconds': float('nan')} for t in EVENTS]]:
            with self.assertRaises(ValueError):
                analyze(rows, 20)

    def test_unknown_uncertainty_rejected(self):
        with self.assertRaises(ValueError):
            analyze([], 0)


if __name__ == '__main__':
    unittest.main()
