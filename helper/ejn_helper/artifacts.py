"""Secure, bounded artifact spooling for decoded Jupyter MIME payloads."""

from __future__ import annotations

import base64
import binascii
import errno
import hashlib
import os
import secrets
import stat
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO

from ejn_array import ArrayFormatError, read_manifest

from .image_metadata import (
    EJN_IMAGE_HEADER_SCAN_BYTES,
    EJN_MAX_IMAGE_PIXELS,
    parse_image_metadata,
)
from .thumbnail import ThumbnailError, run_worker, validate_ppm_fd

EJN_MAX_ARTIFACT_BYTES = 67_108_864
_BASE64_CHUNK_BYTES = 65_536


def _fsync_directory(directory_fd: int) -> None:
    """Durably publish a renamed artifact where the platform supports it.

    File contents are always fsynced before rename.  Darwin filesystems may
    reject a directory descriptor with ``EINVAL`` or ``ENOTSUP`` even though
    the rename itself succeeded; those two errors are the sole portability
    exception.  Every other platform and error remains fail-closed.
    """
    try:
        os.fsync(directory_fd)
    except OSError as exc:
        if sys.platform == "darwin" and exc.errno in {errno.EINVAL, errno.ENOTSUP}:
            return
        raise


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
    _lease: _PublicationLease = field(repr=False, compare=False)


@dataclass(frozen=True, slots=True)
class PublishedImage:
    """One logical image handoff with independently pinned files.

    The compressed original is always present.  ``preview`` is an optional
    canonical PPM generated only by the constrained child worker.  Both carry
    distinct private leases, so caller rollback is all-or-nothing while panel
    ownership can retire them as a single logical bundle.
    """

    original: PublishedArtifact
    preview: PublishedArtifact | None
    width: int | None = None
    height: int | None = None


@dataclass(frozen=True, slots=True)
class PublishedArray:
    """One store-owned numerical group and its bounded validated header."""

    original: PublishedArtifact
    manifest: dict


@dataclass(frozen=True, slots=True)
class _PublicationLease:
    """Store-private identity for a publication not yet handed to Emacs."""

    store_token: object = field(repr=False, compare=False)
    relative_name: str = field(repr=False)
    device: int = field(repr=False)
    inode: int = field(repr=False)


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
        # This identity is deliberately never serialized into a backend event.
        # A caller that only has an advertised path cannot ask us to unlink it.
        self._lease_token = object()

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

    def discard(self, published: PublishedArtifact) -> bool:
        """Discard a publication that never crossed the local admission gate.

        ``published`` must be the exact object returned by this store.  The
        lookup uses only the store-minted relative name through the pinned
        directory descriptor and also pins the originally published inode.
        It therefore never follows or trusts an event's advertised path.
        """
        if not isinstance(published, PublishedArtifact):
            raise ArtifactIOError("artifact discard needs a store publication")
        lease = published._lease
        if lease.store_token is not self._lease_token:
            raise ArtifactIOError("artifact discard belongs to another store")
        directory_fd = self._require_open()
        self._validate_pinned_directory(directory_fd)
        try:
            metadata = os.stat(
                lease.relative_name, dir_fd=directory_fd, follow_symlinks=False
            )
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise ArtifactIOError("artifact discard failed") from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or (metadata.st_dev, metadata.st_ino) != (lease.device, lease.inode)
        ):
            # A same-directory race must not turn an internal cleanup into an
            # unlink of a replacement file.
            return False
        try:
            os.unlink(lease.relative_name, dir_fd=directory_fd)
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise ArtifactIOError("artifact discard failed") from exc
        return True

    def _validate_published_fd(self, published: PublishedArtifact) -> int:
        """Open one store-owned published file and pin its original bytes."""
        if not isinstance(published, PublishedArtifact):
            raise ArtifactIOError("thumbnail input needs a store publication")
        lease = published._lease
        if lease.store_token is not self._lease_token:
            raise ArtifactIOError("thumbnail input belongs to another store")
        directory_fd = self._require_open()
        self._validate_pinned_directory(directory_fd)
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(lease.relative_name, flags, dir_fd=directory_fd)
            metadata = os.fstat(fd)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink != 1
                or (metadata.st_dev, metadata.st_ino) != (lease.device, lease.inode)
                or metadata.st_size != published.byte_count
            ):
                raise ArtifactIOError("thumbnail input identity changed")
            digest = hashlib.sha256()
            while True:
                block = os.read(fd, _BASE64_CHUNK_BYTES)
                if not block:
                    break
                digest.update(block)
            if digest.hexdigest() != published.sha256:
                raise ArtifactIOError("thumbnail input content changed")
            os.lseek(fd, 0, os.SEEK_SET)
            return fd
        except Exception:
            try:
                os.close(fd)
            except (OSError, UnboundLocalError):
                pass
            raise

    @staticmethod
    def _hash_fd(fd: int) -> str:
        digest = hashlib.sha256()
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            block = os.read(fd, _BASE64_CHUNK_BYTES)
            if not block:
                break
            digest.update(block)
        os.lseek(fd, 0, os.SEEK_SET)
        return digest.hexdigest()

    def _publish_preview_fd(self, partial_name: str, file_fd: int) -> PublishedArtifact:
        """Fsync and atomically publish a PPM preview already written to FD."""
        directory_fd = self._require_open()
        self._validate_pinned_directory(directory_fd)
        width, height, byte_count = validate_ppm_fd(file_fd)
        del width, height  # Dimension metadata is returned by the caller.
        partial_metadata = os.fstat(file_fd)
        partial_identity = (partial_metadata.st_dev, partial_metadata.st_ino)
        published_identity: tuple[int, int] | None = None
        published_name: str | None = None
        try:
            os.fchmod(file_fd, 0o600)
            os.fsync(file_fd)
            digest = self._hash_fd(file_fd)
            published_name = self._random_name("ejn-artifact-")
            os.stat(published_name, dir_fd=directory_fd, follow_symlinks=False)
            raise ArtifactIOError("artifact publication name already exists")
        except FileNotFoundError:
            pass
        except ArtifactError:
            raise
        except OSError as exc:
            raise ArtifactIOError("preview publication failed") from exc
        try:
            self._validate_pinned_directory(directory_fd)
            os.replace(
                partial_name,
                published_name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            # Rename preserves the inode.  Record it before any subsequent
            # stat/fsync can fail so rollback still owns the published name.
            published_identity = partial_identity
            metadata = os.stat(published_name, dir_fd=directory_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink != 1
                or metadata.st_size != byte_count
                or (metadata.st_dev, metadata.st_ino) != partial_identity
            ):
                raise ArtifactIOError("preview publication is unsafe")
            # A file fsync is not sufficient to durably publish the name.
            _fsync_directory(directory_fd)
            return PublishedArtifact(
                path=self._directory / published_name,
                byte_count=byte_count,
                sha256=digest,
                _lease=_PublicationLease(
                    self._lease_token,
                    published_name,
                    metadata.st_dev,
                    metadata.st_ino,
                ),
            )
        except Exception:
            if published_name is not None and published_identity is not None:
                try:
                    current = os.stat(
                        published_name, dir_fd=directory_fd, follow_symlinks=False
                    )
                    if (current.st_dev, current.st_ino) == published_identity:
                        os.unlink(published_name, dir_fd=directory_fd)
                        _fsync_directory(directory_fd)
                except OSError:
                    pass
            raise

    def make_array(self, payload: str) -> PublishedArray:
        """Spool and validate a numerical group in the sole artifact worker.

        Validation never allocates plane arrays. Rollback is owned here until
        a successful return transfers the exact publication to the caller.
        """
        original = self.store_base64(payload)
        fd: int | None = None
        try:
            fd = self._validate_published_fd(original)
            before = os.fstat(fd)
            # The file object borrows the already pinned fd.
            with os.fdopen(fd, "rb", closefd=False) as stream:
                manifest, _offset = read_manifest(stream, before.st_size)
            after = os.fstat(fd)
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                    after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ArtifactDataError("numerical artifact changed during validation")
            return PublishedArray(original, manifest)
        except Exception as exc:
            self.discard(original)
            if isinstance(exc, ArrayFormatError):
                raise ArtifactDataError("invalid numerical artifact") from exc
            raise
        finally:
            if fd is not None:
                os.close(fd)

    def make_image(self, payload: str, mime: str, *, max_source_pixels: int = EJN_MAX_IMAGE_PIXELS) -> PublishedImage:
        """Publish PAYLOAD and, when safe, attach one constrained PPM preview.

        All worker/preflight failures are deliberately non-fatal to the
        original artifact.  That leaves an external-viewer-only descriptor;
        publication failures before the original exists still raise normally.
        """
        original = self.store_base64(payload)
        if (
            mime not in {"image/png", "image/jpeg"}
            or type(max_source_pixels) is not int
            or max_source_pixels <= 0
            or max_source_pixels > EJN_MAX_IMAGE_PIXELS
        ):
            return PublishedImage(original, None)
        input_fd: int | None = None
        output_fd: int | None = None
        partial_name: str | None = None
        partial_identity: tuple[int, int] | None = None
        try:
            input_fd = self._validate_published_fd(original)
            prefix = os.read(input_fd, EJN_IMAGE_HEADER_SCAN_BYTES)
            metadata = parse_image_metadata(prefix)
            if (
                metadata is None
                or metadata.mime != mime
                or metadata.width * metadata.height > max_source_pixels
            ):
                return PublishedImage(original, None)
            os.lseek(input_fd, 0, os.SEEK_SET)
            directory_fd = self._require_open()
            self._validate_pinned_directory(directory_fd)
            partial_name = self._random_name(".ejn-partial-")
            flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
            flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            output_fd = os.open(partial_name, flags, 0o600, dir_fd=directory_fd)
            output_metadata = os.fstat(output_fd)
            partial_identity = (output_metadata.st_dev, output_metadata.st_ino)
            run_worker(input_fd, output_fd)
            width, height, _size = validate_ppm_fd(output_fd)
            preview = self._publish_preview_fd(partial_name, output_fd)
            partial_name = None
            return PublishedImage(original, preview, width, height)
        # The child boundary is intentionally fail-closed: an unexpected
        # launcher failure is equivalent to a corrupt/invalid preview.
        except Exception:
            return PublishedImage(original, None)
        finally:
            if input_fd is not None:
                try:
                    os.close(input_fd)
                except OSError:
                    pass
            if output_fd is not None:
                try:
                    os.close(output_fd)
                except OSError:
                    pass
            if partial_name is not None:
                try:
                    directory_fd = self._require_open()
                    current = os.stat(
                        partial_name, dir_fd=directory_fd, follow_symlinks=False
                    )
                    if partial_identity == (current.st_dev, current.st_ino):
                        os.unlink(partial_name, dir_fd=directory_fd)
                except (ArtifactError, OSError):
                    pass

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
        published_created = False
        completed = False
        partial_identity: tuple[int, int] | None = None
        published_identity: tuple[int, int] | None = None
        result: PublishedArtifact | None = None
        byte_count = 0
        digest = hashlib.sha256()

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            file_fd = os.open(partial_name, flags, 0o600, dir_fd=directory_fd)
            partial_created = True
            partial_metadata = os.fstat(file_fd)
            partial_identity = (partial_metadata.st_dev, partial_metadata.st_ino)
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
            published_created = True
            published_identity = partial_identity
            metadata = os.stat(
                published_name, dir_fd=directory_fd, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink != 1
                or (metadata.st_dev, metadata.st_ino) != partial_identity
            ):
                raise ArtifactIOError("artifact publication is not a regular file")
            _fsync_directory(directory_fd)
            result = PublishedArtifact(
                path=self._directory / published_name,
                byte_count=byte_count,
                sha256=digest.hexdigest(),
                _lease=_PublicationLease(
                    self._lease_token,
                    published_name,
                    metadata.st_dev,
                    metadata.st_ino,
                ),
            )
            completed = True
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
            if partial_created and not published_created:
                try:
                    current = os.stat(
                        partial_name, dir_fd=directory_fd, follow_symlinks=False
                    )
                    if partial_identity == (current.st_dev, current.st_ino):
                        os.unlink(partial_name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
            if published_created and not completed:
                try:
                    current = os.stat(
                        published_name, dir_fd=directory_fd, follow_symlinks=False
                    )
                    if published_identity == (current.st_dev, current.st_ino):
                        os.unlink(published_name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass

        assert result is not None
        return result
