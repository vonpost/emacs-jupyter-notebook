"""Self-contained EJN numerical-group publisher; importing never installs it."""

import base64
import json
import hashlib
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
    return None


def _view_variable(namespace, name, *, axes=None, indices=None):
    """Publish only one selected 2D plane of a named NumPy variable.

    AXES contains the display row and column dimensions, in that order.
    INDICES has one item per source dimension: None for each display axis and
    a nonnegative integer for every other axis (including a channel axis).
    NumPy's base descriptors and base view bypass subclass Python getters and
    slicing overrides. No complete array conversion or representation occurs.
    """
    import numpy as np

    if type(name) is not str or not name.isidentifier():
        raise ValueError("use a simple Python variable name")
    name = _text(name, "variable name", required=True)
    if type(namespace) is not dict or name not in namespace:
        raise ValueError("variable is not defined in this kernel")
    value = dict.__getitem__(namespace, name)
    cls = type(value)
    bases = type.__dict__["__mro__"].__get__(cls)
    if not any(base is np.ndarray for base in bases):
        raise ValueError("array viewing currently requires a NumPy ndarray")
    if any(base is np.ma.MaskedArray for base in bases):
        raise ValueError("masked arrays are unsupported; select explicit numerical values")
    descriptors = type.__dict__["__dict__"].__get__(np.ndarray)
    shape = descriptors["shape"].__get__(value, cls)
    dtype = descriptors["dtype"].__get__(value, cls)
    ndim = len(shape)
    if not 2 <= ndim <= 32:
        raise ValueError("array viewing requires between 2 and 32 dimensions")
    if axes is None:
        if ndim != 2:
            raise ValueError("choose two display axes for a multidimensional array")
        axes = [0, 1]
    if (type(axes) not in (list, tuple) or len(axes) != 2
            or any(type(axis) is not int or not 0 <= axis < ndim for axis in axes)
            or axes[0] == axes[1]):
        raise ValueError("choose two distinct valid display axes")
    if indices is None:
        indices = [None if axis in axes else 0 for axis in range(ndim)]
    if type(indices) not in (list, tuple) or len(indices) != ndim:
        raise ValueError("provide one slice index per dimension")
    selector = []
    for axis, (size, index) in enumerate(zip(shape, indices)):
        if axis in axes:
            if index is not None:
                raise ValueError("display axes must have None slice indices")
            if not 1 <= size <= _MAX_DIMS:
                raise ValueError("selected plane dimensions must be between 1 and 16384")
            selector.append(slice(None))
        else:
            if type(index) is not int or not 0 <= index < size:
                raise ValueError("slice index is outside its array dimension")
            selector.append(index)
    if dtype.str not in _DTYPES:
        raise ValueError("unsupported viewer dtype: " + dtype.str)
    if shape[axes[0]] * shape[axes[1]] * dtype.itemsize > _MAX_PLANE:
        raise ValueError("selected plane exceeds 33554432 raw bytes")
    # A base ndarray view has no Python subclass finalizer or __getitem__.
    base = np.ndarray.view(value, np.ndarray)
    plane = np.ndarray.__getitem__(base, tuple(selector))
    if axes[0] > axes[1]:
        plane = np.ndarray.transpose(plane)
    # Stable workspace and selection identity. A different slice must not
    # inherit ROI geometry. A variable may be rebound to an unrelated image,
    # so shape/indices alone cannot declare spatial correspondence or units;
    # the viewer asks for those declarations before comparisons across runs.
    key = "variable-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:24]
    selection = json.dumps([name, list(shape), list(axes), list(indices)], separators=(",", ":"))
    identity = hashlib.sha256(selection.encode("utf-8")).hexdigest()[:32]
    return _view({name: plane}, key=key, sample_id=identity)


def install(namespace):
    """Install or refresh the owned ``ejn`` publisher in a user namespace."""
    if not isinstance(namespace, dict):
        raise TypeError("namespace must be a dictionary")
    class _EJN:
        _ejn_publisher_marker = _MARKER
        view = staticmethod(_view)

        @staticmethod
        def view_variable(name, *, axes=None, indices=None):
            return _view_variable(namespace, name, axes=axes, indices=indices)
    if "ejn" in namespace:
        existing = namespace["ejn"]
        if getattr(existing, "_ejn_publisher_marker", None) == _MARKER:
            # Reconnect injects fresh source into a durable kernel. Refresh the
            # owned methods while retaining callers' identity reference.
            type(existing).view = staticmethod(_view)
            type(existing).view_variable = staticmethod(_EJN.view_variable)
            return existing
        raise RuntimeError("cannot install array-group publisher: user-owned ejn exists")
    instance = _EJN()
    namespace["ejn"] = instance
    return instance
