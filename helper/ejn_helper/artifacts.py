"""Secure, bounded artifact spooling for decoded Jupyter MIME payloads."""

from __future__ import annotations

import base64
import binascii
import hashlib
import os
import secrets
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

EJN_MAX_ARTIFACT_BYTES = 67_108_864
_BASE64_CHUNK_BYTES = 65_536


class ArtifactError(Exception):
    """Base class for safe artifact-store failures."""


class ArtifactDirectoryError(ArtifactError):
    """The configured artifact directory is unsafe or unavailable."""


class ArtifactDataError(ArtifactError):
    """The supplied artifact payload is malformed."""


class ArtifactTooLargeError(ArtifactDataError):
    """The decoded artifact exceeds the configured byte ceiling."""


class ArtifactIOError(ArtifactError):
    """An unpublished artifact could not be written or published."""


@dataclass(frozen=True, slots=True)
class PublishedArtifact:
    """Metadata for an atomically published artifact owned by Emacs."""

    path: Path
    byte_count: int
    sha256: str


def _write_all(stream: BinaryIO, data: bytes) -> None:
    """Write all DATA to STREAM, handling short raw writes."""
    view = memoryview(data)
    while view:
        written = stream.write(view)
        if written is None or written <= 0:
            raise OSError("artifact write made no progress")
        view = view[written:]


def _decoded_size(payload: str) -> int:
    """Return PAYLOAD's decoded size from its base64 shape.

    This preflight deliberately happens before a temporary file or decoded
    bytes are created.  Alphabet validation remains incremental in the write
    path.
    """
    if not isinstance(payload, str):
        raise ArtifactDataError("artifact payload must be a base64 string")
    if not payload.isascii():
        raise ArtifactDataError("artifact payload is not ASCII base64")
    length = len(payload)
    if length % 4:
        raise ArtifactDataError("artifact payload has invalid base64 length")
    padding = 2 if payload.endswith("==") else 1 if payload.endswith("=") else 0
    unpadded_end = length - padding
    first_padding = payload.find("=")
    if first_padding != -1 and first_padding != unpadded_end:
        raise ArtifactDataError("artifact payload has invalid base64 padding")
    return (length // 4) * 3 - padding


class ArtifactStore:
    """Publish bounded decoded artifacts inside one validated directory.

    The store owns only its directory descriptor and unpublished partials.
    Successfully published files deliberately survive :meth:`close`; Emacs
    owns their retention and deletion.
    """

    def __init__(
        self,
        directory: os.PathLike[str] | str,
        *,
        max_bytes: int = EJN_MAX_ARTIFACT_BYTES,
        expected_uid: int | None = None,
    ) -> None:
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int):
            raise ValueError("max_bytes must be an integer")
        if max_bytes < 0 or max_bytes > EJN_MAX_ARTIFACT_BYTES:
            raise ValueError("max_bytes must be within the protocol ceiling")

        path = Path(directory)
        if not path.is_absolute():
            raise ArtifactDirectoryError("artifact directory must be absolute")
        path_text = os.fspath(path)
        if os.path.abspath(path_text) != path_text:
            raise ArtifactDirectoryError("artifact directory must be normalized")
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise ArtifactDirectoryError(
                "artifact directory validation failed"
            ) from exc

        if expected_uid is None and hasattr(os, "geteuid"):
            expected_uid = os.geteuid()

        flags = os.O_RDONLY
        flags |= getattr(os, "O_DIRECTORY", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor: int | None = None
        try:
            before = os.lstat(path_text)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
                raise ArtifactDirectoryError(
                    "artifact directory is not a real directory"
                )
            canonical = os.lstat(resolved)
            if (before.st_dev, before.st_ino) != (
                canonical.st_dev,
                canonical.st_ino,
            ):
                raise ArtifactDirectoryError(
                    "artifact directory changed during validation"
                )
            descriptor = os.open(resolved, flags)
            opened = os.fstat(descriptor)
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise ArtifactDirectoryError(
                    "artifact directory changed during validation"
                )
            if expected_uid is not None and opened.st_uid != expected_uid:
                raise ArtifactDirectoryError("artifact directory has the wrong owner")
            if stat.S_IMODE(opened.st_mode) != 0o700:
                raise ArtifactDirectoryError("artifact directory mode must be 0700")
        except ArtifactDirectoryError:
            if descriptor is not None:
                os.close(descriptor)
            raise
        except OSError as exc:
            if descriptor is not None:
                os.close(descriptor)
            raise ArtifactDirectoryError(
                "artifact directory validation failed"
            ) from exc

        # Use the canonical path for every later validation and reported file.
        # This accepts Darwin's ordinary /var -> /private/var ancestry without
        # allowing that mutable spelling to redirect a published artifact.
        self._directory = resolved
        self._directory_fd = descriptor
        self._max_bytes = max_bytes
        self._expected_uid = expected_uid

    @property
    def directory(self) -> Path:
        """Return the absolute artifact directory supplied by Emacs."""
        return self._directory

    def close(self) -> None:
        """Close local store state without deleting published artifacts."""
        if self._directory_fd is not None:
            os.close(self._directory_fd)
            self._directory_fd = None

    def __enter__(self) -> ArtifactStore:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def _require_open(self) -> int:
        if self._directory_fd is None:
            raise ArtifactIOError("artifact store is closed")
        return self._directory_fd

    def _validate_pinned_directory(self, directory_fd: int) -> None:
        """Require the published pathname to still name the pinned directory."""
        try:
            current = os.lstat(self._directory)
            pinned = os.fstat(directory_fd)
        except OSError as exc:
            raise ArtifactDirectoryError(
                "artifact directory is no longer safe"
            ) from exc
        current_mode = stat.S_IMODE(current.st_mode)
        pinned_mode = stat.S_IMODE(pinned.st_mode)
        if (
            stat.S_ISLNK(current.st_mode)
            or not stat.S_ISDIR(current.st_mode)
            or not stat.S_ISDIR(pinned.st_mode)
            or (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino)
            or current.st_uid != pinned.st_uid
            or (
                self._expected_uid is not None
                and pinned.st_uid != self._expected_uid
            )
            or current_mode != 0o700
            or pinned_mode != 0o700
        ):
            raise ArtifactDirectoryError("artifact directory is no longer safe")

    @staticmethod
    def _random_name(prefix: str) -> str:
        return f"{prefix}{secrets.token_hex(16)}"

    def store_base64(self, payload: str) -> PublishedArtifact:
        """Decode and atomically publish one base64 PAYLOAD.

        Decoding is incremental.  No decoded bitmap-sized allocation is made,
        and no unpublished partial survives an error.
        """
        directory_fd = self._require_open()
        self._validate_pinned_directory(directory_fd)
        expected_size = _decoded_size(payload)
        if expected_size > self._max_bytes:
            raise ArtifactTooLargeError("artifact exceeds the byte limit")

        partial_name = self._random_name(".ejn-partial-")
        published_name = self._random_name("ejn-artifact-")
        file_fd: int | None = None
        stream: BinaryIO | None = None
        partial_created = False
        published = False
        byte_count = 0
        digest = hashlib.sha256()

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            file_fd = os.open(partial_name, flags, 0o600, dir_fd=directory_fd)
            partial_created = True
            stream = os.fdopen(file_fd, "wb", buffering=0)
            file_fd = None  # STREAM now owns it.

            for offset in range(0, len(payload), _BASE64_CHUNK_BYTES):
                encoded = payload[offset : offset + _BASE64_CHUNK_BYTES]
                try:
                    decoded = base64.b64decode(encoded.encode("ascii"), validate=True)
                except (binascii.Error, ValueError, UnicodeEncodeError) as exc:
                    raise ArtifactDataError(
                        "artifact payload is malformed base64"
                    ) from exc
                byte_count += len(decoded)
                if byte_count > self._max_bytes:
                    raise ArtifactTooLargeError("artifact exceeds the byte limit")
                digest.update(decoded)
                _write_all(stream, decoded)

            if byte_count != expected_size:
                raise ArtifactDataError("artifact payload decoded to an invalid size")
            os.fchmod(stream.fileno(), 0o600)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            stream = None
            self._validate_pinned_directory(directory_fd)
            try:
                os.stat(published_name, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ArtifactIOError("artifact publication name already exists")
            os.replace(
                partial_name,
                published_name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            published = True
        except ArtifactError:
            raise
        except (OSError, ValueError) as exc:
            raise ArtifactIOError("artifact publication failed") from exc
        finally:
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
            if file_fd is not None:
                try:
                    os.close(file_fd)
                except OSError:
                    pass
            if partial_created and not published:
                try:
                    os.unlink(partial_name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass

        return PublishedArtifact(
            path=self._directory / published_name,
            byte_count=byte_count,
            sha256=digest.hexdigest(),
        )
