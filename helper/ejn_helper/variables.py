"""Bounded, metadata-only Python namespace inspection for user expressions.

The expression runs in a temporary dictionary and imports only the standard
library.  Array storage is never read, rendered, copied or converted.  Unknown
objects expose their actual type only; their properties and repr are not used.
"""

from __future__ import annotations

import ast
import json
from collections.abc import Mapping

from .backend import BackendError

MAX_VARIABLES = 200
MAX_VARIABLE_NAME = 128
MAX_VARIABLE_BYTES = 40_000
EXPRESSION_KEY = "ejn_variables"

# Keep this code independent of the helper installation: remote kernels receive
# it in memory and need no EJN package.  Descriptor access to ndarray metadata
# deliberately bypasses any subclass's Python properties or __getattribute__.
_REMOTE_SOURCE = '''
def _ejn_variables():
    import builtins as b, json, sys, types
    def clean(value, size):
        if b.type(value) is not b.str:
            return '?'
        return ''.join(c if ' ' <= c <= '~' and c not in "\\\\'\\\"" else '?' for c in value[:size])
    def module_dict(name):
        module = sys.modules.get(name)
        return types.ModuleType.__getattribute__(module, '__dict__') if b.type(module) is types.ModuleType else {}
    numpy = module_dict('numpy')
    ndarray = numpy.get('ndarray')
    torch = module_dict('torch')
    tensor = torch.get('Tensor')
    def metadata(name, value):
        cls = b.type(value)
        # Call type's own descriptors, bypassing a user metaclass's properties.
        class_name = b.type.__dict__['__name__'].__get__(cls)
        module = b.type.__dict__['__module__'].__get__(cls)
        row = {'name': name, 'type': clean(module, 63) + '.' + clean(class_name, 63), 'shape': None, 'dtype': None}
        try:
            shape = None
            if ndarray is not None and b.any(base is ndarray for base in b.type.__dict__['__mro__'].__get__(cls)):
                descriptors = b.type.__dict__['__dict__'].__get__(ndarray)
                shape = descriptors['shape'].__get__(value, cls)
                dtype = descriptors['dtype'].__get__(value, cls)
                row['dtype'] = clean(dtype.name, 64)
            elif tensor is not None and cls is tensor:
                # Exact Tensor only: subclasses can override torch dispatch.
                shape = value.shape
                row['dtype'] = clean(b.str(value.dtype), 64)
            elif cls is b.memoryview:
                shape = value.shape
                row['dtype'] = clean(value.format, 64)
            if shape is not None and b.len(shape) <= 32 and b.all(b.type(n) is b.int and 0 <= n <= 9007199254740991 for n in shape):
                row['shape'] = b.list(shape)
        except Exception:
            # Unsupported metadata never triggers a fallback to repr or values.
            pass
        return row
    ns = _ejn_user_ns
    if b.type(ns) is not b.dict:
        return json.dumps({'variables': [], 'truncated': False})
    requested = _ejn_names
    rows, used, scanned, truncated = [], 0, 0, False
    iterator = ((name, b.dict.get(ns, name)) for name in requested if name in ns) if requested is not None else b.iter(b.dict.items(ns))
    try:
        for name, value in iterator:
            scanned += 1
            if scanned > 4096:
                truncated = True
                break
            if b.type(name) is not b.str or b.len(name) > 128 or b.len(name.encode('utf-8')) > 128 or not name.isidentifier():
                continue
            if requested is None and (name.startswith('_') or b.any(b.type(value) is kind for kind in (types.ModuleType, types.FunctionType, types.BuiltinFunctionType, b.type))):
                continue
            row = metadata(name, value)
            size = b.len(json.dumps(row, ensure_ascii=True, separators=(',', ':')))
            if b.len(rows) >= _ejn_limit or used + size > 39000:
                truncated = True
                break
            rows.append(row)
            used += size + 1
    except RuntimeError:
        truncated = True
    rows.sort(key=lambda row: row['name'])
    return json.dumps({'variables': rows, 'truncated': truncated}, ensure_ascii=True, separators=(',', ':'))
'''


def build_variables_expression(params: Mapping[str, object]) -> str:
    """Build one safe metadata expression after strict bounded validation."""
    names = params.get("names")
    limit = params.get("limit", MAX_VARIABLES)
    if (
        set(params) - {"names", "limit"}
        or type(limit) is not int
        or not 1 <= limit <= MAX_VARIABLES
        or (
            names is not None
            and (
                type(names) is not list
                or not 1 <= len(names) <= MAX_VARIABLES
                or any(type(name) is not str or not 1 <= len(name) <= MAX_VARIABLE_NAME or not name.isidentifier() or len(name.encode('utf-8')) > MAX_VARIABLE_NAME for name in names)
                or len(set(names)) != len(names)
            )
        )
    ):
        raise BackendError("invalid-request")
    # Builtins are imported explicitly so a notebook variable named `exec`,
    # `type`, or `str` cannot alter introspection.  No helper names are written
    # into the user's namespace, and no representation of user values is used.
    return (
        "(lambda _scope: (__import__('builtins').exec("
        + repr(_REMOTE_SOURCE)
        + ", _scope), _scope['_ejn_variables']())[1])"
        + "({'_ejn_user_ns': get_ipython().user_ns, '_ejn_names': "
        + repr(names)
        + ", '_ejn_limit': "
        + str(limit)
        + "})"
    )


def normalize_variables_reply(content: Mapping[str, object]) -> dict:
    """Extract and validate metadata from a correlated execute_reply.

IPython's plain-text representation of a JSON string is a quoted Python
literal.  Only a bounded string literal is decoded; rich MIME is never read.
"""
    expressions = content.get("user_expressions")
    item = expressions.get(EXPRESSION_KEY) if isinstance(expressions, Mapping) else None
    data = item.get("data") if isinstance(item, Mapping) else None
    text = data.get("text/plain") if isinstance(data, Mapping) else None
    if (
        content.get("status") != "ok"
        or not isinstance(item, Mapping)
        or item.get("status") != "ok"
        or type(text) is not str
        or len(text) > 65_536
        or len(text) < 2
        or text[0] not in "\"'"
        or text[-1] != text[0]
    ):
        raise BackendError("protocol-error")
    try:
        raw = ast.literal_eval(text)
        if type(raw) is not str or len(raw) > MAX_VARIABLE_BYTES:
            raise ValueError("invalid metadata size")
        result = json.loads(raw)
    except (ValueError, TypeError, SyntaxError, RecursionError, MemoryError) as exc:
        raise BackendError("protocol-error") from exc
    if (
        type(result) is not dict
        or set(result) != {"variables", "truncated"}
        or type(result["variables"]) is not list
        or len(result["variables"]) > MAX_VARIABLES
        or type(result["truncated"]) is not bool
    ):
        raise BackendError("protocol-error")
    seen = set()
    for row in result["variables"]:
        if type(row) is not dict or set(row) != {"name", "type", "shape", "dtype"}:
            raise BackendError("protocol-error")
        name, kind, shape, dtype = (row[key] for key in ("name", "type", "shape", "dtype"))
        if (
            type(name) is not str
            or not 1 <= len(name) <= MAX_VARIABLE_NAME
            or not name.isidentifier()
            or len(name.encode('utf-8')) > MAX_VARIABLE_NAME
            or name in seen
            or type(kind) is not str
            or not 1 <= len(kind) <= 128
            or not kind.isascii()
            or not kind.isprintable()
            or (dtype is not None and (type(dtype) is not str or len(dtype) > 64 or not dtype.isascii() or not dtype.isprintable()))
            or (shape is not None and (type(shape) is not list or len(shape) > 32 or any(type(n) is not int or not 0 <= n <= 2**53 - 1 for n in shape)))
        ):
            raise BackendError("protocol-error")
        seen.add(name)
    if len(json.dumps(result, ensure_ascii=True, separators=(",", ":"))) > MAX_VARIABLE_BYTES:
        raise BackendError("protocol-error")
    return result
