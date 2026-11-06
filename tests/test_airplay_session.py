"""Session orchestration with fake network endpoints; NEVER connect speakers."""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adapters.airplay_pyatv import session
from adapters.airplay_pyatv import cli
from adapters.airplay_pyatv.source import CoreAudioSource
from adapters.airplay_pyatv.timing import LateStartError
from pyatv.protocols.raop.protocols import StreamContext
from pyatv.protocols.raop.stream_client import ControlClient,StreamClient
from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
import pyatv.protocols.raop as raop

LIBRARY=os.environ.get("FLOW_CORE_LIBRARY")


class AirPlaySessionTests(unittest.TestCase):
    def make(self,**kwargs):
        defaults=dict(library=LIBRARY,samples=[.1,.2,.3,-.1,-.2,-.3],sample_rate=44100,
                      channels=3,routes={0:[0,0],1:[1,1],2:[2,2]},report={})
        defaults.update(kwargs);return session.SessionPatches(**defaults)

    def snapshots(self):
        return (raop.open_source,ControlClient.start,StreamClient._stream_data,
                AirPlayV2.setup_audio_stream,AirPlayV2.send_audio_packet)

    def test_scoped_install_rejects_overlap_and_restores_every_method_on_error(self):
        original=self.snapshots();gate=self.make()
        with self.assertRaisesRegex(RuntimeError,"injected body"):
            with gate:
                self.assertNotEqual(self.snapshots(),original)
                with self.assertRaisesRegex(RuntimeError,"active"):
                    with self.make():pass
                raise RuntimeError("injected body")
        self.assertEqual(self.snapshots(),original)
        self.assertFalse(session.SessionPatches._active)

    def test_partial_patch_install_failure_restores_prior_methods(self):
        original=self.snapshots()
        class Broken(session.SessionPatches):
            def _install(self):
                self._replace(ControlClient,"start",lambda *_:None)
                raise RuntimeError("injected install")
        with self.assertRaisesRegex(RuntimeError,"injected install"):
            with Broken(None,[0,0,0],44100,3,{0:[0,0]},{}):pass
        self.assertEqual(self.snapshots(),original)
        self.assertFalse(session.SessionPatches._active)

    def test_barrier_timeout_never_builds_or_releases_partial_group(self):
        gate=self.make(barrier_timeout=.01)
        async def run():
            with patch.object(gate,"_prepare_plan") as build:
                with self.assertRaises(asyncio.TimeoutError):
                    await gate.arrive(SimpleNamespace(),gate.sources[0])
                build.assert_not_called()
            self.assertIsNone(gate.plan)
            self.assertEqual(gate.report,{})
        asyncio.run(run())

    def test_mismatched_receiver_latency_refused_before_native_render(self):
        gate=self.make();contexts=[StreamContext(),StreamContext(),StreamContext()]
        contexts[1].latency+=1
        gate.clients=[(SimpleNamespace(context=ctx),gate.sources[i]) for i,ctx in enumerate(contexts)]
        with patch.object(session,"render_audio") as render:
            with self.assertRaisesRegex(ValueError,"same"):
                gate._prepare_plan()
            render.assert_not_called()
        self.assertTrue(all(s._pcm is None for s in gate.sources.values()))

    def test_real_native_plan_attaches_all_sources_and_applies_latency_mapping(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        gate=self.make();contexts=[StreamContext() for _ in range(3)]
        gate.clients=[(SimpleNamespace(context=ctx),gate.sources[i]) for i,ctx in enumerate(contexts)]
        with patch.object(session.time,"monotonic_ns",return_value=10_000_000_000),\
             patch.object(session.time,"time_ns",return_value=1_794_000_000_000_000_000):
            gate._prepare_plan()
        self.assertEqual(gate.rendered.origin_ns,18_000_000_000)
        self.assertEqual(gate.plan.send_origin_ns,16_500_000_000)
        self.assertTrue(all(c.start_ts==c.head_ts==gate.plan.start_ts for c in contexts))
        self.assertTrue(all(c.rtptime==66150 for c in contexts))
        self.assertTrue(all(s._pcm is not None for s in gate.sources.values()))
        self.assertIs(gate.report["acoustic_sync_verified"],False)

    def test_slow_real_render_refuses_plan_before_release(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        gate=self.make();gate.clients=[(SimpleNamespace(context=StreamContext()),s) for s in gate.sources.values()]
        with patch.object(session.time,"monotonic_ns",side_effect=[10_000_000_000,10_000_000_000,16_500_000_000]),\
             patch.object(session.time,"time_ns",return_value=1_794_000_000_000_000_000):
            with self.assertRaises(LateStartError):gate._prepare_plan()
        self.assertNotIn("stream_releases",gate.report)

    def test_full_play_stream_failure_closes_sources_connections_and_restores_patches(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        original=self.snapshots();sources=[];connections=[]
        def create_source(*args):
            result=CoreAudioSource(*args);sources.append(result);return result
        def create_connection():
            c=SimpleNamespace(audio=SimpleNamespace(set_volume=AsyncMock()),
                              stream=SimpleNamespace(stream_file=AsyncMock(side_effect=RuntimeError("injected stream"))))
            c.close=lambda:connections.append(c) or set()
            return c
        hosts={0:"offline-a",1:"offline-b",2:"offline-c"}
        devices=[SimpleNamespace(address=h) for h in hosts.values()]
        report={}
        async def run():
            with patch.object(session,"scan",AsyncMock(return_value=devices)),\
                 patch("pyatv.connect",AsyncMock(side_effect=[create_connection() for _ in range(3)])),\
                 patch.object(session,"CoreAudioSource",side_effect=create_source):
                with self.assertRaisesRegex(RuntimeError,"injected stream"):
                    await session.play(LIBRARY,[.1,.2,.3],44100,3,{0:[0,0],1:[1,1],2:[2,2]},hosts,report=report)
        asyncio.run(run())
        self.assertEqual(len(connections),3);self.assertEqual(len(sources),3)
        self.assertTrue(all(s.closed for s in sources))
        self.assertEqual(self.snapshots(),original)
        self.assertFalse(session.SessionPatches._active)
        self.assertEqual(report["status"],"failed")
        self.assertIs(report["acoustic_sync_verified"],False)

    def test_cleanup_closes_every_resource_when_one_close_raises(self):
        async def run():
            source=CoreAudioSource(0,44100,1)
            def fail():raise RuntimeError("injected connection close")
            report={}
            result=await session.cleanup_session([SimpleNamespace(close=fail)],[],[source],report,timeout=.01)
            self.assertFalse(result);self.assertTrue(source.closed)
            self.assertFalse(report["cleanup_complete"])
            self.assertIn("injected connection close",str(report["cleanup_errors"]))
        asyncio.run(run())

    def test_async_close_failure_cannot_report_cleanup_complete(self):
        async def run():
            async def fail():raise RuntimeError("injected async close")
            closing=asyncio.create_task(fail())
            report={}
            result=await session.cleanup_session([SimpleNamespace(close=lambda:{closing})],[],[],report,timeout=.01)
            self.assertFalse(result)
            self.assertFalse(report["cleanup_complete"])
            self.assertIn("injected async close",str(report["cleanup_errors"]))
        asyncio.run(run())

    def test_cleanup_cancels_active_stream_and_closes_source(self):
        async def run():
            started=asyncio.Event();cancelled=asyncio.Event()
            async def stream():
                started.set()
                try:await asyncio.Event().wait()
                finally:cancelled.set()
            task=asyncio.create_task(stream());await started.wait()
            source=CoreAudioSource(0,44100,1);report={}
            self.assertTrue(await session.cleanup_session([], [task], [source], report, timeout=.01))
            self.assertTrue(cancelled.is_set() and task.cancelled() and source.closed)
        asyncio.run(run())

    def test_cli_dry_run_uses_native_and_never_scans_or_connects(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        text=io.StringIO()
        with patch.object(session,"scan",AsyncMock()) as scan,\
             patch("pyatv.connect",AsyncMock()) as connect,contextlib.redirect_stdout(text):
            code=cli.main(["dry-run","--library",LIBRARY,"--seconds","0.01"])
        self.assertEqual(code,0);scan.assert_not_called();connect.assert_not_called()
        report=json.loads(text.getvalue())
        self.assertEqual(report["status"],"offline_dry_run_completed")
        self.assertIs(report["network_used"],False)
        self.assertTrue(report["native_core_used"])
        self.assertIs(report["acoustic_sync_verified"],False)
        self.assertEqual(len(report["audio_source_consumed"]),3)

    def test_cli_failure_has_failed_status_without_scanning(self):
        text=io.StringIO()
        with patch.object(session,"scan",AsyncMock()) as scan,contextlib.redirect_stdout(text):
            code=cli.main(["dry-run","--library","/missing/native/library","--seconds","0"])
        self.assertEqual(code,1);scan.assert_not_called()
        report=json.loads(text.getvalue())
        self.assertEqual(report["status"],"failed")
        self.assertIn("error",report)
        self.assertIs(report["acoustic_sync_verified"],False)


if __name__=="__main__":unittest.main(verbosity=2)
