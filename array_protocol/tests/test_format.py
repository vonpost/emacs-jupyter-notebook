import copy
import io
import json
from pathlib import Path
import struct
import unittest

from ejn_array import ArrayFormatError, MAX_GROUP_BYTES, read_manifest

FIXTURES = Path(__file__).resolve().parents[2] / "tests/fixtures/viewer-contract-v1.json"


def materialize(vector):
    header = vector["header_json"].encode("utf-8")
    return b"EJNARR01" + struct.pack(">I", len(header)) + header + bytes.fromhex(vector["raw_hex"])


class FormatTests(unittest.TestCase):
    def setUp(self):
        self.vectors = json.loads(FIXTURES.read_text())

    def test_independent_golden_vectors(self):
        for vector in self.vectors["valid"]:
            with self.subTest(vector=vector["name"]):
                raw = materialize(vector)
                header, offset = read_manifest(io.BytesIO(raw), len(raw))
                fmt = "<6H" if header["planes"][0]["dtype"] == "<u2" else ">6h"
                self.assertEqual(list(struct.unpack(fmt, raw[offset:])), vector["values"])

    def test_rejection_vectors(self):
        for vector in self.vectors["rejections"]:
            with self.subTest(vector=vector["name"]):
                raw = materialize(vector)
                with self.assertRaises(ArrayFormatError):
                    read_manifest(io.BytesIO(raw), len(raw))

    def test_reject_before_reading_over_budget_file_or_header(self):
        class Unreadable:
            def read(self, _):
                raise AssertionError("read before size check")
        with self.assertRaises(ArrayFormatError):
            read_manifest(Unreadable(), MAX_GROUP_BYTES + 1)
        raw = b"EJNARR01" + struct.pack(">I", 16385)
        with self.assertRaises(ArrayFormatError):
            read_manifest(io.BytesIO(raw), 50000)

    def test_strict_shape_identity_and_spatial_metadata(self):
        original = json.loads(self.vectors["valid"][0]["header_json"])
        modifications = [
            ("shape", [True, 3]), ("shape", [1, 16385]), ("offset", False),
            ("nbytes", True), ("dtype", "O"), ("units", "x\x00y"),
            ("units", "\ud800"), ("spacing", [1, 1]), ("extra", 1),
        ]
        for field, value in modifications:
            header = copy.deepcopy(original)
            header["planes"][0][field] = value
            encoded = json.dumps(header).encode()
            raw = b"EJNARR01" + struct.pack(">I", len(encoded)) + encoded + b"\x00" * 12
            with self.subTest(field=field, value=value), self.assertRaises(ArrayFormatError):
                read_manifest(io.BytesIO(raw), len(raw))


if __name__ == "__main__":
    unittest.main()
