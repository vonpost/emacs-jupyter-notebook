"""Filesystem and identity checks for the durable external-viewer snapshot."""

from __future__ import annotations

import hashlib
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ejn_helper import artifact_verify


class ArtifactVerifyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        temporary_root = Path(self.temporary.name)
        self.root = temporary_root / "artifacts"
        self.snapshot_root = temporary_root / "external-viewer"
        self.root.mkdir(mode=0o700)
        self.snapshot_root.mkdir(mode=0o700)
        self.path = self.root / "image.bin"
        self.destination = self.snapshot_root / "image.bin"
        self.payload = b"a small original image payload\x00\xff"
        self.path.write_bytes(self.payload)
        os.chmod(self.root, 0o700)
        os.chmod(self.snapshot_root, 0o700)
        os.chmod(self.path, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def argv_for(
        self,
        *,
        root: Path | None = None,
        path: Path | None = None,
        snapshot_root: Path | None = None,
        destination: Path | None = None,
        root_device: int | None = None,
        root_inode: int | None = None,
        file_device: int | None = None,
        file_inode: int | None = None,
        size: int | None = None,
        digest: str | None = None,
    ) -> list[str]:
        selected_root = self.root if root is None else root
        selected_path = self.path if path is None else path
        selected_snapshot_root = (
            self.snapshot_root if snapshot_root is None else snapshot_root
        )
        selected_destination = self.destination if destination is None else destination
        try:
            root_metadata = os.stat(selected_root)
        except OSError:
            root_metadata = os.stat(self.root)
        try:
            file_metadata = os.stat(selected_path)
        except OSError:
            file_metadata = os.stat(self.path)
        return [
            "artifact_verify.py",
            str(selected_root),
            str(selected_path),
            str(root_metadata.st_dev if root_device is None else root_device),
            str(root_metadata.st_ino if root_inode is None else root_inode),
            str(file_metadata.st_dev if file_device is None else file_device),
            str(file_metadata.st_ino if file_inode is None else file_inode),
            str(len(self.payload) if size is None else size),
            hashlib.sha256(self.payload).hexdigest() if digest is None else digest,
            str(selected_snapshot_root),
            str(selected_destination),
        ]

    def assert_rejected(self, argv: list[str]) -> None:
        with mock.patch.object(sys, "argv", argv):
            self.assertNotEqual(artifact_verify.main(), 0)

    def assert_no_snapshot(self) -> None:
        self.assertFalse(self.destination.exists())

    def test_valid_file_creates_exact_durable_private_snapshot(self) -> None:
        argv = self.argv_for()
        self.assertTrue(artifact_verify.verify(argv))
        self.assertEqual(self.destination.read_bytes(), self.payload)
        metadata = os.stat(self.destination)
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_uid, os.geteuid())
        self.assertEqual(metadata.st_nlink, 1)

        replacement = self.snapshot_root / "main-entry.bin"
        main_argv = self.argv_for(destination=replacement)
        with mock.patch.object(sys, "argv", main_argv):
            self.assertEqual(artifact_verify.main(), 0)
        self.assertEqual(replacement.read_bytes(), self.payload)

    def test_wrong_hash_size_or_original_identities_are_rejected(self) -> None:
        metadata = os.stat(self.path)
        root_metadata = os.stat(self.root)
        for argv in (
            self.argv_for(digest="0" * 64),
            self.argv_for(size=len(self.payload) + 1),
            self.argv_for(size=len(self.payload) - 1),
            self.argv_for(file_inode=metadata.st_ino + 1),
            self.argv_for(file_device=metadata.st_dev + 1),
            self.argv_for(root_inode=root_metadata.st_ino + 1),
            self.argv_for(root_device=root_metadata.st_dev + 1),
        ):
            self.assert_rejected(argv)
            self.assert_no_snapshot()

    def test_invalid_source_and_snapshot_paths_are_rejected(self) -> None:
        nested = self.root / "nested"
        nested.mkdir(mode=0o700)
        nested_file = nested / "image.bin"
        nested_file.write_bytes(self.payload)
        sibling = Path(self.temporary.name) / "sibling.bin"
        sibling.write_bytes(self.payload)
        os.chmod(sibling, 0o600)
        nested_destination = self.snapshot_root / "nested" / "image.bin"
        nested_destination.parent.mkdir(mode=0o700)

        invalid = (
            self.argv_for(path=nested_file),
            self.argv_for(path=sibling),
            self.argv_for(path=Path("relative-image.bin")),
            self.argv_for(root=Path("relative-root"), path=Path("relative-image.bin")),
            self.argv_for(destination=Path("relative-snapshot.bin")),
            self.argv_for(destination=nested_destination),
            self.argv_for(snapshot_root=self.root, destination=self.root / "copy.bin"),
        )
        for argv in invalid:
            self.assert_rejected(argv)
            self.assert_no_snapshot()

    def test_symlinks_hardlinks_and_existing_destination_are_rejected(self) -> None:
        symlink = self.root / "symlink.bin"
        symlink.symlink_to(self.path)
        self.assert_rejected(self.argv_for(path=symlink))
        self.assert_no_snapshot()

        hardlink = self.root / "hardlink.bin"
        os.link(self.path, hardlink)
        self.assert_rejected(self.argv_for(path=hardlink))
        self.assert_no_snapshot()

        snapshot_symlink = Path(self.temporary.name) / "snapshot-symlink"
        snapshot_symlink.symlink_to(self.snapshot_root, target_is_directory=True)
        self.assert_rejected(
            self.argv_for(
                snapshot_root=snapshot_symlink,
                destination=snapshot_symlink / "image.bin",
            )
        )
        self.assert_no_snapshot()

        self.destination.write_bytes(b"already exists")
        os.chmod(self.destination, 0o600)
        self.assert_rejected(self.argv_for())
        self.assertEqual(self.destination.read_bytes(), b"already exists")

    def test_file_and_snapshot_root_modes_are_rejected(self) -> None:
        os.chmod(self.path, 0o640)
        self.assert_rejected(self.argv_for())
        self.assert_no_snapshot()

        os.chmod(self.path, 0o600)
        os.chmod(self.root, 0o750)
        try:
            self.assert_rejected(self.argv_for())
            self.assert_no_snapshot()
        finally:
            os.chmod(self.root, 0o700)

        os.chmod(self.snapshot_root, 0o750)
        try:
            self.assert_rejected(self.argv_for())
            self.assert_no_snapshot()
        finally:
            os.chmod(self.snapshot_root, 0o700)

    def test_oversized_metadata_and_malformed_arguments_are_rejected(self) -> None:
        self.assert_rejected(
            self.argv_for(size=artifact_verify.MAX_ORIGINAL_BYTES + 1)
        )
        self.assertFalse(artifact_verify.verify(["artifact_verify.py"]))
        self.assertFalse(
            artifact_verify.verify(self.argv_for(digest="not-a-sha256"))
        )
        self.assert_rejected(self.argv_for(size=-1))

    def test_main_reports_fixed_bounded_failure_statuses(self) -> None:
        """The parent can distinguish safe stages without receiving details."""
        metadata = os.stat(self.path)
        self.assertEqual(
            artifact_verify.verification_status(
                self.argv_for(file_inode=metadata.st_ino + 1)
            ),
            artifact_verify.STATUS_ORIGINAL_FILE,
        )
        with mock.patch.object(
            artifact_verify.os, "fsync", side_effect=OSError("private detail")
        ):
            self.assertEqual(
                artifact_verify.verification_status(self.argv_for()),
                artifact_verify.STATUS_COPY_IO,
            )
        with mock.patch.object(sys, "argv", ["artifact_verify.py"]):
            self.assertEqual(
                artifact_verify.main(), artifact_verify.STATUS_INVALID_REQUEST
            )

    def test_write_and_fsync_failures_remove_partial_snapshot(self) -> None:
        with mock.patch.object(artifact_verify.os, "write", side_effect=OSError("nope")):
            self.assertFalse(artifact_verify.verify(self.argv_for()))
        self.assert_no_snapshot()

        real_write = os.write

        def partial_write(fd: int, block: bytes) -> int:
            return real_write(fd, block[:1])

        with mock.patch.object(artifact_verify.os, "write", side_effect=partial_write):
            self.assertTrue(
                artifact_verify.verify(
                    self.argv_for(destination=self.snapshot_root / "partial.bin")
                )
            )
        partial_path = self.snapshot_root / "partial.bin"
        self.assertEqual(partial_path.read_bytes(), self.payload)

        with mock.patch.object(artifact_verify.os, "fsync", side_effect=OSError("nope")):
            self.assertFalse(
                artifact_verify.verify(
                    self.argv_for(destination=self.snapshot_root / "fsync.bin")
                )
            )
        self.assertFalse((self.snapshot_root / "fsync.bin").exists())

    def test_final_fstat_failure_removes_snapshot(self) -> None:
        argv = self.argv_for()
        real_fstat = os.fstat
        source_fd: int | None = None
        calls = 0

        class ChangedIdentity:
            def __init__(self, original: os.stat_result) -> None:
                self.original = original

            def __getattr__(self, name: str):
                if name == "st_ino":
                    return self.original.st_ino + 1
                return getattr(self.original, name)

        def fstat(fd: int):
            nonlocal calls, source_fd
            calls += 1
            result = real_fstat(fd)
            # The third fstat is the opened source file.  Corrupt its final
            # fstat after the snapshot has been written and fsynced.
            if calls == 3:
                source_fd = fd
            if source_fd == fd and calls > 3:
                return ChangedIdentity(result)
            return result

        with mock.patch.object(artifact_verify.os, "fstat", side_effect=fstat):
            self.assertFalse(artifact_verify.verify(argv))
        self.assert_no_snapshot()


if __name__ == "__main__":
    unittest.main()
