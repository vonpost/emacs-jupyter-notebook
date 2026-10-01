import copy
import io
import json
from pathlib import Path
import struct
import unittest

from ejn_array import ArrayFormatError, MAX_GROUP_BYTES, read_manifest, validate_header

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

    def test_volume_layout_and_float16_both_endians(self):
        for dtype in ("<f2", ">f2"):
            header = json.loads(self.vectors["valid"][0]["header_json"])
            header["planes"][0].update(shape=[2, 1, 3], dtype=dtype)
            encoded = json.dumps(header).encode()
            samples = struct.pack(dtype[0] + "6e", -1.5, 0, 0.25, 1, 12, 65504)
            raw = b"EJNARR01" + struct.pack(">I", len(encoded)) + encoded + samples
            parsed, offset = read_manifest(io.BytesIO(raw), len(raw))
            self.assertEqual(parsed["planes"][0]["shape"], [2, 1, 3])
            self.assertEqual(raw[offset:], samples)

    def test_volume_checks_every_dimension_product_and_spatial_contract(self):
        original = json.loads(self.vectors["valid"][0]["header_json"])
        cases = [
            {"shape": [2, 3, 2]},  # Includes the third axis in byte counts.
            {"shape": [2, 3, 0]}, {"shape": [2, 3, True]},
            {"shape": [2, 3, 16385]}, {"shape": [2, 3, 1, 1]},
            {"shape": [256, 256, 512], "nbytes": 67_108_864},
            {"shape": [2, 3, 1], "spacing": [1, 1], "origin": [0, 0],
             "direction": [1, 0, 0, 1], "spatial_units": "mm"},
        ]
        for changes in cases:
            header = copy.deepcopy(original)
            header["planes"][0].update(changes)
            encoded = json.dumps(header).encode()
            with self.subTest(changes=changes), self.assertRaises(ArrayFormatError):
                validate_header(header, len(encoded), 12 + len(encoded) + 12)

    def test_rank_specific_spatial_metadata(self):
        for shape, spacing, origin, direction in (
            ([2, 3], [0.2, 0.1], [4, -2], [1, 0, 0, 1]),
            ([2, 3, 1], [0.2, 0.1, 0.5], [4, -2, 10], [1, 0, 0, 0, 1, 0, 0, 0, 1]),
            ([2, 3, 1], [0.2, 0.1, 0.5], [4, -2, 10], [0, -1, 0, 1, 0, 0, 0, 0, 1]),
        ):
            header = json.loads(self.vectors["valid"][0]["header_json"])
            header["planes"][0].update(shape=shape, spacing=spacing, origin=origin,
                                        direction=direction, spatial_units="mm")
            encoded = json.dumps(header).encode()
            with self.subTest(shape=shape, direction=direction):
                self.assertIs(validate_header(header, len(encoded), 12 + len(encoded) + 12), header)

    def test_volume_spatial_metadata_is_complete_finite_and_nonsingular(self):
        original = json.loads(self.vectors["valid"][0]["header_json"])
        original["planes"][0].update(
            shape=[2, 3, 1], spacing=[0.2, 0.1, 0.5], origin=[0, 0, 0],
            direction=[1, 0, 0, 0, 1, 0, 0, 0, 1], spatial_units="mm")
        cases = [
            {"spacing": [1, 1]}, {"spacing": [1, 0, 1]}, {"spacing": [1, -1, 1]},
            {"spacing": [1, float("inf"), 1]}, {"spacing": [1, True, 1]},
            {"origin": [0, 0]}, {"origin": [0, float("nan"), 0]},
            {"direction": [1, 0, 0, 1]}, {"direction": [1] * 9},
            {"direction": [1, 0, 0, 0, 1, 0, 0, 0, float("inf")]},
            {"spatial_units": ""},
        ]
        for changes in cases:
            header = copy.deepcopy(original)
            header["planes"][0].update(changes)
            encoded = json.dumps(header).encode()
            with self.subTest(changes=changes), self.assertRaises(ArrayFormatError):
                validate_header(header, len(encoded), 12 + len(encoded) + 12)


if __name__ == "__main__":
    unittest.main()
