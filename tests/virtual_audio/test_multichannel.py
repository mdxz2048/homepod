"""Offline tests for source-first multichannel acceptance (contract v1).

Run:
  python -m unittest discover -s tests/virtual_audio -p test_multichannel.py -v

These tests never play, capture, install, SSH, use Git, or change a device.
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
    def test_canonical_layouts_masks_and_channel_order(self):
        expected = {
            "mono": (("M",), 0x4),
            "stereo": (("FL", "FR"), 0x3),
            "3.0": (("FL", "FR", "FC"), 0x7),
            "4.0_quad": (("FL", "FR", "BL", "BR"), 0x33),
            "5.1_side": (("FL", "FR", "FC", "LFE", "SL", "SR"), 0x60F),
            "5.1_back": (("FL", "FR", "FC", "LFE", "BL", "BR"), 0x3F),
            "7.1": (("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"), 0x63F),
            "5.1.2": (("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR"), 0x560F),
            "7.1.2": (
                ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR"),
                0x563F,
            ),
            "7.1.4": (
                ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR",
                 "TFL", "TFR", "TRL", "TRR"),
                0x2D63F,
            ),
        }
        for name, (labels, mask) in expected.items():
            self.assertEqual(model.labels_for(name), labels, name)
            self.assertEqual(model.channel_order(name), labels, name)
            self.assertEqual(model.mask_for(name), mask, name)
            self.assertEqual(model.layout_from_mask(mask, len(labels)), name)
        self.assertEqual(model.contract_token("7.1"), "7_1")
        self.assertEqual(model.contract_token("5.1.2"), "5_1_2")

    def test_side_precedes_back_in_7_1_and_512_is_not_7_1(self):
        order = model.channel_order("7.1")
        self.assertEqual(order, ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"))
        self.assertLess(order.index("SL"), order.index("BL"))
        self.assertLess(order.index("SR"), order.index("BR"))
        self.assertEqual(model.labels_for("5.1_side")[4:], ("SL", "SR"))
        self.assertEqual(model.labels_for("5.1_back")[4:], ("BL", "BR"))
        self.assertEqual(model.channel_count_for("5.1.2"), 8)
        self.assertNotEqual(model.labels_for("5.1.2"), model.labels_for("7.1"))
        self.assertNotIn("BL", model.labels_for("5.1.2"))

    def test_ambiguous_unknown_and_permuted_layouts_reject(self):
        for name in ("5.1", "8ch", "10ch", "12ch"):
            with self.assertRaises(model.RejectError) as context:
                model.build_route(name, "stereo")
            self.assertEqual(context.exception.code, "source_layout_ambiguous")
        for name in ("5.1.4", "unknown"):
            with self.assertRaises(model.RejectError) as context:
                model.build_route(name, "stereo")
            self.assertEqual(context.exception.code, "unsupported_layout")
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
    def test_capture_is_identity_pad_or_refused_only(self):
        pad = model.plan_capture("5.1_back", "7.1")
        self.assertEqual(pad.kind, "pad_silent")
        self.assertEqual(pad.provenance, "source_padded")
        self.assertEqual(pad.silent_slots, [4, 5])
        self.assertEqual(
            pad.placed,
            [
                {"sourceLabel": "FL", "slot": 0},
                {"sourceLabel": "FR", "slot": 1},
                {"sourceLabel": "FC", "slot": 2},
                {"sourceLabel": "LFE", "slot": 3},
                {"sourceLabel": "BL", "slot": 6},
                {"sourceLabel": "BR", "slot": 7},
            ],
        )
        self.assertIn("pad_5_1_back_to_7_1", pad.transformations)
        model.validate_capture_claims(pad)

        identity = model.plan_capture("7.1", "7.1")
        self.assertEqual(identity.kind, "identity")
        self.assertEqual(identity.provenance, "source_native")
        self.assertTrue(identity.native_claim)

        stereo = model.plan_capture("stereo", "5.1_side")
        self.assertEqual(stereo.kind, "pad_silent")
        self.assertEqual(stereo.provenance, "stereo_passthrough_in_multichannel")
        self.assertFalse(stereo.native_claim)
        self.assertEqual(stereo.transformations, ["stereo_passthrough"])

        refusals = [
            ("7.1", "5.1_side", "source_exceeds_container"),
            ("5.1_side", "5.1_back", "container_layout_mismatch"),
            ("5.1_back", "5.1_side", "container_layout_mismatch"),
            ("4.0_quad", "5.1_side", "container_layout_mismatch"),
            ("mono", "stereo", "container_layout_mismatch"),
            ("3.0", "4.0_quad", "container_layout_mismatch"),
        ]
        for source, container, code in refusals:
            refused = model.plan_capture(source, container)
            self.assertEqual(refused.kind, "refused", (source, container))
            self.assertEqual(refused.error, code, (source, container))
            with self.assertRaises(model.RejectError) as context:
                model.require_capture(source, container)
            self.assertEqual(context.exception.code, code)

    def test_flow_7_1_to_6_uses_contract_coefficients(self):
        plan = model.build_route("7.1", "5.1_side")
        self.assertEqual(plan.mode, "downmix")
        self.assertEqual(plan.matrix_id, "M_71_6")
        self.assertAlmostEqual(plan.matrix["SL"]["SL"], 0.5)
        self.assertAlmostEqual(plan.matrix["SL"]["BL"], 0.5)
        self.assertAlmostEqual(plan.matrix["SR"]["SR"], 0.5)
        self.assertAlmostEqual(plan.matrix["SR"]["BR"], 0.5)
        self.assertEqual(plan.matrix["LFE"]["LFE"], 1.0)
        self.assertEqual(plan.losses["downmixed"], ["BL", "BR"])
        self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-12)
        self.assertFalse(plan.reported_as_native_5_1_or_7_1)

        back = model.build_route("7.1", "5.1_back")
        self.assertEqual(back.matrix_id, "M_71_6B")
        self.assertAlmostEqual(back.matrix["BL"]["BL"], 0.5)
        self.assertAlmostEqual(back.matrix["BL"]["SL"], 0.5)

    def test_downmix_losses_cover_every_source_label(self):
        cases = ["3.0", "4.0_quad", "5.1_side", "5.1_back", "7.1"]
        for source in cases:
            plan = model.build_route(source, "stereo")
            accounted = set(plan.losses.get("downmixed", []))
            accounted.update(plan.losses.get("discarded", []))
            source_labels = set(model.labels_for(source))
            # FL/FR keep their output names; every other source channel is
            # either folded (downmixed) or explicitly discarded.
            expected = source_labels - set(model.labels_for("stereo"))
            self.assertEqual(accounted, expected, source)
            if "LFE" in source_labels:
                self.assertIn("LFE", plan.losses["discarded"])
                for row in plan.matrix.values():
                    self.assertNotIn("LFE", row)
        seven = model.build_route("7.1", "5.1_side")
        self.assertEqual(set(seven.losses["downmixed"]), {"BL", "BR"})

    def test_stereo_carrier_is_padded_not_native(self):
        for target in ("5.1_side", "5.1_back", "7.1"):
            plan = model.build_route("stereo", target)
            self.assertEqual(plan.mode, "padded")
            self.assertEqual(plan.provenance, "padded")
            self.assertFalse(plan.native)
            self.assertFalse(plan.reported_as_native_5_1_or_7_1)
            self.assertEqual(set(plan.matrix["FL"]), {"FL"})
            self.assertEqual(set(plan.matrix["FR"]), {"FR"})
            self.assertIn("FC", plan.losses["silent"])
            capture = model.plan_capture("stereo", target)
            self.assertEqual(capture.provenance, "stereo_passthrough_in_multichannel")

    def test_stereo_upmix_matches_contract_matrix(self):
        plan = model.build_route("stereo", "5.1_side", "upmix")
        self.assertEqual(plan.mode, "upmix")
        self.assertEqual(plan.matrix_id, "M_ST_51S")
        self.assertAlmostEqual(plan.matrix["FL"]["FL"], model.SQRT_HALF)
        self.assertAlmostEqual(plan.matrix["FR"]["FR"], model.SQRT_HALF)
        self.assertAlmostEqual(plan.matrix["FC"]["FL"], model.F_COEFF)
        self.assertAlmostEqual(plan.matrix["FC"]["FR"], model.F_COEFF)
        self.assertEqual(plan.matrix["SL"], {"FL": 0.5, "FR": -0.5})
        self.assertEqual(plan.matrix["SR"], {"FL": -0.5, "FR": 0.5})
        self.assertEqual(plan.matrix["LFE"], {})
        self.assertFalse(plan.native)

        seven = model.build_route("stereo", "7.1", "upmix")
        self.assertEqual(seven.matrix_id, "M_ST_71")
        self.assertEqual(seven.matrix["BL"], {})
        self.assertEqual(seven.matrix["BR"], {})
        with self.assertRaises(model.RejectError) as context:
            model.build_route("stereo", "3.0", "upmix")
        self.assertEqual(context.exception.code, "transform_unavailable")

    def test_lfe_is_discarded_to_stereo_and_never_folded(self):
        for source in ("5.1_side", "5.1_back", "7.1"):
            plan = model.build_route(source, "stereo")
            self.assertIn("LFE", plan.losses["discarded"])
            self.assertEqual(plan.matrix_id, {
                "5.1_side": "M_51S_2",
                "5.1_back": "M_51B_2",
                "7.1": "M_71_2",
            }[source])
            self.assertNotIn(61, model.expected_tones(plan)["FL"])
        self.assertNotIn("lfe_folded", " ".join(
            item for plan in [model.build_route("5.1_side", "stereo")]
            for item in plan.transformations
        ))
        keep = model.build_route("7.1", "5.1_side")
        self.assertEqual(keep.matrix["LFE"]["LFE"], 1.0)
        height = model.build_route("7.1.2", "7.1")
        self.assertEqual(height.matrix["LFE"]["LFE"], 1.0)

    def test_reserved_height_uses_trl_trr_and_512(self):
        plan = model.build_route("7.1.2", "7.1")
        self.assertEqual(plan.matrix_id, "M_712_71")
        self.assertIn("TFL", plan.matrix["FL"])
        self.assertIn("TFR", plan.matrix["FR"])
        self.assertEqual(set(plan.losses["downmixed"]), {"TFL", "TFR"})

        four = model.build_route("7.1.4", "7.1.2")
        self.assertEqual(four.matrix_id, "M_714_712")
        self.assertIn("TRL", four.matrix["TFL"])
        self.assertIn("TRR", four.matrix["TFR"])
        self.assertNotIn("TBL", model.ALLOWED_LABELS)
        self.assertNotIn("TBR", model.ALLOWED_LABELS)
        self.assertLessEqual(model.max_row_l1(four.matrix), 1.0 + 1e-12)

        five = model.build_route("5.1.2", "7.1")
        self.assertEqual(five.matrix_id, "M_512_71")
        self.assertNotIn("BL", model.labels_for("5.1.2"))
        self.assertEqual(model.channel_count_for("5.1.2"), 8)


class EndpointTests(unittest.TestCase):
    def test_contract_endpoint_capability_cells(self):
        table = {
            "mono": {1: "native", 2: "mono_map", 3: "mono_map",
                     4: "mono_map", 6: "mono_map", 8: "mono_map"},
            "stereo": {2: "native", 3: "padded", 4: "padded",
                       6: "padded", 8: "padded"},
            "3.0": {2: "downmix", 3: "native", 6: "padded", 8: "padded"},
            "4.0_quad": {2: "downmix", 4: "native", 6: "padded", 8: "padded"},
            "5.1_side": {2: "downmix", 6: "native", 8: "padded"},
            "5.1_back": {2: "downmix", 6: "native", 8: "padded"},
            "7.1": {2: "downmix", 6: "downmix", 8: "native"},
        }
        for source, counts in table.items():
            for count, mode in counts.items():
                plan = model.build_endpoint_route(source, count)
                self.assertEqual(plan.mode, mode, (source, count))
                self.assertEqual(plan.container_channel_count, count)
                self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-12)
        for source, count in [
            ("stereo", 1), ("3.0", 1), ("3.0", 4), ("5.1_side", 3),
            ("5.1_back", 4), ("7.1", 3), ("7.1", 4),
        ]:
            with self.assertRaises(model.RejectError) as context:
                model.build_endpoint_route(source, count)
            self.assertEqual(context.exception.code, "route_unsupported",
                             (source, count))

    def test_six_endpoints_preserve_side_or_back_identity(self):
        side = model.build_endpoint_route("5.1_side", 6)
        back = model.build_endpoint_route("5.1_back", 6)
        self.assertEqual(side.container_layout, "5.1_side")
        self.assertEqual(back.container_layout, "5.1_back")
        self.assertEqual(side.mode, "native")
        self.assertEqual(back.mode, "native")
        self.assertIn("SL", side.labels)
        self.assertIn("BL", back.labels)
        quad = model.build_endpoint_route("4.0_quad", 6)
        self.assertEqual(quad.container_layout, "5.1_back")
        self.assertEqual(quad.mode, "padded")

    def test_seven_one_to_six_is_downmix_not_native(self):
        plan = model.build_endpoint_route("7.1", 6)
        self.assertEqual(plan.container_layout, "5.1_side")
        self.assertEqual(plan.mode, "downmix")
        self.assertFalse(plan.reported_as_native_5_1_or_7_1)
        self.assertEqual(model.acoustic_claim_for("7.1", 6), "5.1_side_downmix")

    def test_two_homepods_only_claim_downmix_or_mono_map(self):
        self.assertEqual(model.acoustic_claim_for("5.1_side", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("5.1_back", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("7.1", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("stereo", 2), "stereo")
        self.assertEqual(model.acoustic_claim_for("mono", 2), "stereo_mono_map")


class GainClipTests(unittest.TestCase):
    def test_all_cases_are_l1_capped_and_ordered(self):
        for case in fixtures.build_cases():
            if case["kind"] == "endpoint":
                plan = model.build_endpoint_route(
                    str(case["source_layout"]),
                    model.channel_count_for(str(case["target_layout"])),
                )
            else:
                plan = model.build_route(
                    str(case["source_layout"]),
                    str(case["target_layout"]),
                    str(case["mode"]),
                )
            self.assertLessEqual(model.max_row_l1(plan.matrix), 1.0 + 1e-12,
                                 case["case"])
            self.assertEqual(list(plan.channel_order),
                             list(model.labels_for(plan.container_layout)),
                             case["case"])

    def test_full_scale_12ch_to_stereo_does_not_clip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stress.wav"
            plan = model.build_endpoint_route("7.1.4", 2)
            wav.render_plan(path, plan, duration=0.25, amplitude=1.0)
            data = wav.read_wav(path)
            self.assertLessEqual(max(wav.peak(channel) for channel in data.samples),
                                 1.0 + 1e-6)

    def test_wav_writer_rejects_clipping_input(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(wav.ClippingError):
                wav.write_wav(
                    Path(directory) / "clip.wav",
                    48000,
                    ("M",),
                    {"M": [1.5, -1.5]},
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
        for value in (0, 1, 14, 4095, 4096):
            device.accept_io_frames(value)
        for value in (14, 0, -1, 4097):
            with self.assertRaises(model.RejectError):
                device.set_buffer(value)
        for value in (-1, 4097):
            with self.assertRaises(model.RejectError) as context:
                device.accept_io_frames(value)
            self.assertEqual(context.exception.code, "unsupported_io_frames")
        device.set_buffer(256)
        self.assertEqual(device.driver_reported_buffer, 512)
        self.assertEqual(device.buffer_frames, 256)


class LayerClaimTests(unittest.TestCase):
    def test_claims_are_layer_specific(self):
        self.assertEqual(model.acoustic_claim_for("5.1_side", 6), "5.1_side")
        self.assertEqual(model.acoustic_claim_for("7.1", 8), "7.1")
        self.assertEqual(model.acoustic_claim_for("5.1_side", 2), "stereo_downmix")
        self.assertEqual(model.acoustic_claim_for("7.1", 2), "stereo_downmix")
        with self.assertRaises(model.RejectError) as context:
            model.validate_acoustic_claim("5.1_side", 2)
        self.assertEqual(context.exception.code, "acoustic_endpoints_insufficient")
        with self.assertRaises(model.RejectError) as context:
            model.validate_acoustic_claim("5.1_side", 6)
        self.assertEqual(context.exception.code, "acoustic_not_measured")
        model.validate_acoustic_claim("5.1_side", 6, measured=True)

    def test_false_native_descriptor_and_capture_rejected(self):
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
        capture = model.plan_capture("stereo", "5.1_side")
        capture.native_claim = True
        with self.assertRaises(model.RejectError) as context:
            model.validate_capture_claims(capture)
        self.assertEqual(context.exception.code, "false_native_claim")
        refused = model.plan_capture("7.1", "5.1_side")
        model.validate_capture_claims(refused)
        self.assertEqual(refused.kind, "refused")


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
            self.assertEqual(manifest["contract"], "MULTICHANNEL_CONTRACT.md v1")
            for layout, info in manifest["sources"].items():
                data = wav.read_wav(root / fixtures.SOURCE_FILES[layout])
                self.assertEqual(data.channels, model.channel_count_for(layout))
                self.assertEqual(data.mask, model.mask_for(layout))
                self.assertEqual(list(model.channel_order(layout)),
                                 list(model.labels_for(layout)))
                self.assertEqual(len(data.samples), data.channels)
            mono = wav.read_wav(root / fixtures.SOURCE_FILES["mono"])
            self.assertEqual(mono.channels, 1)
            self.assertEqual(model.layout_from_mask(mono.mask, 1), "mono")
            self.assertEqual(model.labels_for("mono"), ("M",))

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
            self.assertEqual(passed["channel_order"],
                             ["FL", "FR", "FC", "LFE", "SL", "SR"])

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
