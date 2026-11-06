"""Real native routing -> actual custom pyatv source, with no network playback."""
import array
import asyncio
from dataclasses import replace
import os
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adapters.airplay_pyatv.render import render_audio
from adapters.airplay_pyatv.source import CoreAudioSource
from bindings.python.flow_core import Engine

LIBRARY=os.environ.get("FLOW_CORE_LIBRARY")


class AirPlayBridgeTests(unittest.TestCase):
    def render(self,**kwargs):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY must point to real native library")
        defaults=dict(library=LIBRARY,samples=[0.25,-0.5,0.75,-0.25,0.5,-0.75,0,1,-1],
                      sample_rate=44100,channels=3,routes={9:[2,2],4:[0,1]},
                      now_ns=1_000_000_000,lead_ns=3_000_000_000,epoch=11,block_frames=2)
        defaults.update(kwargs)
        return render_audio(**defaults)

    def test_native_submit_called_and_cpp_output_consumed_by_source(self):
        calls=[]
        original=Engine.submit
        def submit(engine,epoch,first,samples):
            calls.append((epoch,first,len(samples)))
            return original(engine,epoch,first,samples)
        with patch.object(Engine,"submit",submit):batch=self.render()
        self.assertEqual(calls,[(11,0,6),(11,2,3)])
        expected={9:[24575,24575,-24575,-24575,-32767,-32767],
                  4:[8192,-16384,-8192,16384,0,32767]}
        async def consume():
            for key,output in batch.outputs.items():
                source=CoreAudioSource(key,44100,3);source.attach(output)
                self.assertEqual((source.channels,source.sample_size,source.sample_rate),(2,2,44100))
                data=await source.readframes(2)+await source.readframes(2)
                self.assertEqual(list(struct.unpack(">6h",data)),expected[key])
                self.assertEqual(await source.readframes(2),b"")
                self.assertEqual(source.frames_read,3)
                await source.close();self.assertEqual(await source.readframes(2),b"")
        asyncio.run(consume())
        for output in batch.outputs.values():
            self.assertEqual([b.first_frame for b in output.blocks],[0,2])
            self.assertEqual([b.presentation_ns for b in output.blocks],
                             [4_000_000_000,4_000_000_000+2_000_000_000//44100])
        report=batch.report()
        self.assertTrue(report["native_core_used"])
        self.assertIs(report["acoustic_sync_verified"],False)

    def test_source_refuses_unattached_reads_and_mismatched_or_repeated_attachment(self):
        out=self.render().outputs[9]
        async def verify():
            source=CoreAudioSource(9,44100,3)
            with self.assertRaises(RuntimeError):await source.readframes(2)
            for invalid in [replace(out,output_id=10),replace(out,sample_rate=48000),
                            replace(out,channels=1),replace(out,frames=4),replace(out,pcm_be=b"bad")]:
                with self.assertRaises(ValueError):source.attach(invalid)
            source.attach(out)
            with self.assertRaises(ValueError):source.attach(out)
            with self.assertRaises(ValueError):await source.readframes(0)
            await source.close()
            with self.assertRaises(ValueError):source.attach(out)
        asyncio.run(verify())

    def test_bounded_render_rejects_before_loading_native_library(self):
        # Missing library proves these limits run before CDLL/engine allocation.
        for kwargs in [dict(samples=[]),dict(samples=[0,0]),dict(routes={}),
                       dict(routes={i:[0,0] for i in range(9)}),
                       dict(block_frames=0),dict(sample_rate=0),dict(channels=0)]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):
                self.render(library="/missing/native/library",**kwargs)


if __name__=="__main__":unittest.main(verbosity=2)
