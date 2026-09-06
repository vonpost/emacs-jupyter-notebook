"""Validate EJNARR01 without NumPy, Qt, or executable serialization.

All parsing is bounded before payload allocation. Callers supply an already
confined, pinned binary file; this module does not grant filesystem authority.
"""

from __future__ import annotations

import json
import math
import re
import struct
from typing import BinaryIO

MIME = "application/x-ejn-array-group"
MAGIC = b"EJNARR01"
MAX_GROUP_BYTES = 67_108_864
MAX_PLANE_BYTES = 33_554_432
MAX_HEADER_BYTES = 16_384
MAX_DIMENSION = 16_384
MAX_MEMBERS = 4
DTYPES = {"|u1": 1, "|i1": 1,
          **{endian + kind: size for endian in "<>"
             for kind, size in (("u2", 2), ("i2", 2), ("u4", 4), ("i4", 4),
                                ("f4", 4), ("f8", 8))}}
_HEADER_FIELDS = {"v", "key", "sample_id", "publication_id", "planes"}
_PLANE_REQUIRED = {"id", "name", "shape", "dtype", "offset", "nbytes"}
_SPATIAL = {"spacing", "origin", "direction", "spatial_units"}
_PLANE_OPTIONAL = {"grid_id", "units"} | _SPATIAL


class ArrayFormatError(ValueError):
    """Malformed or over-budget numerical data; safe bounded diagnostic."""


def _fail(message: str):
    raise ArrayFormatError(message)


def _text(value, name: str, *, nonempty=True):
    if not isinstance(value, str) or (nonempty and not value):
        _fail(f"invalid {name}")
    # Character count bounds encoding work, including malformed surrogates.
    if len(value) > 128 or any(not char.isprintable() for char in value):
        _fail(f"invalid {name}")
    try:
        if len(value.encode("utf-8")) > 128:
            _fail(f"invalid {name}")
    except UnicodeError:
        _fail(f"invalid {name}")


def _integer(value, lower: int, upper: int, name: str):
    if type(value) is not int or not lower <= value <= upper:
        _fail(f"invalid {name}")


def _numbers(value, length: int, name: str):
    if not isinstance(value, list) or len(value) != length:
        _fail(f"invalid {name}")
    for number in value:
        if type(number) not in (int, float):
            _fail(f"invalid {name}")
        try:
            if not math.isfinite(number):
                _fail(f"invalid {name}")
        except OverflowError:
            _fail(f"invalid {name}")


def validate_header(header: object, header_bytes: int, file_bytes: int) -> dict:
    """Return HEADER after strict shape, allocation, and aggregate checks."""
    _integer(header_bytes, 1, MAX_HEADER_BYTES, "header size")
    _integer(file_bytes, 13, MAX_GROUP_BYTES, "group size")
    if not isinstance(header, dict) or set(header) != _HEADER_FIELDS:
        _fail("invalid header fields")
    if type(header["v"]) is not int or header["v"] != 1:
        _fail("unsupported content version")
    _text(header["key"], "key")
    _text(header["sample_id"], "sample id")
    publication = header["publication_id"]
    if not isinstance(publication, str) or not re.fullmatch("[0-9a-f]{32}", publication):
        _fail("invalid publication id")
    planes = header["planes"]
    if not isinstance(planes, list) or not 1 <= len(planes) <= MAX_MEMBERS:
        _fail("invalid plane count")
    offset = 0
    ids, names = set(), set()
    for plane in planes:
        if (not isinstance(plane, dict) or not _PLANE_REQUIRED <= set(plane)
                or set(plane) - _PLANE_REQUIRED - _PLANE_OPTIONAL):
            _fail("invalid plane fields")
        for field in ("id", "name"):
            _text(plane[field], field)
        if plane["id"] in ids or plane["name"] in names:
            _fail("duplicate plane identity")
        ids.add(plane["id"])
        names.add(plane["name"])
        shape = plane["shape"]
        if not isinstance(shape, list) or len(shape) != 2:
            _fail("invalid plane shape")
        for dimension in shape:
            _integer(dimension, 1, MAX_DIMENSION, "dimension")
        dtype = plane["dtype"]
        if not isinstance(dtype, str) or dtype not in DTYPES:
            _fail("unsupported dtype")
        expected = shape[0] * shape[1] * DTYPES[dtype]
        _integer(plane["nbytes"], 1, MAX_PLANE_BYTES, "plane size")
        _integer(plane["offset"], 0, MAX_GROUP_BYTES, "plane offset")
        if plane["nbytes"] != expected or plane["offset"] != offset:
            _fail("inconsistent plane layout")
        offset += expected
        for field in ("grid_id", "units"):
            if field in plane:
                _text(plane[field], field, nonempty=False)
        spatial = set(plane) & _SPATIAL
        if spatial and spatial != _SPATIAL:
            _fail("incomplete spatial metadata")
        if spatial:
            _text(plane["spatial_units"], "spatial units")
            _numbers(plane["spacing"], 2, "spacing")
            if any(value <= 0 for value in plane["spacing"]):
                _fail("invalid spacing")
            _numbers(plane["origin"], 2, "origin")
            _numbers(plane["direction"], 4, "direction")
            a, b, c, d = plane["direction"]
            try:
                determinant = a * d - b * c
                if not math.isfinite(determinant) or determinant == 0:
                    _fail("singular direction")
            except OverflowError:
                _fail("invalid direction")
    if 12 + header_bytes + offset != file_bytes:
        _fail("group length mismatch")
    return header


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate JSON key")
        result[key] = value
    return result


def read_manifest(stream: BinaryIO, file_bytes: int) -> tuple[dict, int]:
    """Read only the bounded header from pinned STREAM; return it and data offset.

    FILE_BYTES must come from fstat of that file descriptor. The caller retains
    ownership and is responsible for rejecting concurrent file mutation.
    """
    _integer(file_bytes, 13, MAX_GROUP_BYTES, "group size")
    prefix = stream.read(12)
    if len(prefix) != 12 or prefix[:8] != MAGIC:
        _fail("invalid group prefix")
    length = struct.unpack(">I", prefix[8:])[0]
    _integer(length, 1, MAX_HEADER_BYTES, "header size")
    if 12 + length > file_bytes:
        _fail("truncated header")
    encoded = stream.read(length)
    if len(encoded) != length:
        _fail("truncated header")
    try:
        header = json.loads(encoded.decode("utf-8"), object_pairs_hook=_unique_object,
                            parse_constant=lambda _: _fail("non-finite JSON value"))
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise ArrayFormatError("invalid header JSON") from exc
    return validate_header(header, length, file_bytes), 12 + length
