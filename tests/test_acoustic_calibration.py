"""Silent fixtures: known acoustic arrivals, real DSP, and live delay routing."""
import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import numpy as np
from adapters.calibration.acoustic import OFFSETS, analyze_recording, chirp, compensation_plan
from adapters.system_worker import parse_system_request
from adapters.worker.protocol import ProtocolError


class AcousticChecks(unittest.TestCase):
    def recording(self, rate=48000, delays=(.037, .039, .038), gain=.07, noise=.0003):
        audio = np.random.default_rng(111).normal(0, noise, rate * 10).astype('<f4')
        probe = chirp(rate)
        for offset, delay in zip(OFFSETS, delays):
            at = round((2 + offset + delay) * rate)
            audio[at:at + len(probe)] += gain * probe
        return audio

    def analyze(self, audio, rate=48000):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'probe.f32'
            audio.astype('<f4').tofile(path)
            return analyze_recording(path, rate, 10e9, 12e9, 2000)

    def test_soft_probe_recovers_known_delay_at_three_rates(self):
        for rate in (44100, 48000, 96000):
            result = self.analyze(self.recording(rate), rate)
            self.assertAlmostEqual(result['residual_ms'], 38, delta=.1)
            self.assertAlmostEqual(result['measured_ms'], 2038, delta=.1)
            self.assertLess(result['spread_ms'], 2.1)

    def test_silence_and_noise_never_save_a_latency(self):
        for audio in (np.zeros(480000), np.random.default_rng(11).normal(0, .01, 480000)):
            with self.assertRaises(ValueError):
                self.analyze(audio)

    def test_unstable_network_is_rejected(self):
        with self.assertRaisesRegex(ValueError, '波动'):
            self.analyze(self.recording(delays=(.01, .05, .09)))

    def test_equal_reflections_are_rejected(self):
        audio = self.recording(noise=0)
        reflected = self.recording(delays=(.077, .079, .078), noise=0)
        with self.assertRaisesRegex(ValueError, '回声'):
            self.analyze(audio + reflected)

    def test_clipping_and_partial_recording_are_rejected(self):
        for audio in (np.ones(480000), self.recording()[:48000]):
            with self.assertRaises(ValueError): self.analyze(audio)

    def test_compensation_equalizes_every_endpoint(self):
        for residuals in ({0: 10, 1: 41, 2: -12}, {0: -20, 1: -1}, {0: 0}):
            common, frames = compensation_plan(residuals)
            for key, residual in residuals.items():
                self.assertAlmostEqual(residual + frames[key] / 44.1, common, delta=1 / 44.1)
        for bad in ({0: float('nan')}, {0: 751}, {0: -251}, {}):
            with self.assertRaises(ValueError): compensation_plan(bad)

    def test_protocol_rejects_partial_calibration_and_probe_virtual_capture(self):
        p = {'session': 'ab12cd34-ab12-4d34-ab12-ab12cd34ef56', 'library': '/core',
             'capture_host': '/capture', 'routes': [{'output_id': 0, 'channels': [0, 1], 'host': 'a'}],
             'input': {'backend': 'virtual_device_v2', 'layout': '7_1',
                       'device_uid': 'com.homepodflow.virtual-audio.surround71.v1'}}
        def parse(params):
            return parse_system_request((json.dumps({'v': 1, 'id': 'x', 'command': 'start', 'params': params}) + '\n').encode())
        for value in ({}, {'1': 20}, {'0': float('nan')}, {'0': 9999}):
            with self.assertRaises(ProtocolError): parse(dict(p, calibration=value))
        self.assertEqual(parse(dict(p, calibration={'0': 25}))['params']['calibration'], {'0': 25})
        with self.assertRaises(ProtocolError): parse(dict(p, probe=True))
        for volume in (1, 10, 37, 100):
            self.assertEqual(parse(dict(p, probe=True, volume=volume))['params']['volume'], volume)
        for volume in (0, 101, 37.5):
            with self.assertRaises(ProtocolError): parse(dict(p, probe=True, volume=volume))


class CalibrationPreflightChecks(unittest.IsolatedAsyncioTestCase):
    async def test_pending_driver_stops_before_recording_or_playback(self):
        from types import SimpleNamespace
        from adapters.system_worker import SystemWorkerServer
        events = []
        server = SystemWorkerServer(events.append)
        command = (json.dumps({'v': 1, 'id': 'snapshot', 'command': 'calibration_snapshot',
                   'params': {'helper': '/hflctl'}}) + '\n').encode()
        with patch('adapters.live.latency_apply._status', AsyncMock(return_value=
                   SimpleNamespace(pending_status='pending', ms=2000, revision=2))):
            await server.handle_line(command)
        self.assertEqual(events[-1]['event'], 'error')
        self.assertEqual(events[-1]['payload']['code'], 'latency_pending')
        self.assertIn('重新启动', events[-1]['payload']['message'])


class DiscoveryWarmupChecks(unittest.IsolatedAsyncioTestCase):
    async def test_cold_discovery_retries_until_saved_identity_appears(self):
        from types import SimpleNamespace
        from adapters.system_worker import scan_receivers
        receiver = SimpleNamespace(identifier='speaker-a', name='A', address='192.0.2.1',
                                   device_info=SimpleNamespace(model='HomePod'))
        scan = AsyncMock(side_effect=[[], [], [receiver]])
        with patch('adapters.airplay_pyatv.session.scan', scan), \
             patch('adapters.system_worker.asyncio.sleep', AsyncMock()):
            result = await scan_receivers({'hosts': ['192.0.2.1'], 'expected_identifiers': ['speaker-a']})
        self.assertEqual(result['devices'][0]['identifier'], 'speaker-a')
        self.assertEqual(scan.await_count, 3)
        self.assertEqual(scan.await_args_list[0].args, (['192.0.2.1'], 4))
        self.assertEqual(scan.await_args_list[1].args, (None, 4))

    async def test_unavailable_speaker_has_bounded_attempts(self):
        from adapters.system_worker import scan_receivers
        scan = AsyncMock(return_value=[])
        with patch('adapters.airplay_pyatv.session.scan', scan), \
             patch('adapters.system_worker.asyncio.sleep', AsyncMock()):
            self.assertEqual(await scan_receivers({'expected_identifiers': ['missing']}), {'devices': []})
        self.assertEqual(scan.await_count, 4)

    async def test_discovery_cancellation_never_starts_another_scan(self):
        from adapters.system_worker import scan_receivers
        scan = AsyncMock(side_effect=asyncio.CancelledError())
        with patch('adapters.airplay_pyatv.session.scan', scan):
            with self.assertRaises(asyncio.CancelledError):
                await scan_receivers({'expected_identifiers': ['speaker-a']})
        self.assertEqual(scan.await_count, 1)


class DelayChecks(unittest.IsolatedAsyncioTestCase):
    async def test_pcm_delay_survives_packet_boundaries_without_dropping_frames(self):
        from adapters.live.session import LiveSource
        first = b''.join(n.to_bytes(4, 'big') for n in range(1, 10))
        hub = type('Hub', (), {'read': AsyncMock(side_effect=[first[:16], first[16:32], first[32:]])})()
        source = LiveSource(hub, 0)
        source.delay_buffer = bytearray(3 * 4)
        result = b''.join([await source.readframes(4), await source.readframes(4), await source.readframes(1)])
        self.assertEqual(result, bytes(12) + first[:24])
        self.assertEqual(bytes(source.delay_buffer), first[24:])
        self.assertEqual(source.frames_read, 9)



class FullPathProbeChecks(unittest.TestCase):
    def test_injected_virtual_input_is_measured_with_known_capture_delay(self):
        rate = 48000
        audio = np.random.default_rng(9).normal(0, .0001, rate * 12).astype('<f4')
        for code, delay in enumerate((2.019, 2.044, 2.032, 2.026)):
            tone = chirp(rate, code)
            for offset in OFFSETS:
                start = round((1 + delay + offset) * rate)
                audio[start:start + len(tone)] += tone * .05
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'full.f32'; audio.tofile(path)
            for code, expected in enumerate((19, 44, 32, 26)):
                result = analyze_recording(path, rate, 10e9, 11e9, 2000,
                    injection_ns=11e9, code=code, expected_latency_ms=2000)
                self.assertAlmostEqual(result['residual_ms'], expected, delta=.2)

    def test_compensated_group_verifies_absolute_and_relative_arrivals(self):
        rate = 48000
        audio = np.random.default_rng(4).normal(0, .0001, rate * 12).astype('<f4')
        for code, delay in enumerate((2.043, 2.044, 2.045, 2.044)):
            for offset in OFFSETS:
                tone = chirp(rate, code)
                start = round((1 + delay + offset) * rate)
                audio[start:start + len(tone)] += tone * .05
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'verified.f32'; audio.tofile(path)
            measured = [analyze_recording(path, rate, 10e9, 11e9, 2000,
                injection_ns=11e9, code=code, expected_latency_ms=2044)['measured_ms'] for code in range(4)]
            self.assertLess(max(measured) - min(measured), 2.2)
            self.assertTrue(all(abs(value - 2044) < 1.2 for value in measured))

class CalibratedSessionChecks(unittest.IsolatedAsyncioTestCase):
    async def test_saved_offsets_write_common_hal_target_and_delay_each_pcm_output(self):
        from types import SimpleNamespace
        import test_latency_apply as fixtures
        from adapters.live.session import LivePatches
        import adapters.live.session as session_module
        import adapters.live.latency_apply as latency_module
        hub = fixtures.FakeLatencyHub(); hub.routes = {0: [0, 1], 1: [0, 1]}
        capture = fixtures.FakeLatencyCapture()
        group = LivePatches(hub, capture, {}, latency_control='/hflctl', calibration={0: 10, 1: 40})
        clients = [SimpleNamespace(context=SimpleNamespace(sample_rate=44100, channels=2,
            bytes_per_channel=2, latency=66150, start_ts=None, head_ts=None)) for _ in range(2)]
        apply = AsyncMock(return_value=SimpleNamespace(status='applied', verified_report=None,
                        report=lambda: {'status': 'applied', 'target_ms': 2040}))
        with patch.object(latency_module, 'apply_planned_latency', apply), \
             patch.object(session_module, 'build_timing_plan', return_value=fixtures.FakePlan()):
            await asyncio.gather(*(group.arrive(client, group.sources[index]) for index, client in enumerate(clients)))
        apply.assert_awaited_once_with('/hflctl', 66150, 44100, target_ms=2040)
        self.assertEqual(len(group.sources[0].delay_buffer), 1323 * 4)
        self.assertEqual(len(group.sources[1].delay_buffer), 0)
        self.assertEqual(group.report['scheduling']['planned_presentation_ms'], 2040)
        self.assertTrue(capture.started)

    async def test_calibrated_preparation_keeps_actual_driver_failure(self):
        from types import SimpleNamespace
        import test_latency_apply as fixtures
        from adapters.live.session import LivePatches
        from adapters.live.latency_apply import LatencyApplyError
        hub = fixtures.FakeLatencyHub(); hub.routes = {0: [0, 1]}
        report = {}
        capture = fixtures.FakeLatencyCapture()
        group = LivePatches(hub, capture, report, latency_control='/hflctl', calibration={0: 314})
        client = SimpleNamespace(context=SimpleNamespace(sample_rate=44100, channels=2,
            bytes_per_channel=2, latency=66150, start_ts=None, head_ts=None))
        with patch('adapters.live.latency_apply.apply_planned_latency',
                   AsyncMock(side_effect=LatencyApplyError('write_rejected'))):
            with self.assertRaisesRegex(Exception, 'write_rejected'):
                await group.arrive(client, group.sources[0])
        self.assertEqual(report['latency_state']['status'], 'failure')
        self.assertIn('write_rejected', report['preparation_failure']['detail'])
        self.assertFalse(capture.started)

class MicrophoneClockChecks(unittest.TestCase):
    def test_arrival_uses_each_hardware_block_clock_instead_of_first_callback(self):
        rate = 48000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'clocked.f32'
            AcousticChecks().recording(rate).tofile(path)
            clock = Path(directory) / 'clock.json'
            frames = range(0, rate * 10, 1024)
            clock.write_text(json.dumps([{'frame': frame,
                'ns': 10e9 + frame / rate * 1e9 + (8e6 if frame >= rate * 2 else 0)} for frame in frames]))
            result = analyze_recording(path, rate, 10e9, 12e9, 2000, clock_path=clock)
            self.assertAlmostEqual(result['residual_ms'], 46, delta=.1)

if __name__ == '__main__': unittest.main()
