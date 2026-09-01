"""Bounded PNG/JPEG header parsing tests for helper image admission."""

from __future__ import annotations

import tempfile
import unittest
import zlib
from pathlib import Path

from ejn_helper.image_metadata import (
    EJN_IMAGE_HEADER_SCAN_BYTES,
    EJN_MAX_IMAGE_HEIGHT,
    EJN_MAX_IMAGE_PIXELS,
    EJN_MAX_IMAGE_WIDTH,
    parse_image_metadata,
    read_image_metadata,
)


def png(width: int, height: int, *, ihdr_length: int = 13) -> bytes:
    """Return the fixed prefix of a PNG with controlled IHDR dimensions."""
    ihdr = (
        b"IHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + b"\x08\x02\x00\x00\x00"
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + ihdr_length.to_bytes(4, "big")
        + ihdr
        + zlib.crc32(ihdr).to_bytes(4, "big")
    )


def jpeg(width: int, height: int, *, before: bytes = b"") -> bytes:
    """Return a minimal baseline JPEG header with one colour component."""
    sof = (
        b"\xff\xc0\x00\x0b\x08"
        + height.to_bytes(2, "big")
        + width.to_bytes(2, "big")
        + b"\x01\x01\x11\x00"
    )
    return b"\xff\xd8" + before + sof + b"\xff\xd9"


class ImageMetadataTests(unittest.TestCase):
    def assert_metadata(self, payload: bytes, mime: str, width: int, height: int) -> None:
        value = parse_image_metadata(payload)
        self.assertIsNotNone(value)
        assert value is not None
        self.assertEqual(value.mime, mime)
        self.assertEqual((value.width, value.height), (width, height))

    def test_png_exact_dimension_and_pixel_boundaries(self) -> None:
        self.assert_metadata(png(2048, 2048), "image/png", 2048, 2048)
        self.assertIsNone(parse_image_metadata(png(2049, 2048)))
        self.assert_metadata(
            png(EJN_MAX_IMAGE_WIDTH, 1),
            "image/png",
            EJN_MAX_IMAGE_WIDTH,
            1,
        )
        self.assertIsNone(
            parse_image_metadata(
                png(EJN_MAX_IMAGE_WIDTH + 1, 1)
            )
        )
        self.assert_metadata(
            png(1, EJN_MAX_IMAGE_HEIGHT),
            "image/png",
            1,
            EJN_MAX_IMAGE_HEIGHT,
        )
        self.assertIsNone(
            parse_image_metadata(png(1, EJN_MAX_IMAGE_HEIGHT + 1))
        )
        self.assertEqual(EJN_MAX_IMAGE_PIXELS, 4_194_304)

    def test_png_requires_exact_first_ihdr_and_nonzero_dimensions(self) -> None:
        complete = png(1, 1)
        for end in range(len(complete)):
            self.assertIsNone(parse_image_metadata(complete[:end]), end)
        for length in (0, 12, 14, 0xFFFFFFFF):
            self.assertIsNone(parse_image_metadata(png(1, 1, ihdr_length=length)))
        wrong_first_chunk = bytearray(complete)
        wrong_first_chunk[12:16] = b"IDAT"
        self.assertIsNone(parse_image_metadata(bytes(wrong_first_chunk)))
        self.assertIsNone(parse_image_metadata(b"x" + complete))
        self.assertIsNone(parse_image_metadata(png(0, 1)))
        self.assertIsNone(parse_image_metadata(png(1, 0)))
        self.assertIsNone(parse_image_metadata(png(0xFFFFFFFF, 1)))

    def test_png_rejects_bad_crc_and_invalid_ihdr_domain(self) -> None:
        bad_crc = bytearray(png(2, 3))
        bad_crc[-1] ^= 1
        self.assertIsNone(parse_image_metadata(bytes(bad_crc)))
        for offset, value in ((24, 3), (25, 5), (26, 1), (27, 1), (28, 2)):
            bad_domain = bytearray(png(2, 3))
            bad_domain[offset] = value
            bad_domain[-4:] = zlib.crc32(bad_domain[12:29]).to_bytes(4, "big")
            self.assertIsNone(parse_image_metadata(bytes(bad_domain)))

    def test_jpeg_exact_boundaries_and_marker_forms(self) -> None:
        self.assert_metadata(jpeg(2048, 2048), "image/jpeg", 2048, 2048)
        self.assertIsNone(parse_image_metadata(jpeg(2049, 2048)))
        self.assert_metadata(
            jpeg(EJN_MAX_IMAGE_WIDTH, 1),
            "image/jpeg",
            EJN_MAX_IMAGE_WIDTH,
            1,
        )
        self.assertIsNone(
            parse_image_metadata(jpeg(EJN_MAX_IMAGE_WIDTH + 1, 1))
        )
        self.assert_metadata(
            jpeg(1, EJN_MAX_IMAGE_HEIGHT),
            "image/jpeg",
            1,
            EJN_MAX_IMAGE_HEIGHT,
        )
        self.assertIsNone(
            parse_image_metadata(jpeg(1, EJN_MAX_IMAGE_HEIGHT + 1))
        )
        # TEM and restart markers have no segment length.  Fill bytes before
        # a marker are valid JPEG framing and must not change its position.
        before = b"\xff\xe0\x00\x03\x00\xff\x01\xff\xff\xd0"
        self.assert_metadata(jpeg(3, 2, before=before), "image/jpeg", 3, 2)

    def test_jpeg_rejects_malformed_and_pre_sof_markers(self) -> None:
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\x00"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\xe0\x00\x00"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\xe0\x00\x01"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\xe0\xff\xff"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8x"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\xda\x00\x08"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff\xd9"))
        self.assertIsNone(parse_image_metadata(b"\xff\xd8\xff"))
        self.assertIsNone(parse_image_metadata(jpeg(0, 1)))
        self.assertIsNone(parse_image_metadata(jpeg(1, 0)))
        zero_components = bytearray(jpeg(1, 1))
        zero_components[11] = 0
        self.assertIsNone(parse_image_metadata(bytes(zero_components)))
        truncated_sof = jpeg(1, 1)[:11]
        self.assertIsNone(parse_image_metadata(truncated_sof))

    def test_parser_rejects_oversized_caller_prefix(self) -> None:
        self.assertIsNone(
            parse_image_metadata(b"\xff\xd8" + b"\xff" * EJN_IMAGE_HEADER_SCAN_BYTES)
        )

    def test_reader_never_scans_past_fixed_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "storm.jpg"
            # The SOF is valid but lies strictly beyond the fixed parser read.
            storm = b"\xff\xd8" + b"\xff" * EJN_IMAGE_HEADER_SCAN_BYTES
            path.write_bytes(storm + jpeg(5, 5)[2:])
            self.assertIsNone(read_image_metadata(path))

    def test_reader_accepts_sof_ending_at_prefix_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "boundary.jpg"
            tail = jpeg(7, 3)[2:]
            remaining = EJN_IMAGE_HEADER_SCAN_BYTES - 2 - len(tail)
            # A 5-byte APP segment makes the otherwise odd filler exact;
            # remaining TEM markers are standalone and need no length field.
            prefix = b"\xff\xd8\xff\xe0\x00\x03\x00" + b"\xff\x01" * (
                (remaining - 5) // 2
            )
            payload = prefix + jpeg(7, 3)[2:]
            self.assertEqual(len(payload), EJN_IMAGE_HEADER_SCAN_BYTES)
            path.write_bytes(payload)
            value = read_image_metadata(path)
            self.assertIsNotNone(value)
            assert value is not None
            self.assertEqual((value.width, value.height), (7, 3))
