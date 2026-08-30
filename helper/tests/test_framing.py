"""Focused tests for the pure HT3 framing codec."""

import json
import random
import struct
import unittest
from pathlib import Path

from ejn_helper.framing import Decoder, FrameCodecError, encode

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "fixtures" / "helper-protocol-v1.json"


def canonical_payload(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def fixture_wire(vector):
    if vector["kind"] == "raw-error":
        return bytes.fromhex(vector["raw_hex"])
    obj = vector.get("object")
    if vector["kind"] in {"recipe", "recipe-error"}:
        obj = json.loads(json.dumps(vector["template"]))
        key = "result" if obj["kind"] == "response" else "params"
        empty = json.loads(json.dumps(obj))
        empty[key][vector["field"]] = ""
        length = vector["target_frame_length"] - 4 - len(canonical_payload(empty))
        obj[key][vector["field"]] = "a" * length
    payload = canonical_payload(obj)
    return struct.pack(">I", len(payload)) + payload


def fixture_object(vector):
    if vector["kind"] == "frame":
        return json.loads(json.dumps(vector["object"]))
    obj = json.loads(json.dumps(vector["template"]))
    key = "result" if obj["kind"] == "response" else "params"
    empty = json.loads(json.dumps(obj))
    empty[key][vector["field"]] = ""
    obj[key][vector["field"]] = "a" * (vector["target_frame_length"] - 4 - len(canonical_payload(empty)))
    return obj


def random_chunks(data):
    rng = random.Random(1729)
    chunks = []
    offset = 0
    while offset < len(data):
        width = min(len(data) - offset, rng.randint(1, 23))
        chunks.append(data[offset:offset + width])
        offset += width
    return chunks


class FramingTests(unittest.TestCase):
    def test_all_golden_vectors_with_exact_bytes(self):
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        for vector in fixture["vectors"]:
            wire = fixture_wire(vector)
            if vector["kind"] == "raw-error":
                decoder = Decoder(fixture["limits"]["max_to_helper_frame"])
                if vector.get("outcome") == "partial-frame-timeout":
                    decoder.feed(wire)
                    with self.assertRaises(FrameCodecError) as error:
                        decoder.partial_frame_expired()
                    self.assertEqual(error.exception.code, vector["error"]["code"])
                elif vector["error"]["code"] == "protocol-error":
                    with self.assertRaises(FrameCodecError) as error:
                        decoder.feed(wire)
                    self.assertEqual(error.exception.code, vector["error"]["code"])
                    self.assertTrue(decoder.failed)
                else:
                    # Envelope semantic errors belong to the later dispatcher;
                    # framing must preserve a valid JSON object for it.
                    self.assertEqual(len(decoder.feed(wire)), 1)
                self.assertEqual(decoder.buffered_bytes, 0)
                continue
            if "declared_payload_length" in vector:
                self.assertEqual(int.from_bytes(wire[:4], "big"), vector["declared_payload_length"])
                self.assertEqual(wire[:4].hex(), vector["prefix_hex"])
            ceiling = fixture["limits"]["max_response_frame"] if vector.get("direction") == "response" else (fixture["limits"]["max_to_emacs_frame"] if vector.get("direction", "to-emacs") == "to-emacs" else fixture["limits"]["max_to_helper_frame"])
            decoder = Decoder(ceiling)
            if vector["kind"] == "recipe-error":
                with self.assertRaises(FrameCodecError) as error:
                    decoder.feed(wire[:4])
                self.assertEqual(error.exception.code, vector["error"]["code"])
                self.assertTrue(decoder.failed)
                self.assertEqual(decoder.buffered_bytes, 0)
                continue
            decoded = []
            for byte in wire:
                decoded.extend(decoder.feed(bytes([byte])))
            self.assertEqual(decoded, [fixture_object(vector)])
            if "expected_payload_length" in vector:
                self.assertEqual(len(wire) - 4, vector["expected_payload_length"])
                self.assertEqual(wire[:4].hex(), vector["expected_prefix_hex"])
            random_decoder = Decoder(ceiling)
            random_decoded = []
            for chunk in random_chunks(wire):
                random_decoded.extend(random_decoder.feed(chunk))
            self.assertEqual(random_decoded, [fixture_object(vector)])

    def test_exact_encode_and_decode_boundaries(self):
        for size in (12, 64):
            obj = {"x": "a" * (size - 12)}
            wire = encode(obj, size)
            self.assertEqual(len(wire), size)
            self.assertEqual(Decoder(size).feed(wire), [obj])
            with self.assertRaises(FrameCodecError) as error:
                encode({"x": "a" * (size - 11)}, size)
            self.assertEqual(error.exception.code, "frame-too-large")

    def test_fragmented_timeout_and_failed_state(self):
        wire = encode({"ok": True}, 100)
        decoder = Decoder(100)
        decoder.feed(wire[:3])
        self.assertTrue(decoder.partial_frame)
        decoder.feed(wire[3:5])
        with self.assertRaises(FrameCodecError):
            decoder.partial_frame_expired()
        self.assertEqual(decoder.buffered_bytes, 0)
        with self.assertRaises(FrameCodecError):
            decoder.feed(wire)

    def test_preflight_accumulator_and_bad_inputs(self):
        decoder = Decoder(100, accumulator_limit=100)
        with self.assertRaises(FrameCodecError):
            decoder.feed(b"x" * 101)
        self.assertEqual(decoder.buffered_bytes, 0)
        for raw in (b"\x00\x00\x00\x01\xc3", b"\x00\x00\x00\x01\x7b", b"\x00\x00\x00\x01\x31"):
            decoder = Decoder(100)
            with self.assertRaises(FrameCodecError):
                decoder.feed(raw)
            self.assertTrue(decoder.failed)
            self.assertEqual(decoder.buffered_bytes, 0)
        for value in ("NaN", "Infinity", "-Infinity"):
            raw_payload = ("{" + '"x":' + value + "}").encode("ascii")
            raw = struct.pack(">I", len(raw_payload)) + raw_payload
            decoder = Decoder(100)
            with self.assertRaises(FrameCodecError):
                decoder.feed(raw)
            self.assertTrue(decoder.failed)
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.assertRaises(FrameCodecError):
                encode({"x": value}, 100)
        with self.assertRaises(TypeError):
            Decoder(100).feed(bytearray())

    def test_multiple_frames_and_constructor_limits(self):
        first = encode({"n": 1}, 100)
        second = encode({"n": 2}, 100)
        self.assertEqual(Decoder(100).feed(first + second), [{"n": 1}, {"n": 2}])
        with self.assertRaises(ValueError): Decoder(4)
        with self.assertRaises(ValueError): Decoder(100, accumulator_limit=99)
        with self.assertRaises(ValueError): encode({}, 4)


if __name__ == "__main__":
    unittest.main()
