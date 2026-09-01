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


def verify(argv: list[str]) -> bool:
    """Create the requested durable snapshot iff all identities still match.

    ``argv`` includes the script name followed by original root/path and their
    pinned device/inode metadata, expected original size/hash, then the
    caller-created snapshot root and its immediate-child destination path.
    """
    if len(argv) != 11:
        return False
    root, path = argv[1], argv[2]
    root_device, root_inode = _integer(argv[3]), _integer(argv[4])
    file_device, file_inode = _integer(argv[5]), _integer(argv[6])
    expected_size = _integer(argv[7])
    expected_sha256 = argv[8]
    snapshot_root, destination = argv[9], argv[10]
    destination_name: str | None = None
    root_fd: int | None = None
    file_fd: int | None = None
    snapshot_fd: int | None = None
    destination_fd: int | None = None
    destination_created = False
    completed = False
    try:
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
            or expected_size > MAX_ORIGINAL_BYTES
            or len(expected_sha256) != 64
            or any(character not in "0123456789abcdef" for character in expected_sha256)
        ):
            return False
        destination_name = os.path.basename(destination)
        if destination_name in {"", ".", ".."}:
            return False

        expected_uid = os.geteuid()
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        read_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        read_flags |= getattr(os, "O_NOFOLLOW", 0)
        write_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        write_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

        root_fd = os.open(root, directory_flags)
        root_metadata = os.fstat(root_fd)
        if not _private_directory_metadata(root_metadata, expected_uid) or (
            root_metadata.st_dev,
            root_metadata.st_ino,
        ) != (root_device, root_inode):
            return False

        snapshot_fd = os.open(snapshot_root, directory_flags)
        snapshot_metadata = os.fstat(snapshot_fd)
        if not _private_directory_metadata(snapshot_metadata, expected_uid) or (
            snapshot_metadata.st_dev,
            snapshot_metadata.st_ino,
        ) == (root_metadata.st_dev, root_metadata.st_ino):
            return False

        file_fd = os.open(os.path.basename(path), read_flags, dir_fd=root_fd)
        original_metadata = os.fstat(file_fd)
        if not _original_metadata(
            original_metadata,
            expected_uid,
            file_device,
            file_inode,
            expected_size,
        ):
            return False

        destination_fd = os.open(destination_name, write_flags, 0o600, dir_fd=snapshot_fd)
        destination_created = True
        digest = hashlib.sha256()
        remaining = expected_size
        while remaining:
            block = os.read(file_fd, min(_READ_SIZE, remaining))
            if not block:
                return False
            remaining -= len(block)
            digest.update(block)
            _write_all(destination_fd, block)
        if os.read(file_fd, 1) or digest.hexdigest() != expected_sha256:
            return False
        os.fsync(destination_fd)

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
            return False
        completed = True
        return True
    except (OSError, ValueError):
        return False
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


def main() -> int:
    try:
        return 0 if verify(sys.argv) else 1
    except (OSError, ValueError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
