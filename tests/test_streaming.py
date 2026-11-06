"""Bounded native continuous routing, accelerated media time, no speaker access."""
import asyncio
import math
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adapters.airplay_pyatv.streaming import BoundedHub,ToneReader,StreamingSource,StreamFailure
from adapters.airplay_pyatv.timing import LateStartError
from bindings.python.flow_core import Engine

LIBRARY=os.environ.get("FLOW_CORE_LIBRARY")


class StreamingTests(unittest.TestCase):
    def hub(self,seconds=.1,**kwargs):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required, actual native routing cannot be mocked")
        reader=ToneReader(seconds,channels=2)
        defaults=dict(block_frames=352,capacity_blocks=3,stall_timeout=.2,clock_ns=lambda:1_000_000_000)
        defaults.update(kwargs)
        result=BoundedHub(LIBRARY,reader,{0:[0,0],1:[1,1]},**defaults)
        result.start(1_000_000_000,3_000_000_000,epoch=17)
        return result,reader

    def test_61_second_media_stream_is_incremental_native_and_bounded_with_unequal_reads(self):
        async def run():
            hub,reader=self.hub(61)
            self.assertEqual(reader.read_calls,0,"start must not pre-render input")
            tracker={"next":0,"calls":0}
            original=Engine.submit
            def submit(engine,epoch,first,samples):
                self.assertEqual(epoch,17);self.assertEqual(first,tracker["next"])
                self.assertLessEqual(len(samples),352*2)
                original(engine,epoch,first,samples)
                tracker["next"]+=len(samples)//2;tracker["calls"]+=1
            async def consume(output,count):
                total=0
                while True:
                    data=await hub.read(output,count)
                    if not data:break
                    total+=len(data)//4
                    # Unequal request sizes and cooperative scheduling exercise
                    # distinct queue occupancy without a wall-clock longplay.
                    await asyncio.sleep(0)
                return total
            try:
                with patch.object(Engine,"submit",submit):
                    totals=await asyncio.gather(consume(0,127),consume(1,509))
                report=hub.report()
                expected=61*44100
                self.assertEqual(totals,[expected,expected])
                self.assertEqual(tracker["next"],expected)
                self.assertEqual(tracker["calls"],math.ceil(expected/352))
                self.assertTrue(report["input_eof"] and report["input_closed"])
                self.assertFalse(report["group_failed"])
                self.assertLessEqual(reader.max_read_frames,352)
                self.assertEqual(reader.frames_read,expected)
                last=(math.ceil(expected/352)-1)*352
                for out in report["outputs"]:
                    self.assertEqual(out["native_frames"],expected)
                    self.assertEqual(out["consumed_frames"],expected)
                    self.assertEqual(out["native_pcm_sha256"],out["consumed_pcm_sha256"])
                    self.assertEqual(out["first_presentation_ns"],4_000_000_000)
                    self.assertEqual(out["last_presentation_ns"],4_000_000_000+last*1_000_000_000//44100)
                    self.assertLessEqual(out["queue_peak_frames"],report["queue_capacity_frames"])
                    self.assertEqual(out["buffer_current_frames"],0)
                    self.assertGreater(out["eof_reads"],0)
                self.assertNotEqual(report["outputs"][0]["native_pcm_sha256"],report["outputs"][1]["native_pcm_sha256"])
                self.assertEqual(report["queue_capacity_frames"],1056)
            finally:await hub.stop()
        asyncio.run(run())

    def test_temporarily_empty_peer_queue_is_not_eof(self):
        async def run():
            hub,reader=self.hub()
            try:
                first=await hub.read(0,1)
                self.assertEqual(len(first),4)
                self.assertFalse(hub.input_eof)
                self.assertEqual(reader.frames_read,352)
                self.assertTrue(await hub.read(1,1))
                self.assertEqual(reader.read_calls,1)
            finally:await hub.stop()
        asyncio.run(run())

    def test_stalled_peer_times_out_and_closes_group_without_unbounded_input(self):
        async def run():
            hub,reader=self.hub(capacity_blocks=1,stall_timeout=.01)
            try:
                with self.assertRaises(TimeoutError):await hub.read(0,704)
                report=hub.report()
                self.assertTrue(report["group_failed"] and report["hub_stopped"] and report["input_closed"])
                self.assertLessEqual(reader.frames_read,352)
                for out in report["outputs"]:self.assertEqual(out["buffer_current_frames"],0)
                with self.assertRaises(StreamFailure):await hub.read(1,1)
            finally:await hub.stop()
        asyncio.run(run())

    def test_explicit_stop_wakes_waiting_reader(self):
        async def run():
            hub,reader=self.hub(capacity_blocks=1,stall_timeout=1)
            waiting=asyncio.create_task(hub.read(0,704))
            await asyncio.sleep(.01)
            await hub.stop();await hub.stop()
            with self.assertRaises(StreamFailure):await asyncio.wait_for(waiting,.1)
            self.assertTrue(reader.closed)
            self.assertTrue(all(not out.queue for out in hub.outputs.values()))
        asyncio.run(run())

    def test_source_failure_fails_all_and_releases_queues(self):
        async def run():
            hub,reader=self.hub()
            def fail(_):raise OSError("injected reader failure")
            reader.read=fail
            try:
                with self.assertRaisesRegex(OSError,"injected reader"):await hub.read(0,1)
                self.assertTrue(reader.closed and hub.report()["group_failed"])
                with self.assertRaises(StreamFailure):await hub.read(1,1)
            finally:await hub.stop()
        asyncio.run(run())

    def test_late_presentation_is_rejected_instead_of_reported_synchronized(self):
        async def run():
            now=[1_000_000_000]
            hub,reader=self.hub(clock_ns=lambda:now[0])
            now[0]=4_000_000_000
            try:
                with self.assertRaises(LateStartError):await hub.read(0,1)
                self.assertTrue(reader.closed and hub.report()["group_failed"])
                self.assertIs(hub.report()["acoustic_sync_verified"],False)
            finally:await hub.stop()
        asyncio.run(run())

    def test_cancelled_source_read_fails_group_and_releases_resources(self):
        async def run():
            hub,reader=self.hub(capacity_blocks=1,stall_timeout=1)
            source=StreamingSource(hub,0)
            waiting=asyncio.create_task(source.readframes(704));await asyncio.sleep(.01)
            waiting.cancel()
            with self.assertRaises(asyncio.CancelledError):await waiting
            self.assertTrue(reader.closed and hub.report()["group_failed"])
            await source.close();await hub.stop()
        asyncio.run(run())


if __name__=="__main__":unittest.main(verbosity=2)
