"""Security, fidelity, and ownership tests for the V5 snapshot loader."""

import hashlib
import io
import json
import os
import stat
import struct
import tempfile
import unittest
from unittest import mock

import numpy as np

from ejn_viewer.snapshots import SnapshotError, load_snapshot
from ejn_viewer import snapshots


def group_bytes(array):
    dtype = array.dtype.str
    header = {"v": 1, "key": "k", "sample_id": "s",
              "publication_id": "0123456789abcdef0123456789abcdef",
              "planes": [{"id": "0", "name": "plane", "shape": list(array.shape),
                          "dtype": dtype, "offset": 0,
                          "nbytes": array.size * array.dtype.itemsize}]}
    encoded = json.dumps(header, separators=(",", ":")).encode()
    return b"EJNARR01" + struct.pack(">I", len(encoded)) + encoded + array.tobytes()


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.chmod(self.root, 0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, data, name="ejn-artifact-0123456789abcdef0123456789abcdef"):
        path = os.path.join(self.root, name)
        with open(path, "wb") as handle:
            handle.write(data)
        os.chmod(path, 0o600)
        return path

    def params(self, path, kind="array-group", **extra):
        root = os.stat(self.root)
        file_stat = os.stat(path)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        result = {"workspace": "ws", "generation": 4, "execution": "e-1",
                  "kind": kind, "focus": False,
                  "artifact": {"root": self.root, "path": path,
                                "root_device": root.st_dev, "root_inode": root.st_ino,
                                "device": file_stat.st_dev, "inode": file_stat.st_ino,
                                "size": file_stat.st_size, "sha256": digest}}
        result.update(extra)
        return result

    def test_numeric_values_endian_shape_and_readonly_survive_deletion(self):
        original = np.array([[1, 258], [65535, 7]], dtype=">u2")
        path = self.write(group_bytes(original))
        snapshot = load_snapshot(self.params(path))
        self.assertEqual(snapshot.manifest["planes"][0]["dtype"], ">u2")
        np.testing.assert_array_equal(snapshot.planes["plane"], original)
        self.assertFalse(snapshot.planes["plane"].flags.writeable)
        self.assertIs(snapshot.planes["plane"].base.base, snapshot.raw_bytes)
        os.unlink(path)
        np.testing.assert_array_equal(snapshot.planes["plane"], original)
        self.assertEqual(snapshot.raw_bytes[:8], b"EJNARR01")

    def test_raster_rgb_is_independent_and_non_numeric(self):
        from PIL import Image
        image = Image.new("RGB", (3, 2), (12, 34, 56))
        output = io.BytesIO()
        image.save(output, format="PNG")
        path = self.write(output.getvalue())
        snapshot = load_snapshot(self.params(path, "raster", mime="image/png"))
        self.assertFalse(snapshot.numerical)
        self.assertEqual(snapshot.planes["rendered"].shape, (2, 3, 3))
        self.assertFalse(snapshot.planes["rendered"].flags.writeable)
        os.unlink(path)
        np.testing.assert_array_equal(snapshot.planes["rendered"][0, 0], [12, 34, 56])

    def test_raster_l_and_palette_modes_convert_to_rgb(self):
        from PIL import Image
        image = Image.new("P", (2, 1))
        image.putdata([3, 7])
        image.putpalette([0, 0, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90])
        output = io.BytesIO()
        image.save(output, format="PNG")
        path = self.write(output.getvalue())
        snapshot = load_snapshot(self.params(path, "raster", mime="image/png"))
        self.assertEqual(snapshot.planes["rendered"].shape, (1, 2, 3))
        np.testing.assert_array_equal(snapshot.planes["rendered"][0], [[70, 80, 90], [70, 80, 90]])

    def test_palette_png_transparency_preserves_rgba(self):
        from PIL import Image
        image = Image.new("P", (2, 1))
        image.putdata([0, 1])
        image.putpalette([10, 20, 30, 40, 50, 60] + [0] * (768 - 6))
        output = io.BytesIO()
        image.save(output, format="PNG", transparency=bytes([0, 128]))
        path = self.write(output.getvalue())
        snapshot = load_snapshot(self.params(path, "raster", mime="image/png"))
        self.assertFalse(snapshot.numerical)
        np.testing.assert_array_equal(snapshot.planes["rendered"],
                                      [[[10, 20, 30, 0], [40, 50, 60, 128]]])

    def test_sibling_publication_between_stat_and_open_is_allowed(self):
        original = np.arange(4, dtype="<u2").reshape(2, 2)
        path = self.write(group_bytes(original))
        params = self.params(path)
        real_open = os.open
        changed = False

        def open_with_sibling(name, flags, *args, **kwargs):
            nonlocal changed
            if name == self.root and not changed:
                changed = True
                self.write(b"sibling", "ejn-artifact-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            return real_open(name, flags, *args, **kwargs)

        with mock.patch.object(snapshots.os, "open", side_effect=open_with_sibling):
            snapshot = load_snapshot(params)
        self.assertTrue(changed)
        np.testing.assert_array_equal(snapshot.planes["plane"], original)

    def test_sibling_publication_and_cleanup_during_read_are_allowed(self):
        original = np.arange(4, dtype="<u2").reshape(2, 2)
        path = self.write(group_bytes(original))
        sibling = self.write(b"old sibling", "ejn-artifact-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        params = self.params(path)
        real_read = os.read
        changed = False

        def read_with_sibling(fd, size):
            nonlocal changed
            chunk = real_read(fd, size)
            if not changed:
                changed = True
                self.write(b"new sibling", "ejn-artifact-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                os.unlink(sibling)
            return chunk

        with mock.patch.object(snapshots.os, "read", side_effect=read_with_sibling):
            snapshot = load_snapshot(params)
        self.assertTrue(changed)
        np.testing.assert_array_equal(snapshot.planes["plane"], original)

    def test_root_replacement_or_symlink_during_read_is_rejected(self):
        path = self.write(group_bytes(np.ones((2, 2), dtype="|u1")))
        real_read = os.read
        moved = self.root + "-moved"
        for symlink in (False, True):
            params = self.params(path)
            changed = False

            def read_with_root_swap(fd, size):
                nonlocal changed
                chunk = real_read(fd, size)
                if not changed:
                    changed = True
                    os.rename(self.root, moved)
                    if symlink:
                        # The resolved file is still the exact original inode.
                        # Only revalidating lstat(root) catches this change.
                        os.symlink(moved, self.root)
                    else:
                        os.mkdir(self.root, 0o700)
                return chunk

            try:
                with self.subTest(symlink=symlink), \
                        mock.patch.object(snapshots.os, "read", side_effect=read_with_root_swap):
                    with self.assertRaises(SnapshotError):
                        load_snapshot(params)
                    self.assertTrue(changed)
            finally:
                if changed:
                    if symlink:
                        os.unlink(self.root)
                    else:
                        os.rmdir(self.root)
                    os.rename(moved, self.root)

    def test_file_mutation_after_read_rejects_even_when_copied_hash_matches(self):
        path = self.write(group_bytes(np.ones((2, 2), dtype="|u1")))
        params = self.params(path)
        real_read = os.read
        changed = False

        def read_then_mutate(fd, size):
            nonlocal changed
            chunk = real_read(fd, size)
            if not changed:
                changed = True
                before = os.stat(path)
                os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
            return chunk

        with mock.patch.object(snapshots.os, "read", side_effect=read_then_mutate):
            with self.assertRaises(SnapshotError):
                load_snapshot(params)

    def test_file_path_replacement_after_read_rejects_copied_original(self):
        original = group_bytes(np.ones((2, 2), dtype="|u1"))
        path = self.write(original)
        params = self.params(path)
        real_read = os.read
        changed = False

        def read_then_replace(fd, size):
            nonlocal changed
            chunk = real_read(fd, size)
            if not changed:
                changed = True
                os.rename(path, path + "-old")
                self.write(original)
            return chunk

        with mock.patch.object(snapshots.os, "read", side_effect=read_then_replace):
            with self.assertRaises(SnapshotError):
                load_snapshot(params)

    def test_bad_identity_hash_and_modes_are_rejected(self):
        path = self.write(group_bytes(np.arange(4, dtype="<i4").reshape(2, 2)))
        for mutation in (lambda p: p["artifact"].update(sha256="0" * 64),
                         lambda p: p["artifact"].update(inode=p["artifact"]["inode"] + 1),
                         lambda p: p["artifact"].update(size=p["artifact"]["size"] + 1)):
            params = self.params(path)
            mutation(params)
            with self.assertRaises(SnapshotError):
                load_snapshot(params)
        os.chmod(path, 0o644)
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(path))

    def test_symlink_and_hardlink_rejected(self):
        data = group_bytes(np.ones((2, 2), dtype="|u1"))
        path = self.write(data)
        link = os.path.join(self.root, "ejn-artifact-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        os.symlink(path, link)
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(link))
        hard = os.path.join(self.root, "ejn-artifact-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        os.link(path, hard)
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(hard))

    def test_malformed_group_dtype_and_raster_mime_rejected(self):
        path = self.write(b"not-a-group")
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(path))
        raster = self.write(b"not-an-image")
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(raster, "raster", mime="image/jpeg"))

    def test_arbitrary_artifact_name_and_unhashable_kind_are_rejected(self):
        path = self.write(group_bytes(np.ones((1, 1), dtype="|u1")), "ordinary-file")
        with self.assertRaises(SnapshotError):
            load_snapshot(self.params(path))
        valid_path = self.write(group_bytes(np.ones((1, 1), dtype="|u1")))
        valid = self.params(valid_path)
        valid["kind"] = []
        with self.assertRaises(SnapshotError):
            load_snapshot(valid)


if __name__ == "__main__":
    unittest.main()
