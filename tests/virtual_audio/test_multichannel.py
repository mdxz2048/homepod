"""Offline tests for source-first multichannel acceptance.

Run:
  python -m unittest discover -s tests/virtual_audio -p test_multichannel.py -v

These tests never play, capture, install, or change a device.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
import unittest

import analyze_multichannel_capture as analyzer
import make_multichannel_fixtures as fixtures
import multichannel_model as model
import multichannel_wav as wav


class LayoutTests(unittest.TestCase):
    def test_canonical_layouts_and_masks(self):
        expected = {
            "mono": (("FC",), 0x4),
            "stereo": (("FL", "FR"), 0x3),
            "3.0": (("FL", "FR", "FC"), 0x7),
            "4.0_quad": (("FL", "FR", "BL", "BR"), 0x33),
            "5.1_side": (("FL", "FR", "FC", "LFE", "SL", "SR"), 0x60F),
            "5.1_back": (("FL", "FR", "FC", "LFE", "BL", "BR"), 0x3F),
            "7.1": (("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"), 0x63F),
            "7.1.2": (
                ("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR"),
                0x363F,
            ),
            "7.1.4": (
                ("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR",
                 "TFL", "TFR", "TBL", "TBR"),
                0xF63F,
            ),
        }
        for name, (labels, mask) in expected.items():
            self.assertEqual(model.labels_for(name), labels)
            self.assertEqual(model.mask_for(name), mask)
            self.assertEqual(model.layout_from_mask(mask, len(labels)), name)

    def test_side_and_back_have_distinct_slot_identity(self):
        side = model.labels_for("5.1_side")
        back = model.labels_for("5.1_back")
        self.assertEqual(side[4:], ("SL", "SR"))
        self.assertEqual(back[4:], ("BL", "BR"))
        self.assertNotEqual(side, back)

    def test_ambiguous_unknown_and_permuted_layouts_reject(self):
        for name in ("5.1", "8ch", "10ch", "5.1.4", "unknown"):
            with self.assertRaises(model.RejectError):
                model.build_route(name, "stereo")
        with self.assertRaises(model.RejectError):
            model.layout_from_mask(0, 6)
        with self.assertRaises(model.RejectError):
            model.validate_labels(("FL", "FR", "FC", "LFE", "SR", "SL"))
        with self.assertRaises(model.RejectError):
            model.validate_labels(("FL", "FL"))
        with self.assertRaises(model.RejectError):
            model.validate_labels(("FL", "FC"))

    def test_silence_never_infers_layout(self):
        with self.assertRaises(model.RejectError) as context:
            model.infer_layout_from_silence([0.25, 0, 0, 0, 0, 0])
        self.assertEqual(context.exception.code, "silence_does_not_identify_layout")


class RoutingTests(unittest.TestCase):
    def test_source_fewer_than_container_is_passthrough_with_silent_extra_slots(self):
        cases = [
            ("mono", "5.1_side", {"FC"}),
            ("stereo", "7.1", {"FL", "FR"}),
            ("4.0_quad", "5.1_back", {"FL", "FR", "BL", "BR"}),
            ("5.1_side", "7.1", {"FL", "FR", "FC", "LFE", "SL", "SR"}),
        ]
        for source, target, active in cases:
            plan = model.build_route(source, target)
            self.assertEqual(plan.mode, "passthrough")
            self.assertFalse(plan.reported_as_native_5_1_or_7_1)
            self.assertFalse(plan.report_container_as_native)
            nonzero = {label for label, row in plan.matrix.items() if row}
            self.assertEqual(nonzero, active)
            for label, row in plan.matrix.items():
                if label not in active:
                    self.assertEqual(row, {})

    def test_source_more_than_container_is_explicit_downmix(self):
        plan = model.build_route("7.1", "5.1_side")
        self.assertEqual(plan.mode, "downmix")
        self.assertAlmostEqual(plan.matrix["SL"]["SL"], 0.5)
        self.assertAlmostEqual(plan.matrix["SL"]["BL"], 0.5)
        self.assertAlmostEqual(plan.matrix["SR"]["SR"], 0.5)
        self.assertAlmostEqual(plan.matrix["SR"]["BR"], 0.5)
        self.assertEqual(plan.matrix["LFE"]["LFE"], 1.0)
        self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-9)

        stereo = model.build_route("7.1", "stereo")
        self.assertEqual(stereo.mode, "downmix")
        self.assertLessEqual(model.max_row_l1(stereo.matrix), 1.0 + 1e-9)
        self.assertTrue(stereo.transformations)

    def test_downmix_has_no_silent_drop(self):
        cases = [
            ("stereo", "mono"),
            ("4.0_quad", "3.0"),
            ("5.1_side", "stereo"),
            ("7.1", "5.1_side"),
            ("7.1", "stereo"),
            ("7.1.2", "7.1"),
            ("7.1.4", "7.1.2"),
        ]
        for source, target in cases:
            plan = model.build_route(source, target)
            used = set()
            for row in plan.matrix.values():
                used.update(row)
            expected = set(model.labels_for(source))
            if "lfe_omitted" in plan.transformations:
                expected.discard("LFE")
            self.assertEqual(used, expected, (source, target, plan.transformations))

    def test_stereo_uses_container_as_carrier_not_native(self):
        for target in ("5.1_side", "7.1"):
            plan = model.build_route("stereo", target)
            self.assertEqual(plan.mode, "passthrough")
            self.assertEqual(plan.provenance, "stereo_passthrough_in_multichannel")
            self.assertFalse(plan.report_container_as_native)
            self.assertFalse(plan.reported_as_native_5_1_or_7_1)
            self.assertEqual(set(plan.matrix["FL"]), {"FL"})
            self.assertEqual(set(plan.matrix["FR"]), {"FR"})

    def test_stereo_upmix_is_one_explicit_fallback(self):
        plan = model.build_route("stereo", "5.1_side", "upmix")
        self.assertEqual(plan.mode, "upmix")
        self.assertEqual(plan.provenance, "stereo_upmix_v1")
        self.assertFalse(plan.reported_as_native_5_1_or_7_1)
        self.assertEqual(plan.matrix["FC"], {"FL": 0.5, "FR": 0.5})
        self.assertEqual(plan.matrix["SL"], {"FL": 0.5, "FR": -0.5})
        self.assertEqual(plan.matrix["SR"], {"FL": -0.5, "FR": 0.5})
        self.assertEqual(plan.matrix["LFE"], {"FL": 0.5, "FR": 0.5})
        seven = model.build_route("stereo", "7.1", "upmix")
        self.assertEqual(seven.matrix["BL"], {})
        self.assertEqual(seven.matrix["BR"], {})

    def test_lfe_policy_is_explicit(self):
        omitted = model.build_route("5.1_side", "stereo")
        self.assertEqual(omitted.matrix["FL"].get("LFE", 0.0), 0.0)
        self.assertIn("lfe_omitted", omitted.transformations)
        self.assertNotIn(61, model.expected_tones(omitted)["FL"])

        folded = model.build_route("5.1_side", "stereo", lfe_policy="fold")
        self.assertGreater(folded.matrix["FL"]["LFE"], 0.0)
        self.assertIn("lfe_folded", folded.transformations)
        self.assertIn(61, model.expected_tones(folded)["FL"])

        keep = model.build_route("7.1", "5.1_side")
        self.assertEqual(keep.matrix["LFE"]["LFE"], 1.0)
        height = model.build_route("7.1.2", "7.1")
        self.assertEqual(height.matrix["LFE"]["LFE"], 1.0)

    def test_reserved_height_layouts(self):
        plan = model.build_route("7.1.2", "7.1")
        self.assertIn("TFL", plan.matrix["FL"])
        self.assertIn("TFR", plan.matrix["FR"])
        four = model.build_route("7.1.4", "7.1.2")
        self.assertIn("TBL", four.matrix["BL"])
        self.assertIn("TBR", four.matrix["BR"])
        self.assertLessEqual(model.max_row_l1(four.matrix), 1.0 + 1e-9)
        self.assertEqual(model.channel_count_for("7.1.2"), 10)
        self.assertEqual(model.channel_count_for("7.1.4"), 12)


class EndpointTests(unittest.TestCase):
    def test_required_speaker_count_matrix(self):
        for source in fixtures.REQUIRED_SOURCES:
            for count in model.REQUIRED_ENDPOINT_COUNTS:
                plan = model.build_endpoint_route(source, count)
                self.assertEqual(plan.container_channel_count, count)
                self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-9)
                claim = model.acoustic_claim_for(source, count)
                if count == 2 and source in model.SURROUND_LAYOUTS:
                    self.assertEqual(claim, "stereo_downmix")

    def test_six_endpoints_preserve_side_or_back_identity(self):
        side = model.build_endpoint_route("5.1_side", 6)
        back = model.build_endpoint_route("5.1_back", 6)
        self.assertEqual(side.container_layout, "5.1_side")
        self.assertEqual(back.container_layout, "5.1_back")
        self.assertEqual(side.mode, "identity")
        self.assertEqual(back.mode, "identity")
        self.assertIn("SL", side.labels)
        self.assertIn("BL", back.labels)

    def test_seven_one_to_six_is_downmix_not_native(self):
        plan = model.build_endpoint_route("7.1", 6)
        self.assertEqual(plan.container_layout, "5.1_side")
        self.assertEqual(plan.mode, "downmix")
        self.assertFalse(plan.reported_as_native_5_1_or_7_1)
        self.assertEqual(model.acoustic_claim_for("7.1", 6), "5.1_side_downmix")

    def test_two_homepods_only_claim_downmix_for_surround(self):
        self.assertEqual(model.acoustic_claim_for("5.1_side", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("7.1", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("stereo", 2), "stereo")
        self.assertEqual(model.acoustic_claim_for("mono", 2), "stereo_upmix")


class GainClipTests(unittest.TestCase):
    def test_all_cases_are_l1_capped(self):
        for case in fixtures.build_cases():
            plan = (
                model.build_endpoint_route(
                    str(case["source_layout"]),
                    model.channel_count_for(str(case["target_layout"])),
                    lfe_policy=str(case["lfe_policy"]),
                )
                if case["kind"] == "endpoint"
                else model.build_route(
                    str(case["source_layout"]),
                    str(case["target_layout"]),
                    str(case["mode"]),
                    lfe_policy=str(case["lfe_policy"]),
                )
            )
            self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-9, case["case"])

    def test_full_scale_12ch_to_stereo_does_not_clip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stress.wav"
            plan = model.build_endpoint_route("7.1.4", 2)
            wav.render_plan(path, plan, duration=0.25, amplitude=1.0)
            data = wav.read_wav(path)
            self.assertLessEqual(max(wav.peak(channel) for channel in data.samples), 1.0 + 1e-6)

    def test_wav_writer_rejects_clipping_input(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(wav.ClippingError):
                wav.write_wav(
                    Path(directory) / "clip.wav",
                    48000,
                    ("FC",),
                    {"FC": [1.5, -1.5]},
                    mask=model.mask_for("mono"),
                )


class RuntimeSemanticsTests(unittest.TestCase):
    def test_per_device_latency_and_revision(self):
        left = model.DeviceClock("left")
        right = model.DeviceClock("right")
        revision = left.set_latency(4800)
        self.assertEqual(right.revision, 1)
        self.assertEqual(left.set_latency(4800), revision)
        self.assertEqual(left.set_latency(2400), revision + 1)
        self.assertEqual(left.set_rate(44100), revision + 2)
        seconds = left.latency_frames / left.rate
        self.assertAlmostEqual(seconds, 2400 / 48000, places=6)
        old = left
        new = left.rediscover()
        self.assertNotEqual(new.revision, old.revision)
        with self.assertRaises(model.RejectError) as context:
            old.assert_revision(old.revision)
        self.assertEqual(context.exception.code, "latency_revision_changed")
        with self.assertRaises(model.RejectError):
            left.set_latency(-1)
        with self.assertRaises(model.RejectError):
            left.set_latency(10 * left.rate + 1)

    def test_host_buffer_range_and_io_frames(self):
        device = model.DeviceClock("buffer")
        revision = device.revision
        for value in (15, 16, 255, 256, 512, 1024, 4096):
            device.set_buffer(value)
            device.accept_io_frames(value)
            self.assertEqual(device.revision, revision)
            self.assertEqual(device.zero_timestamp_period, 16384)
        for value in (14, 4097, 0, -1):
            with self.assertRaises(model.RejectError):
                device.set_buffer(value)
            with self.assertRaises(model.RejectError):
                device.accept_io_frames(value)
        device.set_buffer(256)
        self.assertEqual(device.driver_reported_buffer, 512)
        self.assertEqual(device.buffer_frames, 256)


class LayerClaimTests(unittest.TestCase):
    def test_claims_are_layer_specific(self):
        self.assertEqual(model.acoustic_claim_for("5.1_side", 6), "5.1_side")
        self.assertEqual(model.acoustic_claim_for("7.1", 8), "7.1")
        with self.assertRaises(model.RejectError) as context:
            model.validate_acoustic_claim("5.1_side", 2)
        self.assertEqual(context.exception.code, "acoustic_endpoints_insufficient")
        with self.assertRaises(model.RejectError) as context:
            model.validate_acoustic_claim("5.1_side", 6)
        self.assertEqual(context.exception.code, "acoustic_not_measured")
        model.validate_acoustic_claim("5.1_side", 6, measured=True)

    def test_false_native_descriptor_rejected(self):
        with self.assertRaises(model.RejectError) as context:
            model.validate_descriptor(
                {
                    "source_layout": "stereo",
                    "container_layout": "5.1_side",
                    "reported_as_native_5_1_or_7_1": True,
                }
            )
        self.assertEqual(context.exception.code, "false_native_claim")
        with self.assertRaises(model.RejectError):
            model.validate_descriptor(
                {
                    "source_layout": "5.1_side",
                    "container_layout": "7.1",
                    "report_container_as_native": True,
                }
            )


class FixtureAndAnalyzerTests(unittest.TestCase):
    def test_generator_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            fixtures.create(Path(directory) / "fixtures")
            with self.assertRaises(FileExistsError):
                fixtures.create(Path(directory) / "fixtures")

    def test_source_fixtures_and_expected_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "fixtures"
            manifest = fixtures.create(root)
            self.assertEqual(manifest["case_count"], 84)
            self.assertEqual(manifest["status"], "offline_fixture_only_not_playback")
            for layout, info in manifest["sources"].items():
                data = wav.read_wav(root / fixtures.SOURCE_FILES[layout])
                self.assertEqual(data.channels, model.channel_count_for(layout))
                self.assertEqual(data.mask, model.mask_for(layout))
                self.assertEqual(len(data.samples), data.channels)

    def test_fixture_generation_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            first = fixtures.create(Path(directory) / "first")
            second = fixtures.create(Path(directory) / "second")
            for layout in fixtures.SOURCE_FILES:
                self.assertEqual(
                    first["sources"][layout]["sha256"],
                    second["sources"][layout]["sha256"],
                )
            for case in fixtures.build_cases():
                filename = f"{case['case']}.json"
                self.assertEqual(
                    (Path(directory) / "first" / "expected" / filename).read_bytes(),
                    (Path(directory) / "second" / "expected" / filename).read_bytes(),
                )

    def test_analyzer_passes_and_detects_channel_swap_and_crosstalk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            case = next(c for c in fixtures.build_cases() if c["case"] == "MC-A05")
            plan = model.build_route(
                str(case["source_layout"]), str(case["target_layout"]), str(case["mode"])
            )
            capture = root / "capture.wav"
            expected_path = root / "expected.json"
            expected_path.write_text(
                json.dumps(fixtures.expected_for_case(case)), encoding="utf-8"
            )
            wav.render_plan(capture, plan)
            passed = analyzer.analyze_capture(capture, expected_path)
            self.assertEqual(passed["status"], "pass")

            data = wav.read_wav(capture)
            samples = {
                label: list(data.samples[index])
                for index, label in enumerate(plan.labels)
            }
            samples["SL"], samples["SR"] = samples["SR"], samples["SL"]
            swapped = root / "swapped.wav"
            wav.write_wav(swapped, data.rate, plan.labels, samples, mask=data.mask)
            failed = analyzer.analyze_capture(swapped, expected_path)
            self.assertEqual(failed["status"], "fail")

            samples = {
                label: list(data.samples[index])
                for index, label in enumerate(plan.labels)
            }
            for index in range(len(samples["FL"])):
                samples["FL"][index] += 0.03 * math.sin(
                    2 * math.pi * model.FIXTURE_TONES["FR"] * index / data.rate
                )
            crosstalk = root / "crosstalk.wav"
            wav.write_wav(crosstalk, data.rate, plan.labels, samples, mask=data.mask)
            failed = analyzer.analyze_capture(crosstalk, expected_path)
            self.assertEqual(failed["status"], "fail")


if __name__ == "__main__":
    unittest.main()

