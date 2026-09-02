"""Bounded, non-interactive JSON registry transactions.

This program deliberately owns the entire read-modify-write transaction.  It
uses a nonblocking POSIX advisory lock, so a second Emacs process receives a
bounded ``busy`` reply rather than waiting in Emacs or overwriting another
writer's snapshot.
"""

from __future__ import annotations

import errno
import ctypes
import fcntl
import json
import os
import re
import stat
import sys
import tempfile
import uuid
from collections.abc import Callable
from typing import Any


PROTOCOL_VERSION = 1
REGISTRY_VERSION = 1
MAX_REQUEST_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 384 * 1024
MAX_REGISTRY_BYTES = 256 * 1024
MAX_ENTRY_BYTES = 32 * 1024
MAX_ENTRIES = 256
MAX_PATH_BYTES = 4096
MAX_KEY_BYTES = 256
MAX_JSON_DEPTH = 16
MAX_OBJECT_ITEMS = 128
MAX_ARRAY_ITEMS = 128
MAX_SAFE_JSON_INTEGER = 9007199254740991
MAX_MOUNTINFO_BYTES = 1024 * 1024

_LINUX_LOCAL_FILESYSTEMS = frozenset(
    {
        "bcachefs",
        "btrfs",
        "ext2",
        "ext3",
        "ext4",
        "f2fs",
        "jfs",
        "nilfs2",
        # Containerized Emacs installations commonly expose a persistent
        # host directory through overlayfs.  The backing store determines
        # reboot durability, but overlay itself preserves rename/fsync
        # semantics needed by the transaction protocol.
        "overlay",
        "reiserfs",
        "xfs",
        "zfs",
    }
)


class _DarwinFsid(ctypes.Structure):
    _fields_ = [("val", ctypes.c_int32 * 2)]


class _DarwinStatFs64(ctypes.Structure):
    """Darwin's public `struct statfs64' ABI used by arm64 macOS."""

    _fields_ = [
        ("f_bsize", ctypes.c_uint32),
        ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64),
        ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64),
        ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64),
        ("f_fsid", _DarwinFsid),
        ("f_owner", ctypes.c_uint32),
        ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32),
        ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_reserved", ctypes.c_uint32 * 8),
    ]


class RegistryWorkerError(Exception):
    """An expected, safe-to-report registry worker failure."""

    def __init__(self, code: str, message: str, *, committed: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.committed = committed


class BusyError(RegistryWorkerError):
    """Another worker currently owns the registry transaction lock."""

    def __init__(self):
        super().__init__("busy", "registry transaction is already in progress")


class ConflictError(RegistryWorkerError):
    """The record changed after the caller observed its revision."""

    def __init__(self):
        super().__init__("conflict", "registry entry changed before this transaction")


class CorruptRegistryError(RegistryWorkerError):
    """The on-disk file is not the current bounded registry format."""

    def __init__(self, code: str = "corrupt"):
        super().__init__(code, "registry is missing, oversized, or not valid versioned JSON")


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _parse_json(raw: bytes, error_type: Callable[[], RegistryWorkerError]) -> Any:
    try:
        return json.loads(
            raw.decode("utf-8", "strict"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise error_type() from error


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_text(value: str, message: str) -> int:
    try:
        return len(value.encode("utf-8", "strict"))
    except UnicodeEncodeError as error:
        raise RegistryWorkerError("invalid-request", message) from error


def _validate_json_value(value: Any, depth: int = 0) -> None:
    if depth > MAX_JSON_DEPTH:
        raise RegistryWorkerError("invalid-request", "JSON value nesting is too deep")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, str):
        _validate_text(value, "JSON string is invalid")
        return
    if _is_integer(value):
        if abs(value) > MAX_SAFE_JSON_INTEGER:
            raise RegistryWorkerError("invalid-request", "JSON integer is outside the safe range")
        return
    if isinstance(value, float):
        raise RegistryWorkerError("invalid-request", "floating-point registry values are not allowed")
    if isinstance(value, list):
        if len(value) > MAX_ARRAY_ITEMS:
            raise RegistryWorkerError("invalid-request", "JSON array has too many items")
        for item in value:
            _validate_json_value(item, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > MAX_OBJECT_ITEMS:
            raise RegistryWorkerError("invalid-request", "JSON object has too many fields")
        for key, item in value.items():
            if not isinstance(key, str) or _validate_text(key, "JSON object key is invalid") > MAX_KEY_BYTES:
                raise RegistryWorkerError("invalid-request", "JSON object key is invalid")
            _validate_json_value(item, depth + 1)
        return
    raise RegistryWorkerError("invalid-request", "JSON value has an unsupported type")


def _validate_key(value: Any) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise RegistryWorkerError("invalid-request", "registry key must be a non-empty string")
    if _validate_text(value, "registry key is invalid") > MAX_KEY_BYTES:
        raise RegistryWorkerError("invalid-request", "registry key is too large")
    return value


def _validate_revision(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 32:
        raise RegistryWorkerError("invalid-request", "registry revision is invalid")
    try:
        int(value, 16)
    except ValueError as error:
        raise RegistryWorkerError("invalid-request", "registry revision is invalid") from error
    return value.lower()


def _validate_data(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RegistryWorkerError("invalid-request", "registry entry data must be an object")
    _validate_json_value(value)
    if len(_canonical_json(value)) > MAX_ENTRY_BYTES:
        raise RegistryWorkerError("invalid-request", "registry entry data is too large")
    return value


def _new_entry(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"key", "data"}:
        raise RegistryWorkerError(
            "invalid-request", "new registry entry must contain exactly key and data"
        )
    return {
        "key": _validate_key(value["key"]),
        "revision": uuid.uuid4().hex,
        "data": _validate_data(value["data"]),
    }


def _validate_stored_entry(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"key", "revision", "data"}:
        raise CorruptRegistryError()
    try:
        return {
            "key": _validate_key(value["key"]),
            "revision": _validate_revision(value["revision"]),
            "data": _validate_data(value["data"]),
        }
    except RegistryWorkerError as error:
        raise CorruptRegistryError() from error


def _entry_local_file(value: dict[str, Any]) -> str | None:
    """Return an EJN wire entry's absolute local source path, when present."""
    data = value.get("data")
    if not isinstance(data, dict) or data.get("@ejn") != "entry":
        return None
    fields = data.get("fields")
    if not isinstance(fields, list):
        return None
    matches = [
        field[1]
        for field in fields
        if isinstance(field, list)
        and len(field) == 2
        and field[0] == "local-file"
        and isinstance(field[1], str)
    ]
    if len(matches) != 1 or not os.path.isabs(matches[0]) or "\x00" in matches[0]:
        return None
    return matches[0]


def _local_path_identity(path: str) -> tuple[str, tuple[int, int] | None]:
    """Return canonical pathname and optional inode identity for a local path."""
    canonical = os.path.realpath(path)
    try:
        information = os.stat(canonical)
        inode = (information.st_dev, information.st_ino)
    except OSError:
        inode = None
    return canonical, inode


def _local_file_identity(value: dict[str, Any]) -> tuple[str, tuple[int, int] | None] | None:
    """Return canonical pathname and optional inode identity for an EJN entry."""
    path = _entry_local_file(value)
    return None if path is None else _local_path_identity(path)


def _same_local_file(
    first: tuple[str, tuple[int, int] | None],
    second: tuple[str, tuple[int, int] | None],
) -> bool:
    """Return whether two source identities denote one local source file."""
    return first[0] == second[0] or (
        first[1] is not None and second[1] is not None and first[1] == second[1]
    )


def _assert_unique_local_files(entries: list[dict[str, Any]]) -> None:
    """Reject multiple durable sessions claiming the same local source file."""
    identities: list[tuple[str, tuple[int, int] | None]] = []
    for entry in entries:
        identity = _local_file_identity(entry)
        if identity is None:
            continue
        if any(_same_local_file(identity, existing) for existing in identities):
            raise ConflictError()
        identities.append(identity)


def _validate_path(value: Any) -> str:
    if not isinstance(value, str) or "\x00" in value or not os.path.isabs(value):
        raise RegistryWorkerError("invalid-request", "registry path must be an absolute path")
    if _validate_text(value, "registry path is invalid") > MAX_PATH_BYTES:
        raise RegistryWorkerError("invalid-request", "registry path is too large")
    normalized = os.path.abspath(value)
    if normalized != value or normalized == os.path.sep:
        raise RegistryWorkerError("invalid-request", "registry path must be normalized")
    return normalized


def _path_is_symlink(path: str) -> bool:
    try:
        return stat.S_ISLNK(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def _assert_no_symlink_components(path: str) -> None:
    """Reject every existing symlink component below the filesystem root."""
    cursor = os.path.sep
    for component in path.split(os.path.sep)[1:]:
        if not component:
            continue
        cursor = os.path.join(cursor, component)
        if os.path.lexists(cursor) and _path_is_symlink(cursor):
            raise RegistryWorkerError("unsafe-path", "registry path must not traverse a symlink")


def _assert_private_directory(path: str) -> None:
    try:
        info = os.lstat(path)
    except OSError as error:
        raise RegistryWorkerError("unsafe-path", "registry directory cannot be inspected") from error
    if stat.S_ISLNK(info.st_mode):
        raise RegistryWorkerError("unsafe-path", "registry directory must not be a symlink")
    _assert_private_directory_stat(info)


def _assert_private_directory_stat(info: os.stat_result) -> None:
    """Require an opened directory to belong to this user and resist writes by others."""
    if not stat.S_ISDIR(info.st_mode):
        raise RegistryWorkerError("unsafe-path", "registry directory must be a directory")
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise RegistryWorkerError("unsafe-path", "registry directory is not private")


def _assert_private_regular_stat(info: os.stat_result, name: str) -> None:
    if not stat.S_ISREG(info.st_mode):
        raise RegistryWorkerError("unsafe-path", f"{name} must be a regular file")
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RegistryWorkerError("unsafe-path", f"{name} is not private")


def _decode_mountinfo_path(value: bytes) -> bytes:
    """Decode Linux mountinfo's octal path escapes without locale conversion."""
    return re.sub(
        rb"\\([0-7]{3})",
        lambda match: bytes((int(match.group(1), 8),)),
        value,
    )


def _linux_filesystem_type(path: str) -> str:
    """Return PATH's filesystem type from bounded per-process mount metadata."""
    try:
        with open("/proc/self/mountinfo", "rb") as handle:
            raw = handle.read(MAX_MOUNTINFO_BYTES + 1)
    except OSError as error:
        raise RegistryWorkerError(
            "unsafe-filesystem", "registry filesystem cannot be classified"
        ) from error
    if len(raw) > MAX_MOUNTINFO_BYTES:
        raise RegistryWorkerError(
            "unsafe-filesystem", "registry mount metadata exceeds its limit"
        )
    target = os.fsencode(os.path.abspath(path))
    best: tuple[int, str] | None = None
    for line in raw.splitlines():
        fields = line.split(b" ")
        try:
            separator = fields.index(b"-")
            mountpoint = _decode_mountinfo_path(fields[4])
            filesystem = fields[separator + 1].decode("ascii", "strict")
        except (ValueError, IndexError, UnicodeDecodeError):
            continue
        prefix = mountpoint.rstrip(b"/") + b"/"
        if target == mountpoint or target.startswith(prefix):
            candidate = (len(mountpoint), filesystem)
            if best is None or candidate[0] > best[0]:
                best = candidate
    if best is None:
        raise RegistryWorkerError(
            "unsafe-filesystem", "registry filesystem cannot be classified"
        )
    return best[1]


def _darwin_filesystem(path: str) -> tuple[str, bool]:
    """Return Darwin filesystem type and `statfs64(2)' MNT_LOCAL for PATH."""
    libc = ctypes.CDLL(None, use_errno=True)
    statfs64 = libc.statfs64
    statfs64.argtypes = [ctypes.c_char_p, ctypes.POINTER(_DarwinStatFs64)]
    statfs64.restype = ctypes.c_int
    information = _DarwinStatFs64()
    if statfs64(os.fsencode(path), ctypes.byref(information)) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), path)
    filesystem = bytes(information.f_fstypename).split(b"\0", 1)[0].decode("ascii", "strict")
    return filesystem, bool(information.f_flags & 0x00001000)


def _assert_local_filesystem(path: str) -> None:
    """Reject registry storage lacking intended-platform local-disk semantics."""
    try:
        if sys.platform.startswith("linux"):
            local = _linux_filesystem_type(path) in _LINUX_LOCAL_FILESYSTEMS
        elif sys.platform == "darwin":
            filesystem, is_local = _darwin_filesystem(path)
            local = is_local and filesystem == "apfs"
        else:
            local = False
    except RegistryWorkerError:
        raise
    except BaseException as error:
        raise RegistryWorkerError(
            "unsafe-filesystem", "registry filesystem cannot be classified"
        ) from error
    if not local:
        raise RegistryWorkerError(
            "unsafe-filesystem", "registry must reside on a supported local filesystem"
        )


def _fsync_directory(path: str) -> None:
    """Fsync the exact private directory opened at PATH without following symlinks."""
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        _assert_private_directory_stat(os.fstat(descriptor))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _ensure_private_parent(path: str) -> str:
    parent = os.path.dirname(path)
    _assert_no_symlink_components(parent)
    missing: list[str] = []
    cursor = parent
    while not os.path.exists(cursor):
        missing.append(cursor)
        next_cursor = os.path.dirname(cursor)
        if next_cursor == cursor:
            raise RegistryWorkerError("unsafe-path", "registry parent cannot be created")
        cursor = next_cursor
    if _path_is_symlink(cursor):
        raise RegistryWorkerError("unsafe-path", "registry parent must not traverse a symlink")
    _assert_private_directory(cursor)
    _assert_local_filesystem(cursor)
    for directory in reversed(missing):
        containing_directory = os.path.dirname(directory)
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            raise RegistryWorkerError("unsafe-path", "registry parent cannot be created") from error
        if _path_is_symlink(directory):
            raise RegistryWorkerError("unsafe-path", "registry parent must not traverse a symlink")
        _assert_private_directory(directory)
        try:
            _fsync_directory(containing_directory)
        except BaseException as error:
            raise RegistryWorkerError(
                "unsafe-path", "registry parent creation could not be made durable"
            ) from error
    _assert_private_directory(parent)
    _assert_local_filesystem(parent)
    return parent


class RegistryTransaction:
    """A single nonblocking advisory-lock transaction for one registry path."""

    def __init__(
        self,
        path: str,
        *,
        before_replace: Callable[[str, str], None] | None = None,
    ):
        self.path = _validate_path(path)
        self.parent = _ensure_private_parent(self.path)
        self.lock_path = f"{self.path}.lock"
        self.before_replace = before_replace

    def _open_lock(self, shared: bool) -> int:
        if _path_is_symlink(self.lock_path):
            raise RegistryWorkerError("unsafe-path", "registry lock must not be a symlink")
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.lock_path, flags, 0o600)
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise RegistryWorkerError("unsafe-path", "registry lock must not be a symlink") from error
            raise RegistryWorkerError("unsafe-path", "registry lock cannot be opened") from error
        try:
            _assert_private_regular_stat(os.fstat(descriptor), "registry lock")
            os.fchmod(descriptor, 0o600)
            try:
                mode = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
                fcntl.flock(descriptor, mode | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise BusyError() from error
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @staticmethod
    def _close_lock(descriptor: int) -> None:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)

    def _read_state(self) -> dict[str, Any]:
        if _path_is_symlink(self.path):
            raise RegistryWorkerError("unsafe-path", "registry must not be a symlink")
        try:
            # A blocking open would hang forever on a FIFO before `fstat'
            # can reject it.  Regular-file reads are unaffected.
            flags = os.O_RDONLY | os.O_NONBLOCK
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(self.path, flags)
        except FileNotFoundError:
            return {"v": REGISTRY_VERSION, "generation": 0, "entries": []}
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise RegistryWorkerError("unsafe-path", "registry must not be a symlink") from error
            raise RegistryWorkerError("unsafe-path", "registry cannot be opened") from error
        try:
            info = os.fstat(descriptor)
            _assert_private_regular_stat(info, "registry")
            if info.st_size > MAX_REGISTRY_BYTES:
                raise CorruptRegistryError("registry-too-large")
            chunks: list[bytes] = []
            remaining = info.st_size
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    raise CorruptRegistryError()
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
        finally:
            os.close(descriptor)
        if not raw:
            raise CorruptRegistryError()
        state = _parse_json(raw, CorruptRegistryError)
        if not isinstance(state, dict) or set(state) != {"v", "generation", "entries"}:
            raise CorruptRegistryError()
        if state["v"] != REGISTRY_VERSION or not _is_integer(state["generation"]):
            raise CorruptRegistryError()
        if state["generation"] < 0 or state["generation"] > MAX_SAFE_JSON_INTEGER:
            raise CorruptRegistryError()
        if not isinstance(state["entries"], list) or len(state["entries"]) > MAX_ENTRIES:
            raise CorruptRegistryError()
        entries = [_validate_stored_entry(entry) for entry in state["entries"]]
        keys = [entry["key"] for entry in entries]
        if len(set(keys)) != len(keys):
            raise CorruptRegistryError()
        validated = {
            "v": REGISTRY_VERSION,
            "generation": state["generation"],
            "entries": entries,
        }
        if len(_canonical_json(validated)) > MAX_REGISTRY_BYTES:
            raise CorruptRegistryError("registry-too-large")
        return validated

    def _fsync_parent(self) -> None:
        try:
            _fsync_directory(self.parent)
        except BaseException as error:
            raise RegistryWorkerError(
                "durability-uncertain",
                "registry replacement completed but directory fsync failed",
                committed=True,
            ) from error

    def _write_state(self, state: dict[str, Any]) -> None:
        raw = _canonical_json(state)
        if len(raw) > MAX_REGISTRY_BYTES:
            raise RegistryWorkerError("write-failed", "updated registry would exceed its size limit")
        temporary: str | None = None
        descriptor: int | None = None
        replaced = False
        try:
            descriptor, temporary = tempfile.mkstemp(
                prefix=f".{os.path.basename(self.path)}.", suffix=".tmp", dir=self.parent
            )
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(raw):
                written = os.write(descriptor, raw[offset:])
                if written <= 0:
                    raise OSError("short registry write")
                offset += written
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            if self.before_replace is not None:
                try:
                    self.before_replace(temporary, self.path)
                except BaseException as error:
                    raise RegistryWorkerError(
                        "write-failed", "registry write failed before replacement"
                    ) from error
            os.replace(temporary, self.path)
            replaced = True
            temporary = None
            self._fsync_parent()
        except RegistryWorkerError as error:
            if replaced and not error.committed:
                raise RegistryWorkerError(
                    "durability-uncertain",
                    "registry replacement completed but final validation failed",
                    committed=True,
                ) from error
            raise
        except BaseException as error:
            if replaced:
                raise RegistryWorkerError(
                    "durability-uncertain",
                    "registry replacement completed but finalization failed",
                    committed=True,
                ) from error
            raise RegistryWorkerError(
                "write-failed", "registry could not be atomically written"
            ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass

    @staticmethod
    def _find_entry(state: dict[str, Any], key: str) -> tuple[int | None, dict[str, Any] | None]:
        for index, entry in enumerate(state["entries"]):
            if entry["key"] == key:
                return index, entry
        return None, None

    @staticmethod
    def _find_local_file_entry(
        state: dict[str, Any], local_file: str
    ) -> dict[str, Any] | None:
        wanted = _local_path_identity(local_file)
        for entry in state["entries"]:
            identity = _local_file_identity(entry)
            if identity is not None and _same_local_file(wanted, identity):
                return entry
        return None

    def _commit(self, state: dict[str, Any]) -> int:
        if state["generation"] >= MAX_SAFE_JSON_INTEGER:
            raise RegistryWorkerError(
                "generation-exhausted", "registry generation counter is exhausted"
            )
        state["generation"] += 1
        self._write_state(state)
        return state["generation"]

    def _create_if_absent(self, state: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        entry = _new_entry(request["entry"])
        _index, current = self._find_entry(state, entry["key"])
        if current is not None:
            raise ConflictError()
        _assert_unique_local_files([*state["entries"], entry])
        if len(state["entries"]) >= MAX_ENTRIES:
            raise RegistryWorkerError("capacity", "registry has reached its entry limit")
        state["entries"].append(entry)
        return {"generation": self._commit(state), "entry": entry}

    def _replace_if_revision(self, state: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        entry = _new_entry(request["entry"])
        expected = _validate_revision(request["expected_revision"])
        index, current = self._find_entry(state, entry["key"])
        if current is None or current["revision"] != expected:
            raise ConflictError()
        _assert_unique_local_files(
            [existing for existing in state["entries"] if existing["key"] != entry["key"]]
            + [entry]
        )
        state["entries"][index] = entry
        return {"generation": self._commit(state), "entry": entry}

    def _upsert_if_current(self, state: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        entry = _new_entry(request["entry"])
        expected = request["expected_revision"]
        if expected is not None:
            expected = _validate_revision(expected)
        index, current = self._find_entry(state, entry["key"])
        if current is None:
            if expected is not None:
                raise ConflictError()
            _assert_unique_local_files([*state["entries"], entry])
            if len(state["entries"]) >= MAX_ENTRIES:
                raise RegistryWorkerError("capacity", "registry has reached its entry limit")
            state["entries"].append(entry)
            return {"generation": self._commit(state), "entry": entry, "created": True}
        if expected is None or current["revision"] != expected:
            raise ConflictError()
        _assert_unique_local_files(
            [existing for existing in state["entries"] if existing["key"] != entry["key"]]
            + [entry]
        )
        state["entries"][index] = entry
        return {"generation": self._commit(state), "entry": entry, "created": False}

    def _remove_if_revision(self, state: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        key = _validate_key(request["key"])
        expected = _validate_revision(request["expected_revision"])
        index, current = self._find_entry(state, key)
        if current is None or current["revision"] != expected:
            raise ConflictError()
        del state["entries"][index]
        return {"generation": self._commit(state), "removed": key}

    def _prune_if_revision(self, state: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        targets = request["targets"]
        if not isinstance(targets, list) or not targets or len(targets) > MAX_ENTRIES:
            raise RegistryWorkerError("invalid-request", "prune targets are invalid")
        expected: dict[str, str] = {}
        for target in targets:
            if not isinstance(target, dict) or set(target) != {"key", "expected_revision"}:
                raise RegistryWorkerError("invalid-request", "prune target is invalid")
            key = _validate_key(target["key"])
            if key in expected:
                raise RegistryWorkerError("invalid-request", "prune target is duplicated")
            expected[key] = _validate_revision(target["expected_revision"])
        removed: list[str] = []
        retained: list[str] = []
        kept: list[dict[str, Any]] = []
        found: set[str] = set()
        for entry in state["entries"]:
            key = entry["key"]
            if key not in expected:
                kept.append(entry)
                continue
            found.add(key)
            if entry["revision"] == expected[key]:
                removed.append(key)
            else:
                retained.append(key)
                kept.append(entry)
        retained.extend(key for key in expected if key not in found)
        if removed:
            state["entries"] = kept
            generation = self._commit(state)
        else:
            generation = state["generation"]
        return {"generation": generation, "removed": removed, "retained": retained}

    def execute(self, request: dict[str, Any]) -> dict[str, Any]:
        operation = request["op"]
        descriptor = self._open_lock(
            shared=operation in {"read", "read-for-local-file"}
        )
        result: dict[str, Any] | None = None
        primary_error: BaseException | None = None
        generation_before: int | None = None
        try:
            state = self._read_state()
            generation_before = state["generation"]
            if operation == "read":
                result = {"generation": state["generation"], "entries": state["entries"]}
            elif operation == "read-for-local-file":
                local_file = _validate_local_file(request["local_file"])
                result = {
                    "generation": state["generation"],
                    "entries": state["entries"],
                    "matching_entry": self._find_local_file_entry(state, local_file),
                }
            elif operation == "create-if-absent":
                result = self._create_if_absent(state, request)
            elif operation == "replace-if-revision":
                result = self._replace_if_revision(state, request)
            elif operation == "upsert-if-current":
                result = self._upsert_if_current(state, request)
            elif operation == "remove-if-revision":
                result = self._remove_if_revision(state, request)
            elif operation == "prune-if-revision":
                result = self._prune_if_revision(state, request)
            else:
                raise RegistryWorkerError("invalid-request", "registry operation is unsupported")
        except BaseException as error:
            primary_error = error
        committed = bool(
            isinstance(primary_error, RegistryWorkerError) and primary_error.committed
        ) or bool(
            result is not None
            and generation_before is not None
            and result.get("generation", generation_before) > generation_before
        )
        try:
            self._close_lock(descriptor)
        except BaseException as error:
            if primary_error is None:
                primary_error = RegistryWorkerError(
                    "durability-uncertain" if committed else "lock-release",
                    (
                        "registry mutation committed but its lock could not be released cleanly"
                        if committed
                        else "registry lock could not be released cleanly"
                    ),
                    committed=committed,
                )
                primary_error.__cause__ = error
        if primary_error is not None:
            raise primary_error
        assert result is not None
        return result


_OPERATION_FIELDS = {
    "read": {"v", "op", "path"},
    "read-for-local-file": {"v", "op", "path", "local_file"},
    "create-if-absent": {"v", "op", "path", "entry"},
    "replace-if-revision": {"v", "op", "path", "entry", "expected_revision"},
    "upsert-if-current": {"v", "op", "path", "entry", "expected_revision"},
    "remove-if-revision": {"v", "op", "path", "key", "expected_revision"},
    "prune-if-revision": {"v", "op", "path", "targets"},
}


def _validate_local_file(value: Any) -> str:
    if not isinstance(value, str) or "\x00" in value or not os.path.isabs(value):
        raise RegistryWorkerError("invalid-request", "local source path must be absolute")
    if _validate_text(value, "local source path is invalid") > MAX_PATH_BYTES:
        raise RegistryWorkerError("invalid-request", "local source path is too large")
    return value


def _validate_request(value: Any) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or not _is_integer(value.get("v"))
        or value.get("v") != PROTOCOL_VERSION
    ):
        raise RegistryWorkerError("invalid-request", "registry request has an invalid version")
    operation = value.get("op")
    if not isinstance(operation, str):
        raise RegistryWorkerError("invalid-request", "registry operation is invalid")
    expected_fields = _OPERATION_FIELDS.get(operation)
    if expected_fields is None or set(value) != expected_fields:
        raise RegistryWorkerError("invalid-request", "registry request has invalid fields")
    _validate_path(value["path"])
    if operation == "read-for-local-file":
        _validate_local_file(value["local_file"])
    return value


def execute_request(
    request: dict[str, Any], *, before_replace: Callable[[str, str], None] | None = None
) -> dict[str, Any]:
    """Execute REQUEST and return one bounded protocol response dictionary."""
    try:
        request = _validate_request(request)
        result = RegistryTransaction(request["path"], before_replace=before_replace).execute(request)
        response: dict[str, Any] = {"v": PROTOCOL_VERSION, "ok": True, "result": result}
    except RegistryWorkerError as error:
        response = {
            "v": PROTOCOL_VERSION,
            "ok": False,
            "error": {"code": error.code, "message": error.message},
        }
        if error.committed:
            response["committed"] = True
    except BaseException:
        response = {
            "v": PROTOCOL_VERSION,
            "ok": False,
            "error": {"code": "internal", "message": "registry transaction failed safely"},
        }
    try:
        if len(_canonical_json(response)) > MAX_RESPONSE_BYTES:
            return {
                "v": PROTOCOL_VERSION,
                "ok": False,
                "error": {"code": "result-too-large", "message": "registry response exceeds its limit"},
            }
    except BaseException:
        return {
            "v": PROTOCOL_VERSION,
            "ok": False,
            "error": {"code": "internal", "message": "registry transaction failed safely"},
        }
    return response


def _read_request_from_stdin() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        raise RegistryWorkerError("request-too-large", "registry request exceeds its limit")
    return _validate_request(_parse_json(raw, lambda: RegistryWorkerError(
        "invalid-request", "registry request is not valid JSON"
    )))


def _write_response(response: dict[str, Any]) -> None:
    raw = _canonical_json(response)
    if len(raw) > MAX_RESPONSE_BYTES:
        raw = _canonical_json(
            {
                "v": PROTOCOL_VERSION,
                "ok": False,
                "error": {"code": "result-too-large", "message": "registry response exceeds its limit"},
            }
        )
    # The newline is the response frame boundary used by the Emacs bridge.
    # JSON strings escape embedded newlines, so it is unambiguous.
    sys.stdout.buffer.write(raw + b"\n")
    sys.stdout.buffer.flush()


def main() -> int:
    """Run one request from stdin and emit exactly one JSON response."""
    try:
        request = _read_request_from_stdin()
        response = execute_request(request)
    except RegistryWorkerError as error:
        response = {
            "v": PROTOCOL_VERSION,
            "ok": False,
            "error": {"code": error.code, "message": error.message},
        }
    except BaseException:
        response = {
            "v": PROTOCOL_VERSION,
            "ok": False,
            "error": {"code": "internal", "message": "registry transaction failed safely"},
        }
    _write_response(response)
    return 0
