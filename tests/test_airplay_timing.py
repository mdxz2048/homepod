"""Independent protocol mapping tests; no sockets, no receiver playback."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adapters.airplay_pyatv.timing import build_timing_plan, ntp_from_unix_ns, LateStartError
from pyatv.protocols.raop import timing
from pyatv.protocols.raop.protocols import StreamContext


class AirPlayTimingTests(unittest.TestCase):
    def plan(self):
        return build_timing_plan(14_000_000_000,10_000_000_000,
                                 ntp_from_unix_ns(1_794_000_000_123_456_789),44100,66150)

    def test_latency_subtracted_from_core_presentation_origin(self):
        p=self.plan()
        self.assertEqual(p.send_origin_ns,12_500_000_000)
        self.assertEqual(p.presentation_ns-p.send_origin_ns,1_500_000_000)
        self.assertEqual(p.start_ts,timing.ntp2ts(p.ntp_send_origin,44100))

    def test_actual_pyatv_context_first_and_next_rtp_map_to_core_presentation(self):
        p=self.plan();ctx=StreamContext()
        ctx.sample_rate=44100;ctx.latency=66150;ctx.start_ts=ctx.head_ts=p.start_ts
        self.assertEqual(ctx.rtptime,66150)
        for first in (0,352,44100,4_410_000):
            ctx.head_ts=p.start_ts+first
            self.assertEqual(ctx.rtptime,first+66150)
            # Real ControlClient emits (RTP=f, NTP=head), with audio RTP=f+L.
            sync_ntp=timing.ts2ntp(ctx.head_ts,44100)
            projected_audio_ntp=sync_ntp + 66150*(1<<32)//44100
            expected_ntp=p.ntp_send_origin + (first+66150)*(1<<32)//44100
            self.assertLess(abs(projected_audio_ntp-expected_ntp)*1_000_000_000//(1<<32),100_000)

    def test_snapshot_conversion_and_anchor_delta(self):
        self.assertEqual(ntp_from_unix_ns(0),2_208_988_800<<32)
        self.assertEqual(ntp_from_unix_ns(500_000_000),(2_208_988_800<<32)+(1<<31))
        p=build_timing_plan(14_000_000_000,10_000_000_000,100<<32,44100,66150)
        self.assertEqual(p.ntp_send_origin,(102<<32)+(1<<31))

    def test_ready_guard_inclusive_and_late_rejected(self):
        p=self.plan();p.assert_ready(p.send_origin_ns-50_000_000)
        with self.assertRaises(LateStartError):p.assert_ready(p.send_origin_ns-49_999_999)

    def test_release_early_and_late_rejected_at_fixed_plan(self):
        p=self.plan()
        with self.assertRaises(ValueError):p.assert_release(p.send_origin_ns-1)
        p.assert_release(p.send_origin_ns);p.assert_release(p.send_origin_ns+20_000_000)
        with self.assertRaises(LateStartError):p.assert_release(p.send_origin_ns+20_000_001)

    def test_invalid_and_overflow_domains(self):
        args=[14_000_000_000,10_000_000_000,100<<32,44100,66150]
        for index in range(5):
            for value in (-1,True,1.5):
                bad=args.copy();bad[index]=value
                with self.subTest(index=index,value=value),self.assertRaises(ValueError):build_timing_plan(*bad)
        for bad in ([*args[:3],0,args[4]],[(1<<63),*args[1:]],
                    [args[0],1<<63,*args[2:]],[1,*args[1:]],
                    [2_000_000_000,10_000_000_000,0,44100,66150]):
            with self.subTest(args=bad),self.assertRaises(ValueError):build_timing_plan(*bad)


if __name__=="__main__":unittest.main(verbosity=2)
