"""Executable v1 header/status/export gates. No audio or network operations."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
FROZEN=ROOT/"docs/api/v1"
MANIFEST=json.loads((FROZEN/"manifest.json").read_text(encoding="utf-8"))
EXPECTED_HEADERS={
    "bridge.h":"3448489856d8b8ebbc9a8147fac56de3531313ff2cc8c9c9757c7c4af61618df",
    "core.hpp":"cc80791029982e4fd0d3cd920b7f1bcf50cdb4d63542035209b1e12354fac64c",
}


class ApiFreezeTests(unittest.TestCase):
    def test_frozen_and_live_headers_match_original_hashes(self):
        self.assertEqual(len(MANIFEST["snapshot_headers"]),2)
        for item in MANIFEST["snapshot_headers"]:
            with self.subTest(header=item["snapshot"]):
                expected=EXPECTED_HEADERS[item["snapshot"]]
                self.assertEqual(item["sha256"],expected)
                for path in [FROZEN/item["snapshot"],ROOT/item["source"]]:
                    data=path.read_bytes()
                    self.assertEqual(len(data),item["bytes"])
                    self.assertEqual(hashlib.sha256(data).hexdigest(),expected)

    def test_fixed_status_codes_and_declared_signatures(self):
        header=(FROZEN/"bridge.h").read_text(encoding="utf-8")
        codes=dict((name,int(value)) for name,value in re.findall(r"\b(FLOW_V1_[A-Z_]+)\s*=\s*(\d+)",header))
        self.assertEqual(codes,MANIFEST["status_codes"])
        self.assertEqual(list(codes.values()),list(range(9)))
        normalized=" ".join(header.split())
        self.assertEqual(len(MANIFEST["symbols"]),9)
        for symbol in MANIFEST["symbols"]:
            self.assertIn(" ".join(symbol["declaration"].split()),normalized)
        from bindings.python import flow_core
        for name,code in codes.items():self.assertEqual(getattr(flow_core,name.removeprefix("FLOW_V1_")),code)

    def test_all_frozen_symbols_exported_by_actual_library(self):
        path=os.environ.get("FLOW_CORE_LIBRARY")
        self.assertTrue(path,"FLOW_CORE_LIBRARY required; no mock library or implicit skip")
        lib=ctypes.CDLL(str(Path(path).resolve(strict=True)))
        for symbol in MANIFEST["symbols"]:self.assertTrue(hasattr(lib,symbol["name"]))
        lib.flow_v1_abi_version.restype=ctypes.c_uint32
        self.assertEqual(lib.flow_v1_abi_version(),1)


if __name__=="__main__":unittest.main(verbosity=2)
