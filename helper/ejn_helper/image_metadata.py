"""Bounded compressed-image metadata parsing for thumbnail prefiltering.

This module understands only the small fixed headers needed to reject an
obviously malformed, MIME-confused, or oversized PNG/JPEG before starting the
thumbnail worker.  It is *not* a decoder and never grants an original image
permission to reach an Emacs image API.
"""

from __future__ import annotations

from dataclasses import dataclass
from os import PathLike
import zlib

EJN_IMAGE_HEADER_SCAN_BYTES = 65_536
EJN_MAX_IMAGE_WIDTH = 16_384
EJN_MAX_IMAGE_HEIGHT = 16_384
EJN_MAX_IMAGE_PIXELS = 4_194_304

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_JPEG_STANDALONE_MARKERS = frozenset(
    (0x01, 0xD8, 0xD9, *range(0xD0, 0xD8))
)
_JPEG_SOF_MARKERS = frozenset(
    (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF)
)


@dataclass(frozen=True, slots=True)
class ImageMetadata:
    """Header MIME and dimensions accepted by the worker prefilter."""

    mime: str
    width: int
    height: int


def _u16(data: bytes, offset: int) -> int:
    return (data[offset] << 8) | data[offset + 1]


def _u32(data: bytes, offset: int) -> int:
    return (
        (data[offset] << 24)
        | (data[offset + 1] << 16)
        | (data[offset + 2] << 8)
        | data[offset + 3]
    )


def _within_source_limit(width: int, height: int) -> bool:
    return (
        0 < width <= EJN_MAX_IMAGE_WIDTH
        and 0 < height <= EJN_MAX_IMAGE_HEIGHT
        and width * height <= EJN_MAX_IMAGE_PIXELS
    )


def _metadata(mime: str, width: int, height: int) -> ImageMetadata | None:
    if not _within_source_limit(width, height):
        return None
    return ImageMetadata(mime, width, height)


def _parse_png(data: bytes) -> ImageMetadata | None:
    # PNG requires IHDR to be its first chunk.  Validate its CRC as well as the
    # fixed fields so a corrupted prefix cannot receive an inline-safe label.
    if (
        len(data) < 33
        or data[:8] != _PNG_SIGNATURE
        or _u32(data, 8) != 13
        or data[12:16] != b"IHDR"
    ):
        return None
    if _u32(data, 29) != (zlib.crc32(data[12:29]) & 0xFFFFFFFF):
        return None
    width = _u32(data, 16)
    height = _u32(data, 20)
    # Colour type, compression, filter, and interlace must have values from
    # PNG's fixed IHDR domain.  This is not a decoder; it just prevents a
    # malformed prefix from receiving an inline-safe label.
    bit_depth = data[24]
    colour_type = data[25]
    compression = data[26]
    filter_method = data[27]
    interlace = data[28]
    allowed_depths = {
        0: (1, 2, 4, 8, 16),
        2: (8, 16),
        3: (1, 2, 4, 8),
        4: (8, 16),
        6: (8, 16),
    }
    if (
        bit_depth not in allowed_depths.get(colour_type, ())
        or compression != 0
        or filter_method != 0
        or interlace not in (0, 1)
    ):
        return None
    return _metadata("image/png", width, height)


def _parse_jpeg(data: bytes) -> ImageMetadata | None:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    position = 2
    limit = len(data)
    while position < limit:
        # Outside entropy-coded scan data every marker begins with 0xff.
        if data[position] != 0xFF:
            return None
        while position < limit and data[position] == 0xFF:
            position += 1
        if position >= limit:
            return None
        marker = data[position]
        position += 1
        if marker == 0x00:
            return None
        if marker in _JPEG_STANDALONE_MARKERS:
            # Neither a completed image nor scan data before a frame header
            # yields trustworthy dimensions.
            if marker in (0xD8, 0xD9):
                return None
            continue
        if marker == 0xDA:  # SOS: dimensions must have appeared before this.
            return None
        if position + 2 > limit:
            return None
        length = _u16(data, position)
        if length < 2:
            return None
        end = position + length
        if end > limit:
            return None
        if marker in _JPEG_SOF_MARKERS:
            if length < 8:
                return None
            precision = data[position + 2]
            height = _u16(data, position + 3)
            width = _u16(data, position + 5)
            components = data[position + 7]
            if (
                precision == 0
                or components == 0
                or length < 8 + (3 * components)
            ):
                return None
            return _metadata("image/jpeg", width, height)
        position = end
    return None


def parse_image_metadata(data: bytes) -> ImageMetadata | None:
    """Parse PNG IHDR or JPEG SOF dimensions from one bounded byte prefix.

    Callers supply at most :data:`EJN_IMAGE_HEADER_SCAN_BYTES`; accepting a
    larger caller buffer would make this low-level API accidentally unbounded.
    """
    if not isinstance(data, bytes) or len(data) > EJN_IMAGE_HEADER_SCAN_BYTES:
        return None
    if data.startswith(_PNG_SIGNATURE):
        return _parse_png(data)
    if data.startswith(b"\xff\xd8"):
        return _parse_jpeg(data)
    return None


def read_image_metadata(path: str | PathLike[str]) -> ImageMetadata | None:
    """Read exactly one fixed prefix from PATH and parse image dimensions."""
    try:
        with open(path, "rb") as stream:
            return parse_image_metadata(stream.read(EJN_IMAGE_HEADER_SCAN_BYTES))
    except OSError:
        return None
