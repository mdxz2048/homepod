"""Offline preservation checks. Never invoke discover, run, or main."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrototypePreservation(unittest.TestCase):
    def test_original_files_unchanged(self):
        baseline = json.loads((ROOT / "docs/collaboration/baselines/M0-original-source.json").read_text(encoding="utf-8"))
        for name, expected in baseline["files"].items():
            with self.subTest(file=name):
                content = (ROOT / name).read_bytes()
                self.assertEqual(len(content), expected["bytes"])
                self.assertEqual(hashlib.sha256(content).hexdigest(), expected["sha256"])

    def test_python_syntax_without_execution(self):
        for path in ROOT.glob("*.py"):
            with self.subTest(file=path.name):
                ast.parse(path.read_text(encoding="utf-8-sig"), filename=str(path))

    def test_sender_and_codec_import_without_playback(self):
        # These two modules have no top-level discovery/playback. The sender's
        # main is guarded; import does not call async run or connect a speaker.
        for name in ("sync_probe", "alac_adapter"):
            with self.subTest(module=name):
                spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                self.assertTrue(callable(getattr(module, "run" if name == "sync_probe" else "verbatim_alac")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
