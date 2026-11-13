import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("update_publish", ROOT/"tools/updates/publish.py")
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)

class UpdatePublishTests(unittest.TestCase):
    def test_prepares_signed_feed_and_website_pointer_from_same_package(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            key = Ed25519PrivateKey.generate()
            keyfile = root/"private.pem"
            keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                 serialization.NoEncryption()))
            package = root/"input.pkg"
            package.write_bytes(b"test-package")
            output = root/"site"
            payload = publish.prepare(package, None, "0.3.3", 4, "https://example.test", keyfile, output, "中文")
            envelope = json.loads((output/"updates/latest.json").read_bytes())
            raw = base64.b64decode(envelope["payload"])
            key.public_key().verify(base64.b64decode(envelope["signature"]), raw)
            self.assertEqual(json.loads(raw), payload)
            website = json.loads((output/"release.json").read_bytes())
            self.assertEqual(website["sha256"], payload["sha256"])
            self.assertEqual((output/"downloads"/website["file"]).read_bytes(), package.read_bytes())
            self.assertFalse(any(p.name == "private.pem" for p in output.rglob("*")))

    def test_invalid_publication_arguments_are_rejected_before_copy(self):
        for version, base in [("$(touch bad)", "https://example.test"), ("0.3.3", "http://example.test")]:
            with self.assertRaises(ValueError):
                publish.prepare(Path("missing"), None, version, 4, base, Path("missing-key"), Path("missing-dir"), "")

if __name__ == "__main__":
    unittest.main()
