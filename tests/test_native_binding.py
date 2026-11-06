"""Requires real Flow shared library via FLOW_CORE_LIBRARY; never plays audio."""
import array
import gc
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bindings.python.flow_core import (
    Engine, CaptureOutput, CoreError, INVALID_ARGUMENT, INVALID_STATE,
    PREPARE_FAILED, TRANSPORT_FAILED, TIMESTAMP_DISCONTINUITY, UNSUPPORTED,
    WOULD_BLOCK,
)

LIBRARY = os.environ.get("FLOW_CORE_LIBRARY")


class NativeBindingTests(unittest.TestCase):
    def engine(self, count=3, cap=100):
        if not LIBRARY:
            self.fail("FLOW_CORE_LIBRARY must point to an actual compiled shared library")
        engine = Engine(LIBRARY, 44100, 3)
        self.addCleanup(engine.close)
        sinks = [CaptureOutput(cap) for _ in range(count)]
        for i, sink in enumerate(sinks):
            engine.add_output(i, [i % 3, i % 3], sink)
        engine.prepare()
        origin = engine.start(7, 1_000_000_000, 3_000_000_000)
        return engine, sinks, origin

    def test_actual_native_fanout_and_owned_callback_data(self):
        engine, sinks, origin = self.engine(5)
        data = array.array("f", [0.1,0.2,0.3,-0.1,-0.2,-0.3])
        engine.submit(7,0,data)
        data[0] = 0.9
        gc.collect()
        self.assertEqual(origin,4_000_000_000)
        for i,sink in enumerate(sinks):
            b = sink.blocks[0]
            self.assertEqual((b.output_id,b.sample_rate,b.channels,b.epoch,b.first_frame,b.presentation_ns),
                             (i,44100,2,7,0,origin))
            expected = (i % 3 + 1) / 10
            for got,want in zip(b.samples,[expected,expected,-expected,-expected]):
                self.assertAlmostEqual(got,want,places=6)
        engine.submit(7,2,[0,0,0])
        for sink in sinks:
            self.assertEqual(sink.blocks[1].presentation_ns,origin + 2_000_000_000 // 44100)

    def test_timestamp_rejection_does_not_advance(self):
        engine,sinks,_ = self.engine()
        for epoch,first in [(8,0),(7,1)]:
            with self.assertRaises(CoreError) as caught:
                engine.submit(epoch,first,[0,0,0])
            self.assertEqual(caught.exception.code,TIMESTAMP_DISCONTINUITY)
        self.assertTrue(all(not x.blocks for x in sinks))
        engine.submit(7,0,[0,0,0])
        self.assertTrue(all(len(x.blocks)==1 for x in sinks))

    def test_samples_rejected_then_valid_retry(self):
        engine,sinks,_ = self.engine()
        for data in [[],[0,0],[float("nan"),0,0],[1.1,0,0]]:
            with self.subTest(data=data),self.assertRaises(CoreError) as caught:
                engine.submit(7,0,data)
            self.assertEqual(caught.exception.code,INVALID_ARGUMENT)
        engine.submit(7,0,[0,0,0])
        self.assertTrue(all(len(x.blocks)==1 for x in sinks))

    def test_capacity_failure_closes_every_native_callback_output(self):
        engine,sinks,_ = self.engine(cap=2)
        with self.assertRaises(CoreError) as caught:
            engine.submit(7,0,[0,0,0,0,0,0])
        self.assertEqual(caught.exception.code,WOULD_BLOCK)
        self.assertTrue(all(not x.open and not x.blocks for x in sinks))
        with self.assertRaises(CoreError) as caught:
            engine.submit(7,0,[0,0,0])
        self.assertEqual(caught.exception.code,INVALID_STATE)

    def test_python_enqueue_exception_contained_by_abi_and_group_closed(self):
        engine,sinks,_ = self.engine()
        def fail(_): raise RuntimeError("injected python enqueue")
        sinks[1].enqueue = fail
        with self.assertRaises(CoreError) as caught:
            engine.submit(7,0,[0,0,0])
        self.assertEqual(caught.exception.code,TRANSPORT_FAILED)
        self.assertIn("injected python enqueue",str(caught.exception))
        self.assertTrue(all(not x.open and not x.blocks for x in sinks))

    def test_python_prepare_exception_closes_attempted_outputs(self):
        if not LIBRARY: self.fail("FLOW_CORE_LIBRARY required")
        engine=Engine(LIBRARY,44100,3);self.addCleanup(engine.close)
        sinks=[CaptureOutput(100) for _ in range(3)]
        for i,s in enumerate(sinks):engine.add_output(i,[i,i],s)
        def fail(*_):
            sinks[1].open=True
            raise RuntimeError("injected prepare")
        sinks[1].prepare=fail
        with self.assertRaises(CoreError) as caught:engine.prepare()
        self.assertEqual(caught.exception.code,PREPARE_FAILED)
        self.assertTrue(all(not s.open for s in sinks))

    def test_non_scheduled_backend_rejected_without_preparing(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        engine=Engine(LIBRARY,44100,3);self.addCleanup(engine.close)
        sink=CaptureOutput(100);engine.add_output(0,[0,0],sink,scheduled=False)
        with self.assertRaises(CoreError) as caught:engine.prepare()
        self.assertEqual(caught.exception.code,UNSUPPORTED)
        self.assertFalse(sink.open)

    def test_integer_overflow_rejected_before_ffi_conversion(self):
        engine,sinks,_=self.engine()
        for epoch,frame in [(-1,0),(1<<64,0),(7,-1),(7,1<<64)]:
            with self.assertRaises(ValueError):engine.submit(epoch,frame,[0,0,0])
        self.assertTrue(all(not s.blocks for s in sinks))

    def test_python_output_alias_cannot_bypass_independent_output_contract(self):
        if not LIBRARY:self.fail("FLOW_CORE_LIBRARY required")
        engine=Engine(LIBRARY,44100,3);self.addCleanup(engine.close)
        sink=CaptureOutput(100);engine.add_output(0,[0,0],sink)
        with self.assertRaises(ValueError):engine.add_output(1,[1,1],sink)

    def test_destroy_releases_queue_and_is_idempotent(self):
        engine,sinks,_=self.engine();engine.submit(7,0,[0,0,0])
        engine.close();engine.close()
        self.assertTrue(all(not s.open and not s.blocks for s in sinks))
        with self.assertRaises(CoreError):engine.prepare()

    def test_failed_constructor_does_not_raise_unraisable_destructor_error(self):
        failures=[]
        with patch.object(sys,"unraisablehook",failures.append):
            for library,rate in [(LIBRARY or "missing-library",-1),("/not/a/flow/library",44100)]:
                with self.assertRaises((ValueError,OSError)):
                    Engine(library,rate,3)
            gc.collect()
        self.assertEqual(failures,[])


if __name__=="__main__":unittest.main(verbosity=2)
