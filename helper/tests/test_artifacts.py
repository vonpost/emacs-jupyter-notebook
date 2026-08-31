import base64
import hashlib
import os
import stat
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

from ejn_helper import artifacts
from ejn_helper.artifacts import (
    ArtifactDataError,
    ArtifactDirectoryError,
    ArtifactIOError,
    ArtifactStore,
    ArtifactTooLargeError,
)


class ArtifactStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.directory = self.root / "artifacts"
        self.directory.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def encode(data: bytes) -> str:
        return base64.b64encode(data).decode("ascii")

    def assert_no_partials(self):
        self.assertEqual(
            [
                path.name
                for path in self.directory.iterdir()
                if ".ejn-partial-" in path.name
            ],
            [],
        )

    def test_exact_limit_publishes_digest_mode_and_size(self):
        data = b"exact-limit"
        with ArtifactStore(self.directory, max_bytes=len(data)) as store:
            result = store.store_base64(self.encode(data))
        self.assertEqual(result.path.read_bytes(), data)
        self.assertEqual(result.byte_count, len(data))
        self.assertEqual(result.sha256, hashlib.sha256(data).hexdigest())
        self.assertEqual(stat.S_IMODE(result.path.stat().st_mode), 0o600)
        self.assert_no_partials()

    def test_one_byte_over_limit_is_rejected_before_file_creation(self):
        data = b"one-byte-over"
        with ArtifactStore(self.directory, max_bytes=len(data) - 1) as store:
            with self.assertRaises(ArtifactTooLargeError):
                store.store_base64(self.encode(data))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_malformed_base64_cleans_partial(self):
        # The first full chunk decodes successfully, proving cleanup after a
        # partially written artifact rather than only preflight rejection.
        payload = "A" * artifacts._BASE64_CHUNK_BYTES + "!!!!"
        with ArtifactStore(self.directory) as store:
            with self.assertRaises(ArtifactDataError):
                store.store_base64(payload)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_relative_directory_is_rejected(self):
        with self.assertRaises(ArtifactDirectoryError):
            ArtifactStore(Path("relative-artifacts"))

    def test_parent_traversal_directory_is_rejected(self):
        escaped_spelling = self.directory / ".." / self.directory.name
        with self.assertRaises(ArtifactDirectoryError):
            ArtifactStore(escaped_spelling)

    def test_symlink_directory_escape_is_rejected(self):
        link = self.root / "artifact-link"
        try:
            link.symlink_to(self.directory, target_is_directory=True)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"directory symlinks unavailable: {exc}")
        with self.assertRaises(ArtifactDirectoryError):
            ArtifactStore(link)

    def test_symlinked_ancestor_is_canonicalized_for_darwin_var_portability(self):
        # Darwin commonly presents temporary paths below /var even though the
        # canonical ancestry is /private/var.  Ancestor links are safe once the
        # store pins and reports only the resolved directory.
        real_parent = self.root / "real-parent"
        real_parent.mkdir(mode=0o700)
        nested_directory = real_parent / "nested-artifacts"
        nested_directory.mkdir(mode=0o700)
        linked_parent = self.root / "linked-parent"
        try:
            linked_parent.symlink_to(real_parent, target_is_directory=True)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"directory symlinks unavailable: {exc}")
        decoy_parent = self.root / "decoy-parent"
        decoy_parent.mkdir(mode=0o700)
        decoy_directory = decoy_parent / nested_directory.name
        decoy_directory.mkdir(mode=0o700)

        with ArtifactStore(linked_parent / nested_directory.name) as store:
            self.assertEqual(store.directory, nested_directory.resolve(strict=True))
            linked_parent.unlink()
            linked_parent.symlink_to(decoy_parent, target_is_directory=True)
            result = store.store_base64(self.encode(b"canonical payload"))

        self.assertEqual(result.path.parent, nested_directory.resolve(strict=True))
        self.assertEqual(result.path.read_bytes(), b"canonical payload")
        self.assertEqual(list(decoy_directory.iterdir()), [])

    def test_symlink_publication_escape_is_rejected_without_touching_target(self):
        outside = self.root / "outside"
        outside.write_bytes(b"outside-data")
        collision = self.directory / "ejn-artifact-publish"
        try:
            collision.symlink_to(outside)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"file symlinks unavailable: {exc}")
        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                artifacts.secrets,
                "token_hex",
                side_effect=["partial", "publish"],
            ):
                with self.assertRaises(ArtifactIOError):
                    store.store_base64(self.encode(b"payload"))
        self.assertTrue(collision.is_symlink())
        self.assertEqual(outside.read_bytes(), b"outside-data")
        self.assert_no_partials()

    def test_symlink_partial_collision_is_not_unlinked_by_cleanup(self):
        outside = self.root / "outside-partial"
        outside.write_bytes(b"outside-data")
        collision = self.directory / ".ejn-partial-collision"
        try:
            collision.symlink_to(outside)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"file symlinks unavailable: {exc}")
        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                artifacts.secrets,
                "token_hex",
                side_effect=["collision", "unused"],
            ):
                with self.assertRaises(ArtifactIOError):
                    store.store_base64(self.encode(b"payload"))
        self.assertTrue(collision.is_symlink())
        self.assertEqual(outside.read_bytes(), b"outside-data")

    def test_wrong_expected_owner_is_rejected(self):
        if not hasattr(os, "geteuid"):
            self.skipTest("effective uid unavailable")
        with self.assertRaises(ArtifactDirectoryError):
            ArtifactStore(self.directory, expected_uid=os.geteuid() + 1)

    def test_world_writable_directory_is_rejected(self):
        try:
            self.directory.chmod(0o707)
        except OSError as exc:
            self.skipTest(f"chmod unavailable: {exc}")
        with self.assertRaises(ArtifactDirectoryError):
            ArtifactStore(self.directory)

    def test_write_failure_cleans_partial(self):
        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                artifacts, "_write_all", side_effect=OSError("injected write failure")
            ):
                with self.assertRaises(ArtifactIOError):
                    store.store_base64(self.encode(b"payload"))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_fsync_failure_cleans_partial(self):
        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                os, "fsync", side_effect=OSError("injected fsync failure")
            ):
                with self.assertRaises(ArtifactIOError):
                    store.store_base64(self.encode(b"payload"))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_replace_failure_cleans_partial(self):
        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                os, "replace", side_effect=OSError("injected replace failure")
            ):
                with self.assertRaises(ArtifactIOError):
                    store.store_base64(self.encode(b"payload"))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_directory_path_replacement_before_publish_cleans_pinned_partial(self):
        moved_directory = self.root / "moved-artifacts"
        real_write = artifacts._write_all
        replaced = False

        def replace_path_during_write(stream, data):
            nonlocal replaced
            if not replaced:
                self.directory.rename(moved_directory)
                self.directory.mkdir(mode=0o700)
                replaced = True
            real_write(stream, data)

        with ArtifactStore(self.directory) as store:
            with mock.patch.object(
                artifacts, "_write_all", side_effect=replace_path_during_write
            ):
                with self.assertRaises(ArtifactDirectoryError):
                    store.store_base64(self.encode(b"payload"))
        self.assertEqual(list(moved_directory.iterdir()), [])
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_published_file_survives_store_close(self):
        store = ArtifactStore(self.directory)
        result = store.store_base64(self.encode(b"owned by Emacs"))
        store.close()
        self.assertTrue(result.path.is_file())
        self.assertEqual(result.path.read_bytes(), b"owned by Emacs")
        with self.assertRaises(ArtifactIOError):
            store.store_base64(self.encode(b"after close"))

    def test_discard_uses_store_lease_not_an_advertised_path(self):
        outside = self.root / "outside"
        outside.write_bytes(b"outside-data")
        with ArtifactStore(self.directory) as store:
            published = store.store_base64(self.encode(b"unhanded"))
            forged_path = replace(published, path=outside)
            self.assertTrue(store.discard(forged_path))
        self.assertFalse(published.path.exists())
        self.assertEqual(outside.read_bytes(), b"outside-data")


if __name__ == "__main__":
    unittest.main()
