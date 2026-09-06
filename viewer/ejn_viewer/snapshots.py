"""Bounded, worker-side loading of viewer snapshots.

This module deliberately has no Qt, GUI, IPC, pickle, or memmap dependency.
The caller owns worker scheduling; :func:`load_snapshot` performs one bounded
load from a typed ``open`` parameter object and returns an independent copy.
"""

from __future__ import annotations

import copy
import hashlib
import io
import os
import re
import stat
from dataclasses import dataclass
from typing import Any

import numpy as np

from ejn_array import MAX_GROUP_BYTES, ArrayFormatError, read_manifest


MAX_JSON_SAFE = 9_007_199_254_740_991
MAX_PATH_BYTES = 4096
MAX_RASTER_PIXELS = 16_777_216
MAX_READ_CHUNK = 1024 * 1024
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_ARTIFACT_NAME = re.compile(r"ejn-artifact-[0-9a-f]{32}\Z")
_KINDS = {"array-group", "raster"}
_MIMES = {"image/png", "image/jpeg"}


class SnapshotError(ValueError):
    """A safe, bounded snapshot admission or decoding error."""


@dataclass(frozen=True)
class Snapshot:
    """Independent local snapshot returned by the worker loader."""

    workspace: str
    generation: int
    execution: str
    kind: str
    focus: bool
    manifest: dict[str, Any] | None
    planes: dict[str, np.ndarray]
    image: Any | None
    numerical: bool
    raw_bytes: bytes
    nbytes: int


def _bounded_text(value: Any, name: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        raise SnapshotError(f"invalid {name}")
    limit = MAX_PATH_BYTES if name in ("root", "path") else 512
    if len(value) > limit or any(not character.isprintable() for character in value):
        raise SnapshotError(f"invalid {name}")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as exc:
        raise SnapshotError(f"invalid {name}") from exc
    if len(encoded) > limit:
        raise SnapshotError(f"invalid {name}")
    return value


def _safe_integer(value: Any, name: str, *, upper: int = MAX_JSON_SAFE) -> int:
    if type(value) is not int or value < 0 or value > upper:
        raise SnapshotError(f"invalid {name}")
    return value


def _artifact(params: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(params, dict):
        raise SnapshotError("invalid open parameters")
    required = {"root", "path", "root_device", "root_inode", "device", "inode",
                "size", "sha256"}
    artifact = params.get("artifact")
    if not isinstance(artifact, dict) or set(artifact) != required:
        raise SnapshotError("invalid artifact")
    root = _bounded_text(artifact["root"], "root")
    path = _bounded_text(artifact["path"], "path")
    if not os.path.isabs(root) or not os.path.isabs(path):
        raise SnapshotError("artifact paths must be absolute")
    if os.path.dirname(path) != os.path.normpath(root):
        raise SnapshotError("artifact path is outside root")
    if not _ARTIFACT_NAME.fullmatch(os.path.basename(path)):
        raise SnapshotError("invalid artifact path")
    for field in ("root_device", "root_inode", "device", "inode"):
        _safe_integer(artifact[field], field)
    size = _safe_integer(artifact["size"], "size", upper=MAX_GROUP_BYTES)
    if size < 1:
        raise SnapshotError("invalid size")
    digest = artifact["sha256"]
    if not isinstance(digest, str) or not _SHA256.fullmatch(digest):
        raise SnapshotError("invalid sha256")
    return {"root": root, "path": path, "root_device": artifact["root_device"],
            "root_inode": artifact["root_inode"], "device": artifact["device"],
            "inode": artifact["inode"], "size": size, "sha256": digest}


def _open_verified(artifact: dict[str, Any]):
    root = artifact["root"]
    path = artifact["path"]
    try:
        root_before = os.lstat(root)
        file_before = os.lstat(path)
    except OSError as exc:
        raise SnapshotError("artifact unavailable") from exc
    uid = os.geteuid()
    if (stat.S_ISLNK(root_before.st_mode) or not stat.S_ISDIR(root_before.st_mode)
            or root_before.st_uid != uid or stat.S_IMODE(root_before.st_mode) != 0o700
            or root_before.st_dev != artifact["root_device"]
            or root_before.st_ino != artifact["root_inode"]):
        raise SnapshotError("unsafe artifact root")
    if (stat.S_ISLNK(file_before.st_mode) or not stat.S_ISREG(file_before.st_mode)
            or file_before.st_uid != uid or stat.S_IMODE(file_before.st_mode) != 0o600
            or file_before.st_nlink != 1 or file_before.st_dev != artifact["device"]
            or file_before.st_ino != artifact["inode"]
            or file_before.st_size != artifact["size"]):
        raise SnapshotError("unsafe artifact")
    root_fd = file_fd = None
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        file_fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW,
                          dir_fd=root_fd)
        opened_root = os.fstat(root_fd)
        if (stat.S_ISLNK(opened_root.st_mode) or not stat.S_ISDIR(opened_root.st_mode)
                or opened_root.st_uid != uid
                or stat.S_IMODE(opened_root.st_mode) != 0o700
                or opened_root.st_dev != artifact["root_device"]
                or opened_root.st_ino != artifact["root_inode"]):
            raise SnapshotError("artifact root changed")
        opened = os.fstat(file_fd)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != uid
                or stat.S_IMODE(opened.st_mode) != 0o600 or opened.st_nlink != 1
                or opened.st_dev != artifact["device"] or opened.st_ino != artifact["inode"]
                or opened.st_size != artifact["size"]
                or opened.st_mtime_ns != file_before.st_mtime_ns
                or opened.st_ctime_ns != file_before.st_ctime_ns):
            raise SnapshotError("artifact changed")
        return root_fd, file_fd, opened_root, opened
    except OSError as exc:
        if file_fd is not None:
            os.close(file_fd)
        if root_fd is not None:
            os.close(root_fd)
        raise SnapshotError("artifact unavailable") from exc
    except Exception:
        if file_fd is not None:
            os.close(file_fd)
        if root_fd is not None:
            os.close(root_fd)
        raise


def _read_copy(artifact: dict[str, Any]) -> bytes:
    root_fd, file_fd, _root_before, file_before = _open_verified(artifact)
    try:
        digest = hashlib.sha256()
        chunks = []
        remaining = artifact["size"]
        while remaining:
            chunk = os.read(file_fd, min(MAX_READ_CHUNK, remaining))
            if not chunk:
                raise SnapshotError("artifact truncated")
            chunks.append(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
        if digest.hexdigest() != artifact["sha256"]:
            raise SnapshotError("artifact hash mismatch")
        after = os.fstat(file_fd)
        root_after = os.fstat(root_fd)
        root_path_after = os.lstat(artifact["root"])
        path_after = os.lstat(artifact["path"])
        # Sibling publications and cleanup legitimately change directory
        # timestamps. The pinned directory inode and its current pathname,
        # owner, mode and type are the authority, never its mtime/ctime.
        if (not stat.S_ISDIR(root_after.st_mode)
                or root_after.st_dev != artifact["root_device"]
                or root_after.st_ino != artifact["root_inode"]
                or root_after.st_uid != os.geteuid()
                or stat.S_IMODE(root_after.st_mode) != 0o700
                or not stat.S_ISDIR(root_path_after.st_mode)
                or root_path_after.st_dev != root_after.st_dev
                or root_path_after.st_ino != root_after.st_ino
                or root_path_after.st_uid != root_after.st_uid
                or stat.S_IMODE(root_path_after.st_mode) != 0o700
                or after.st_dev != artifact["device"] or after.st_ino != artifact["inode"]
                or after.st_size != artifact["size"] or after.st_nlink != 1
                or not stat.S_ISREG(after.st_mode)
                or after.st_uid != os.geteuid()
                or stat.S_IMODE(after.st_mode) != 0o600
                or after.st_mtime_ns != file_before.st_mtime_ns
                or after.st_ctime_ns != file_before.st_ctime_ns
                or not stat.S_ISREG(path_after.st_mode)
                or path_after.st_dev != after.st_dev or path_after.st_ino != after.st_ino
                or path_after.st_size != after.st_size
                or path_after.st_nlink != after.st_nlink
                or path_after.st_uid != after.st_uid
                or stat.S_IMODE(path_after.st_mode) != 0o600
                or path_after.st_mtime_ns != after.st_mtime_ns
                or path_after.st_ctime_ns != after.st_ctime_ns):
            raise SnapshotError("artifact changed during read")
        return b"".join(chunks)
    except OSError as exc:
        raise SnapshotError("artifact read failed") from exc
    finally:
        os.close(file_fd)
        os.close(root_fd)


class _BytesReader:
    def __init__(self, data: bytes):
        self._data = memoryview(data)
        self._position = 0

    def read(self, size=-1):
        if size < 0:
            size = len(self._data) - self._position
        start = self._position
        self._position = min(len(self._data), start + size)
        return self._data[start:self._position].tobytes()


def _load_array_group(raw: bytes) -> tuple[dict[str, Any], dict[str, np.ndarray]]:
    stream = _BytesReader(raw)
    try:
        manifest, data_offset = read_manifest(stream, len(raw))
    except (ArrayFormatError, ValueError) as exc:
        raise SnapshotError(str(exc)) from exc
    planes = {}
    for plane in manifest["planes"]:
        start = data_offset + plane["offset"]
        end = start + plane["nbytes"]
        try:
            dtype = np.dtype(plane["dtype"])
            value = np.frombuffer(raw, dtype=dtype,
                                  count=plane["nbytes"] // dtype.itemsize,
                                  offset=start).reshape(tuple(plane["shape"]))
        except (TypeError, ValueError) as exc:
            raise SnapshotError("invalid plane data") from exc
        value.setflags(write=False)
        planes[plane["name"]] = value
    return copy.deepcopy(manifest), planes


def _load_raster(raw: bytes, mime: str):
    try:
        from PIL import Image
        image = Image.open(io.BytesIO(raw))
        if image.format not in ("PNG", "JPEG") or image.format.lower() != mime.rsplit("/", 1)[1]:
            raise SnapshotError("raster MIME does not match image")
        if image.width * image.height > MAX_RASTER_PIXELS:
            raise SnapshotError("raster exceeds pixel limit")
        if image.mode not in ("RGB", "RGBA", "L", "LA", "P"):
            raise SnapshotError("unsupported raster mode")
        if image.mode != "RGBA" and (image.mode == "LA" or "transparency" in image.info):
            image = image.convert("RGBA")
        elif image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGB")
        image.load()
        pixels = np.array(image, dtype=np.uint8, copy=True)
        pixels.setflags(write=False)
        return pixels
    except SnapshotError:
        raise
    except Exception as exc:
        raise SnapshotError("invalid raster") from exc


def load_snapshot(params: dict[str, Any]) -> Snapshot:
    """Validate and independently load one typed viewer ``open`` request."""
    if not isinstance(params, dict):
        raise SnapshotError("invalid open parameters")
    required = {"workspace", "generation", "execution", "kind", "artifact", "focus"}
    if not required <= set(params):
        raise SnapshotError("missing open parameter")
    workspace = _bounded_text(params["workspace"], "workspace")
    generation = _safe_integer(params["generation"], "generation")
    execution = _bounded_text(params["execution"], "execution")
    kind = params["kind"]
    if not isinstance(kind, str) or kind not in _KINDS:
        raise SnapshotError("unsupported snapshot kind")
    if type(params["focus"]) is not bool:
        raise SnapshotError("invalid focus")
    mime = None
    if kind == "raster":
        mime = params.get("mime")
        if not isinstance(mime, str) or mime not in _MIMES:
            raise SnapshotError("invalid raster MIME")
    elif "mime" in params:
        raise SnapshotError("unexpected raster MIME")
    artifact = _artifact(params)
    raw = _read_copy(artifact)
    if kind == "array-group":
        manifest, planes = _load_array_group(raw)
        return Snapshot(workspace, generation, execution, kind, params["focus"],
                        manifest, planes, None, True, raw, len(raw))
    image = _load_raster(raw, mime)
    return Snapshot(workspace, generation, execution, kind, params["focus"],
                    None, {"rendered": image}, None, False, b"", image.nbytes)
