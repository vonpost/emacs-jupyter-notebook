"""Self-contained EJN numerical-group publisher; importing never installs it."""

import base64
import json
import uuid
from collections.abc import Mapping
from itertools import islice

_MARKER = "ejn-array-group-v1"
_MIME = "application/x-ejn-array-group"
_MAX_GROUP = 67_108_864
_MAX_PLANE = 33_554_432
_MAX_HEADER = 16_384
_MAX_DIMS = 16_384
_MAX_MEMBERS = 4
_DTYPES = {"|u1", "|i1", "<u2", ">u2", "<i2", ">i2", "<u4", ">u4",
           "<i4", ">i4", "<f4", ">f4", "<f8", ">f8"}


def _text(value, label, required=False):
    if value is None and not required:
        return None
    if not isinstance(value, str) or (required and not value):
        raise ValueError(label + " must be a non-empty string")
    if len(value) > 128:
        raise ValueError(label + " is too long")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as exc:
        raise ValueError(label + " is not valid UTF-8") from exc
    if len(encoded) > 128 or any(not c.isprintable() for c in value):
        raise ValueError(label + " is too long or contains control characters")
    return value


def _view(planes, *, key="default", sample_id=None, grid_id=None, units=None):
    import numpy as np
    from IPython.display import display

    if not isinstance(planes, Mapping):
        raise ValueError("planes must be a bounded mapping")
    count = len(planes)
    if not 1 <= count <= _MAX_MEMBERS:
        raise ValueError("planes must contain 1 to 4 members")
    members = list(islice(planes.items(), _MAX_MEMBERS + 1))
    if len(members) != count:
        raise ValueError("planes mapping changed during validation")
    key = _text(key, "key", required=True)
    sample_id = _text(sample_id, "sample_id", required=True)
    grid_id = _text(grid_id, "grid_id")
    units = _text(units, "units")
    validated = []
    total_raw = 0
    names = set()
    for index, (name, array) in enumerate(members):
        name = _text(name, "plane name", required=True)
        if name in names:
            raise ValueError("plane names must be unique")
        names.add(name)
        if not isinstance(array, np.ndarray) or array.ndim != 2:
            raise ValueError("each plane must be a 2D NumPy array")
        if np.ma.isMaskedArray(array):
            raise ValueError("masked arrays are unsupported; publish explicit numerical values")
        rows, columns = array.shape
        if not (1 <= rows <= _MAX_DIMS and 1 <= columns <= _MAX_DIMS):
            raise ValueError("plane dimensions must be between 1 and 16384")
        dtype = array.dtype.str
        if dtype not in _DTYPES:
            raise ValueError("unsupported dtype: " + dtype)
        nbytes = rows * columns * array.dtype.itemsize
        if nbytes > _MAX_PLANE:
            raise ValueError("plane exceeds 33554432 raw bytes")
        validated.append((name, array, dtype, rows, columns, nbytes))
        total_raw += nbytes
    offset = 0
    metadata = []
    for index, (name, array, dtype, rows, columns, nbytes) in enumerate(validated):
        plane = {"id": str(index), "name": name, "shape": [rows, columns],
                 "dtype": dtype, "offset": offset, "nbytes": nbytes}
        if grid_id is not None:
            plane["grid_id"] = grid_id
        if units is not None:
            plane["units"] = units
        metadata.append(plane)
        offset += nbytes
    header = {"v": 1, "key": key, "sample_id": sample_id,
              "publication_id": uuid.uuid4().hex, "planes": metadata}
    header_bytes = json.dumps(header, ensure_ascii=False, separators=(",", ":"),
                              allow_nan=False).encode("utf-8")
    if len(header_bytes) > _MAX_HEADER:
        raise ValueError("header exceeds 16384 bytes")
    if 12 + len(header_bytes) + total_raw > _MAX_GROUP:
        raise ValueError("array group exceeds 67108864 bytes")
    raw = b"".join(np.ascontiguousarray(array).tobytes(order="C")
                    for _, array, _, _, _, _ in validated)
    payload = b"EJNARR01" + len(header_bytes).to_bytes(4, "big") + header_bytes + raw
    summary = "EJN array group %s: %d plane(s), sample %s" % (key, count, sample_id)
    display({_MIME: base64.b64encode(payload).decode("ascii"),
             "text/plain": summary}, raw=True)
    return header


def install(namespace):
    """Install ``ejn.view`` in an IPython user namespace exactly once."""
    if not isinstance(namespace, dict):
        raise TypeError("namespace must be a dictionary")
    if "ejn" in namespace:
        existing = namespace["ejn"]
        if getattr(existing, "_ejn_publisher_marker", None) == _MARKER:
            return existing
        raise RuntimeError("cannot install array-group publisher: user-owned ejn exists")

    class _EJN:
        _ejn_publisher_marker = _MARKER
        view = staticmethod(_view)
    instance = _EJN()
    namespace["ejn"] = instance
    return instance
