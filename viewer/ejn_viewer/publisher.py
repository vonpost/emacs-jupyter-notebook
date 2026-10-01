"""Self-contained EJN numerical-group publisher; importing never installs it."""

import base64
import json
import hashlib
import math
import sys
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
           "<i4", ">i4", "<f2", ">f2", "<f4", ">f4", "<f8", ">f8"}


def _array_metadata(value, np):
    """Inspect supported arrays without converting samples or importing torch.

    NumPy subclass descriptors are bypassed. Only exact Tensor and Parameter
    instances are admitted: arbitrary tensor subclasses may dispatch user code
    even when reading metadata or selecting a slice.
    """
    cls = type(value)
    bases = type.__dict__["__mro__"].__get__(cls)
    if any(base is np.ndarray for base in bases):
        if any(base is np.ma.MaskedArray for base in bases):
            raise ValueError("masked arrays are unsupported; publish explicit numerical values")
        descriptors = type.__dict__["__dict__"].__get__(np.ndarray)
        shape = descriptors["shape"].__get__(value, cls)
        dtype = descriptors["dtype"].__get__(value, cls)
        torch = None
    else:
        torch = sys.modules.get("torch")
        parameter_module = sys.modules.get("torch.nn.parameter")
        tensor = vars(torch).get("Tensor") if torch is not None else None
        parameter = (vars(parameter_module).get("Parameter")
                     if parameter_module is not None else None)
        if cls is not tensor and cls is not parameter:
            raise ValueError("array viewing requires a NumPy ndarray or an exact PyTorch Tensor/Parameter")
        if value.layout is not torch.strided or value.is_nested:
            raise ValueError("sparse and nested tensors are unsupported; select explicit dense values")
        if value.is_quantized:
            raise ValueError("quantized tensors are unsupported; dequantize explicitly")
        if value.device.type == "meta":
            raise ValueError("meta tensors have no numerical values to publish")
        kind = str(value.dtype).split(".")[-1]
        if kind not in {"uint8", "int8", "uint16", "int16", "uint32", "int32",
                        "float16", "bfloat16", "float32", "float64"}:
            raise ValueError("unsupported dtype: " + str(value.dtype))
        # Every bfloat16 value is exactly representable in float32. Count the
        # wider wire storage before copying or moving anything to the CPU.
        dtype = np.dtype("float32" if kind == "bfloat16" else kind)
        shape = tuple(value.shape)
    if dtype.str not in _DTYPES:
        raise ValueError("unsupported dtype: " + dtype.str)
    return shape, dtype, torch


def _array_bytes(value, shape, dtype, torch, np):
    """Copy an already budgeted member to immutable C-order bytes."""
    if torch is None:
        value = np.ndarray.view(value, np.ndarray)
    else:
        # Detach also gives this copy its own shape metadata. Recheck before
        # allocation in case a user thread resized a member since validation.
        value = value.detach()
        frozen_shape, frozen_dtype, _ = _array_metadata(value, np)
        if frozen_shape != shape or frozen_dtype != dtype:
            raise ValueError("array metadata changed during publication")
        target_dtype = torch.float32 if value.dtype is torch.bfloat16 else value.dtype
        value = (value.to(device="cpu", dtype=target_dtype, copy=True,
                          memory_format=torch.contiguous_format)
                 .resolve_conj().resolve_neg().numpy())
    if value.shape != shape or value.dtype != dtype:
        raise ValueError("array metadata changed during publication")
    return np.ascontiguousarray(value).tobytes(order="C")


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


def _member_options(value, names, label):
    """Freeze a shared option or a bounded mapping naming every member."""
    if isinstance(value, Mapping):
        if len(value) != len(names):
            raise ValueError(label + " mapping must name every published member exactly once")
        entries = list(islice(value.items(), _MAX_MEMBERS + 1))
        if len(entries) != len(names):
            raise ValueError(label + " mapping changed during validation")
        options = {}
        for name, option in entries:
            name = _text(name, label + " member name", required=True)
            if name not in names or name in options:
                raise ValueError(label + " mapping must name every published member exactly once")
            options[name] = option
        return options
    return {name: value for name in names}


def _spatial_vector(value, ndim, label, *, positive=False):
    if type(value) not in (tuple, list) or len(value) != ndim:
        raise ValueError(label + " must have one number per array axis")
    for number in value:
        if type(number) not in (int, float):
            raise ValueError(label + " must contain finite numbers")
        try:
            if not math.isfinite(number) or (positive and number <= 0):
                raise ValueError(label + " must contain " +
                                 ("positive finite numbers" if positive else "finite numbers"))
        except OverflowError as exc:
            raise ValueError(label + " must contain finite numbers") from exc
    return list(value)


def _view(planes, *, key="default", sample_id=None, grid_id=None, units=None,
          spacing=None, origin=None, spatial_units="mm"):
    """Publish bounded 2D planes or explicit 3D crops, preserving sample values.

    A three-dimensional member is a scalar volume in source axis order, never
    RGB. Crop/slice large sources before calling. PyTorch tensors may reside on
    any materialized device; only accepted members move to CPU. bfloat16 uses
    lossless float32 storage; other accepted dtypes retain their precision.

    SPACING and optional ORIGIN use ndarray axis order, either shared tuples
    or mappings naming every member. ORIGIN is the physical center of index
    zero, defaulting to zero. Spatial metadata is emitted only with SPACING;
    its units default to mm. Axes are aligned to the declared GRID_ID frame.
    """
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
        shape, dtype, torch = _array_metadata(array, np)
        if len(shape) not in (2, 3):
            raise ValueError("each member must be a 2D plane or 3D cropped volume")
        if any(type(size) is not int or not 1 <= size <= _MAX_DIMS for size in shape):
            raise ValueError("member dimensions must be between 1 and 16384")
        nbytes = math.prod(shape) * dtype.itemsize
        if nbytes > _MAX_PLANE:
            raise ValueError("member exceeds 33554432 raw bytes; crop or slice before publishing")
        validated.append((name, array, shape, dtype, torch, nbytes))
        total_raw += nbytes
    if spacing is None and origin is not None:
        raise ValueError("origin requires spacing")
    if spacing is not None:
        spacing_by_name = _member_options(spacing, names, "spacing")
        origin_by_name = _member_options(origin, names, "origin")
        spatial_units = _text(spatial_units, "spatial_units", required=True)
    offset = 0
    metadata = []
    for index, (name, array, shape, dtype, torch, nbytes) in enumerate(validated):
        plane = {"id": str(index), "name": name, "shape": list(shape),
                 "dtype": dtype.str, "offset": offset, "nbytes": nbytes}
        if grid_id is not None:
            plane["grid_id"] = grid_id
        if units is not None:
            plane["units"] = units
        if spacing is not None:
            ndim = len(shape)
            plane_spacing = _spatial_vector(spacing_by_name[name], ndim, "spacing", positive=True)
            plane_origin = _spatial_vector(
                [0] * ndim if origin_by_name[name] is None else origin_by_name[name], ndim, "origin")
            plane.update(spacing=plane_spacing, origin=plane_origin,
                         direction=[int(row == column) for row in range(ndim) for column in range(ndim)],
                         spatial_units=spatial_units)
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
    raw = b"".join(_array_bytes(array, shape, dtype, torch, np)
                    for _, array, shape, dtype, torch, _ in validated)
    payload = b"EJNARR01" + len(header_bytes).to_bytes(4, "big") + header_bytes + raw
    summary = "EJN array group %s: %d member(s), sample %s" % (key, count, sample_id)
    display({_MIME: base64.b64encode(payload).decode("ascii"),
             "text/plain": summary}, raw=True)
    return None


def _view_variable(namespace, name, *, axes=None, indices=None):
    """Publish only one selected 2D plane of a named NumPy/PyTorch variable.

    AXES contains the display row and column dimensions, in that order.
    INDICES has one item per source dimension: None for each display axis and
    a nonnegative integer for every other axis (including a channel axis).
    NumPy's base descriptors and base view bypass subclass Python getters and
    slicing overrides. Tensor selection precedes CPU transfer. No complete
    source conversion or representation occurs.
    """
    import numpy as np

    if type(name) is not str or not name.isidentifier():
        raise ValueError("use a simple Python variable name")
    name = _text(name, "variable name", required=True)
    if type(namespace) is not dict or name not in namespace:
        raise ValueError("variable is not defined in this kernel")
    value = dict.__getitem__(namespace, name)
    shape, dtype, torch = _array_metadata(value, np)
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
    if shape[axes[0]] * shape[axes[1]] * dtype.itemsize > _MAX_PLANE:
        raise ValueError("selected plane exceeds 33554432 raw bytes")
    if torch is None:
        # A base ndarray view has no Python subclass finalizer or __getitem__.
        base = np.ndarray.view(value, np.ndarray)
        plane = np.ndarray.__getitem__(base, tuple(selector))
        if axes[0] > axes[1]:
            plane = np.ndarray.transpose(plane)
    else:
        plane = value[tuple(selector)]
        if axes[0] > axes[1]:
            plane = plane.transpose(0, 1)
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
