"""Run with FLOW_PROCESSING_LIBRARY=/absolute/path/libflow_processing.dylib.

Native tests skip explicitly if unavailable. Pure validation does not pretend
to validate C++ output. No device, recording, network or speaker access.
"""
from array import array
import os
import unittest

from processing.python import Processor, ProcessingError


@unittest.skipUnless(os.environ.get("FLOW_PROCESSING_LIBRARY"), "native DSP library not supplied")
class BindingChecks(unittest.TestCase):
    def make(self, **kw):
        return Processor(os.environ["FLOW_PROCESSING_LIBRARY"],
                         [{"x": .5, "y": .1}, {"x": .2, "y": 1}], **kw)

    def test_safe_default_and_close(self):
        with self.make() as p:
            self.assertEqual(p.process(array("f", [1, -1])), array("f", [0, 0, 0, 0]))
            self.assertEqual(p.next_frame, 1)
        p.close()
        with self.assertRaises(ProcessingError):
            p.process(array("f", [0, 0]))

    def test_ramp_and_block_invariance(self):
        with self.make() as one, self.make() as split:
            for p in (one, split):
                p.set_gain(1, effective_frame=10)
                p.set_gain(.2, output_index=1, effective_frame=500)
            source = array("f", [1, -1] * 1000)
            expected = one.process(source)
            actual = split.process(source[:122]) + split.process(source[122:])
            self.assertEqual(expected, actual)
            self.assertEqual(expected[:40], array("f", [0]*40))
            self.assertEqual(expected[891*4], 1)

    def test_preflight_reject_does_not_consume(self):
        with self.make(initial_master_gain=1) as p:
            for source in (array("f", [float("nan"), 0]), array("f", [1.1, 0])):
                with self.assertRaises(ProcessingError):
                    p.process(source)
            self.assertEqual(p.next_frame, 0)
            self.assertEqual(p.process(array("f", [.5, -.5])), array("f", [.5, -.5, .5, -.5]))
            for frame in (-1, True, 1 << 64):
                with self.assertRaises(ValueError):
                    p.set_gain(.5, effective_frame=frame)
            with self.assertRaises(ValueError):
                p.set_gain(.5, ramp_frames=881)

    def test_cinema_matrix_routes(self):
        with self.make(mode="cinema", initial_master_gain=1) as p:
            matrix = p.matrix
            self.assertNotEqual(matrix[0], matrix[1])
            out = p.process(array("f", [1, 0, 0, 1, 1, 1]))
            for d, (ll, lr, rl, rr) in enumerate(matrix):
                self.assertAlmostEqual(out[d*2], ll)
                self.assertAlmostEqual(out[4+d*2], lr)
                self.assertAlmostEqual(out[8+d*2], ll+lr)
                self.assertLessEqual(abs(ll)+abs(lr), 1.000001)
                self.assertLessEqual(abs(rl)+abs(rr), 1.000001)


if __name__ == "__main__":
    unittest.main()
