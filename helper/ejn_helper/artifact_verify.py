"""Verify an original and create a durable external-viewer snapshot.

This script has no package imports and no output protocol.  Exit status zero
means that a panel-owned original was pinned, verified, copied byte-for-byte
into a caller-created private directory, and the completed snapshot was
fsynced.  The viewer can therefore consume the snapshot after the
original lease has been released.
"""

from __future__ import annotations

import hashlib
import os
import stat
import sys

MAX_ORIGINAL_BYTES = 67_108_864
_READ_SIZE = 65_536

# Fixed exit statuses are the verifier's only diagnostic surface.  They expose
# the failed safety stage without copying paths or exception text across the
# process boundary.
STATUS_OK = 0
STATUS_INVALID_REQUEST = 2
STATUS_UNSAFE_PATH = 3
STATUS_ORIGINAL_ROOT = 4
STATUS_SNAPSHOT_ROOT = 5
STATUS_ORIGINAL_FILE = 6
STATUS_SNAPSHOT_CREATE = 7
STATUS_COPY_IO = 8
STATUS_CONTENT_MISMATCH = 9
STATUS_FINAL_IDENTITY = 10


def _integer(value: str) -> int:
    parsed = int(value, 10)
    if parsed < 0:
        raise ValueError("negative metadata")
    return parsed


def _private_directory_metadata(metadata: os.stat_result, uid: int) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o700
        and metadata.st_uid == uid
    )


def _original_metadata(
    metadata: os.stat_result,
    uid: int,
    device: int,
    inode: int,
    size: int,
) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_uid == uid
        and metadata.st_nlink == 1
        and metadata.st_size == size
        and (metadata.st_dev, metadata.st_ino) == (device, inode)
    )


def _snapshot_metadata(metadata: os.stat_result, uid: int, size: int) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_uid == uid
        and metadata.st_nlink == 1
        and metadata.st_size == size
    )


def _write_all(fd: int, block: bytes) -> None:
    view = memoryview(block)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("snapshot write made no progress")
        view = view[written:]


def _unlink_snapshot(snapshot_fd: int | None, destination_name: str | None) -> None:
    if snapshot_fd is None or destination_name is None:
        return
    try:
        os.unlink(destination_name, dir_fd=snapshot_fd)
    except OSError:
        pass


def verification_status(argv: list[str]) -> int:
    """Create the requested snapshot and return a fixed verification status.

    ``argv`` includes the script name followed by original root/path and their
    pinned device/inode metadata, expected original size/hash, then the
    caller-created snapshot root and its immediate-child destination path.
    """
    if len(argv) != 11:
        return STATUS_INVALID_REQUEST
    root, path = argv[1], argv[2]
    destination_name: str | None = None
    root_fd: int | None = None
    file_fd: int | None = None
    snapshot_fd: int | None = None
    destination_fd: int | None = None
    destination_created = False
    completed = False
    failure_status = STATUS_INVALID_REQUEST
    try:
        root_device, root_inode = _integer(argv[3]), _integer(argv[4])
        file_device, file_inode = _integer(argv[5]), _integer(argv[6])
        expected_size = _integer(argv[7])
        expected_sha256 = argv[8]
        snapshot_root, destination = argv[9], argv[10]
        if (
            expected_size > MAX_ORIGINAL_BYTES
            or len(expected_sha256) != 64
            or any(character not in "0123456789abcdef" for character in expected_sha256)
        ):
            return STATUS_INVALID_REQUEST
        if (
            not os.path.isabs(root)
            or not os.path.isabs(path)
            or not os.path.isabs(snapshot_root)
            or not os.path.isabs(destination)
            or os.path.normpath(root) != root
            or os.path.normpath(path) != path
            or os.path.normpath(snapshot_root) != snapshot_root
            or os.path.normpath(destination) != destination
            or os.path.dirname(path) != root
            or os.path.dirname(destination) != snapshot_root
            or root == snapshot_root
        ):
            return STATUS_UNSAFE_PATH
        destination_name = os.path.basename(destination)
        if destination_name in {"", ".", ".."}:
            return STATUS_UNSAFE_PATH

        expected_uid = os.geteuid()
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        read_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        read_flags |= getattr(os, "O_NOFOLLOW", 0)
        write_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        write_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

        failure_status = STATUS_ORIGINAL_ROOT
        root_fd = os.open(root, directory_flags)
        root_metadata = os.fstat(root_fd)
        if not _private_directory_metadata(root_metadata, expected_uid) or (
            root_metadata.st_dev,
            root_metadata.st_ino,
        ) != (root_device, root_inode):
            return STATUS_ORIGINAL_ROOT

        failure_status = STATUS_SNAPSHOT_ROOT
        snapshot_fd = os.open(snapshot_root, directory_flags)
        snapshot_metadata = os.fstat(snapshot_fd)
        if not _private_directory_metadata(snapshot_metadata, expected_uid) or (
            snapshot_metadata.st_dev,
            snapshot_metadata.st_ino,
        ) == (root_metadata.st_dev, root_metadata.st_ino):
            return STATUS_SNAPSHOT_ROOT

        failure_status = STATUS_ORIGINAL_FILE
        file_fd = os.open(os.path.basename(path), read_flags, dir_fd=root_fd)
        original_metadata = os.fstat(file_fd)
        if not _original_metadata(
            original_metadata,
            expected_uid,
            file_device,
            file_inode,
            expected_size,
        ):
            return STATUS_ORIGINAL_FILE

        failure_status = STATUS_SNAPSHOT_CREATE
        destination_fd = os.open(destination_name, write_flags, 0o600, dir_fd=snapshot_fd)
        destination_created = True
        failure_status = STATUS_COPY_IO
        digest = hashlib.sha256()
        remaining = expected_size
        while remaining:
            block = os.read(file_fd, min(_READ_SIZE, remaining))
            if not block:
                return STATUS_CONTENT_MISMATCH
            remaining -= len(block)
            digest.update(block)
            _write_all(destination_fd, block)
        if os.read(file_fd, 1) or digest.hexdigest() != expected_sha256:
            return STATUS_CONTENT_MISMATCH
        os.fsync(destination_fd)

        failure_status = STATUS_FINAL_IDENTITY
        final_file = os.fstat(file_fd)
        final_root = os.fstat(root_fd)
        final_snapshot_root = os.fstat(snapshot_fd)
        final_destination = os.fstat(destination_fd)
        if not (
            _original_metadata(
                final_file,
                expected_uid,
                file_device,
                file_inode,
                expected_size,
            )
            and _private_directory_metadata(final_root, expected_uid)
            and (final_root.st_dev, final_root.st_ino) == (root_device, root_inode)
            and _private_directory_metadata(final_snapshot_root, expected_uid)
            and (final_snapshot_root.st_dev, final_snapshot_root.st_ino)
            == (snapshot_metadata.st_dev, snapshot_metadata.st_ino)
            and _snapshot_metadata(final_destination, expected_uid, expected_size)
        ):
            return STATUS_FINAL_IDENTITY
        completed = True
        return STATUS_OK
    except (OSError, ValueError):
        return failure_status
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        if destination_created and not completed:
            _unlink_snapshot(snapshot_fd, destination_name)
        if file_fd is not None:
            os.close(file_fd)
        if snapshot_fd is not None:
            os.close(snapshot_fd)
        if root_fd is not None:
            os.close(root_fd)


def verify(argv: list[str]) -> bool:
    """Create the requested durable snapshot iff all identities still match."""
    try:
        return verification_status(argv) == STATUS_OK
    except (OSError, ValueError):
        return False


def main() -> int:
    try:
        return verification_status(sys.argv)
    except (OSError, ValueError):
        return STATUS_COPY_IO


if __name__ == "__main__":
    raise SystemExit(main())
