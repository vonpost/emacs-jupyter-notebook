"""Durable findings remain independent of outputs, source files and kernels."""

from dataclasses import replace
import io
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import unittest
from unittest import mock

import numpy as np
from PIL import Image

from ejn_viewer.findings import (Capture, FindingError, FindingStore, MAX_IMAGE_PIXELS,
                                 MAX_MANIFEST_BYTES, MAX_OVERVIEW_BYTES, MAX_PNG_BYTES,
                                 copy_context)


def capture():
    array = np.arange(12, dtype=">u2").reshape(3, 4)
    array.setflags(write=False)
    return Capture(Image.new("RGB", (60, 40), "red"), (array,),
                   {"panes": [{"sources": [{"execution": "run-a",
                     "context": {"source": "/missing/notebook.py", "entries": [{"code": "model = A"}]}}]}],
                    "rois": [{"x": 1, "y": 1, "width": 2, "height": 1}]})


class FindingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "findings"
        self.store = FindingStore(self.root)

    def test_restart_missing_sources_retains_exact_samples_note_and_context(self):
        original = capture()
        result = self.store.save(original, "Artifact in model A")
        del self.store
        reopened = FindingStore(self.root)
        manifest, image, arrays = reopened.load(result["id"], arrays=True)
        self.assertEqual(manifest["view"], original.metadata)
        self.assertEqual(manifest["note"], "Artifact in model A")
        np.testing.assert_array_equal(arrays[0], original.arrays[0])
        self.assertEqual(arrays[0].dtype.str, ">u2")
        self.assertFalse(arrays[0].flags.writeable)
        self.assertEqual(Image.open(io.BytesIO(image)).size, (60, 40))
        self.assertEqual(os.stat(self.root).st_mode & 0o777, 0o700)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600
                            for path in (self.root / result["id"]).iterdir()))

    def test_failure_publishes_nothing_and_removes_staging_directory(self):
        with mock.patch("ejn_viewer.findings.np.save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.store.save(capture())
        self.assertEqual(self.store.catalog(), ([], 0))
        self.assertEqual([p.name for p in self.root.iterdir()], [".lock"])

    def test_overview_is_larger_than_thumbnail_without_upscaling_or_changing_original(self):
        for size, overview_size, thumb_size in (((1200, 800), (800, 533), (120, 80)),
                                                ((400, 1200), (200, 600), (27, 80)),
                                                ((60, 40), (60, 40), (60, 40))):
            with self.subTest(size=size):
                original = Image.fromarray(np.random.default_rng(1).integers(
                    0, 256, (size[1], size[0], 4), dtype=np.uint8))
                kept = self.store.save(replace(capture(), image=original))
                path = self.root / kept["id"]
                with Image.open(path / "image.png") as image:
                    np.testing.assert_array_equal(np.asarray(image), np.asarray(original))
                with Image.open(path / "overview.png") as image:
                    self.assertEqual(image.size, overview_size)
                with Image.open(path / "thumbnail.png") as image:
                    self.assertEqual(image.size, thumb_size)
                self.assertLessEqual((path / "overview.png").stat().st_size, MAX_OVERVIEW_BYTES)

    def test_overview_bytes_count_toward_capture_quota(self):
        value = capture()
        kept = self.store.save(value)
        path = self.root / kept["id"]
        without_overview = (sum(array.nbytes + 1024 for array in value.arrays)
                            + (path / "image.png").stat().st_size
                            + (path / "thumbnail.png").stat().st_size + MAX_MANIFEST_BYTES)
        limited = FindingStore(Path(self.tmp.name) / "limited", max_bytes=without_overview)
        with self.assertRaisesRegex(FindingError, "storage is full"):
            limited.save(value)
        self.assertEqual(limited.catalog(), ([], 0))

    def test_storage_full_never_evicts_a_kept_finding_and_delete_makes_space(self):
        store = FindingStore(self.root, max_count=1)
        kept = store.save(capture())
        with self.assertRaisesRegex(FindingError, "storage is full"):
            store.save(capture())
        self.assertEqual(store.catalog()[0][0]["id"], kept["id"])
        store.delete([kept["id"]])
        store.save(capture())

    def test_notes_update_atomically_and_invalid_data_does_not_replace_note(self):
        kept = self.store.save(capture(), "Original")
        self.store.update_note(kept["id"], "New observation")
        with self.assertRaises(FindingError):
            self.store.update_note(kept["id"], "a" * 2001)
        self.assertEqual(self.store.manifest(kept["id"])["note"], "New observation")

    def test_traversal_symlinks_schema_and_corrupt_png_are_rejected(self):
        kept = self.store.save(capture())
        path = self.root / kept["id"]
        with self.assertRaises(FindingError):
            self.store.load("../outside")
        image = path / "image.png"
        image.unlink()
        image.symlink_to(path / "thumbnail.png")
        with self.assertRaises(FindingError):
            self.store.load(kept["id"])
        manifest = kept | {"planes": [{"file": "../../x", "nbytes": 1, "shape": [1, 1], "dtype": "u1"}]}
        (path / "finding.json").write_text(json.dumps(manifest))
        with self.assertRaises(FindingError):
            self.store.manifest(kept["id"])
        self.assertEqual(self.store.catalog(), ([], 1))

    def test_writable_arrays_and_excessive_context_rejected_before_saving(self):
        value = capture()
        with self.assertRaises(FindingError):
            self.store.save(replace(value, arrays=(value.arrays[0].copy(),)))
        for context in ([], {"code": "x" * 25000}, {"bad": float("nan")}):
            with self.assertRaises(FindingError):
                copy_context(context)

    def test_corrupt_thumbnail_and_fifo_cannot_block_or_abort_review_catalog(self):
        kept = self.store.save(capture())
        path = self.root / kept["id"] / "thumbnail.png"
        path.unlink()
        os.mkfifo(path)
        self.assertEqual(self.store.catalog(), ([], 1))
        path.unlink()
        path.write_bytes(b"not a PNG")
        self.assertEqual(self.store.catalog(), ([], 1))
        with mock.patch("ejn_viewer.findings.Image.open", side_effect=Image.DecompressionBombError("bomb")):
            self.assertEqual(self.store.catalog(), ([], 1))

    def test_catalog_reports_saved_image_extent_without_blocking_on_damage(self):
        kept = self.store.save(capture())
        image = self.root / kept["id"] / "image.png"
        item = self.store.catalog()[0][0]
        self.assertEqual((item["image_bytes"], item["pixels"]), (image.stat().st_size, 60 * 40))
        # Damaged or non-regular images keep the finding listed with the
        # conservative format limits; opening the preview reports the damage.
        image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0\0\0\x0dIHDR" + b"\xff" * 8)
        item = self.store.catalog()[0][0]
        self.assertEqual((item["image_bytes"], item["pixels"]), (MAX_PNG_BYTES, MAX_IMAGE_PIXELS))
        with self.assertRaises(FindingError):
            self.store.preview(kept["id"])
        image.unlink()
        os.mkfifo(image)
        item = self.store.catalog()[0][0]
        self.assertEqual((item["image_bytes"], item["pixels"]), (MAX_PNG_BYTES, MAX_IMAGE_PIXELS))
        image.unlink()
        image.mkdir()
        before = len(os.listdir("/dev/fd"))
        for _ in range(5):
            item = self.store.catalog()[0][0]
        self.assertEqual((item["image_bytes"], item["pixels"]), (MAX_PNG_BYTES, MAX_IMAGE_PIXELS))
        self.assertEqual(len(os.listdir("/dev/fd")), before)

    def test_modified_numerical_samples_are_detected(self):
        kept = self.store.save(capture())
        path = self.root / kept["id"] / "plane-0.npy"
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(data)
        with self.assertRaisesRegex(FindingError, "samples are damaged"):
            self.store.load(kept["id"], arrays=True)

    def test_org_overview_newest_first_and_relative_assets_survive_folder_copy(self):
        older = self.store.save(capture(), "Older finding")
        newer = self.store.save(capture(), "Newer finding")
        with mock.patch("ejn_viewer.findings._png", side_effect=AssertionError("full PNG decoding")):
            result = self.store.org_overview()
        path = Path(result["path"])
        self.assertEqual(result, {"path": str(self.root / "findings.org"), "count": 2, "skipped": 0})
        content = path.read_text()
        self.assertLess(content.index("* Newer finding"), content.index("* Older finding"))
        self.assertIn("\n** Context\n", content)
        self.assertIn("model = A", content)
        self.assertIn(f"[[file:{newer['id']}/overview.png]]", content)
        self.assertIn("#+STARTUP: content noinlineimages", content)
        self.assertEqual(path.stat().st_mode & 0o777, 0o400)
        copied = Path(self.tmp.name) / "portable"
        shutil.copytree(self.root, copied)
        links = re.findall(r"\[\[file:([^\]]+)\]", content)
        self.assertEqual(len(links), 8)
        self.assertTrue(all(not os.path.isabs(link) and (copied / link).is_file() for link in links))
        self.assertEqual(FindingStore(copied).org_overview()["count"], 2)

    def test_org_untrusted_notes_code_links_and_file_local_variables_are_inert(self):
        malicious = ("* Surprise\n#+STARTUP: showall\n[[elisp:(evil)]]\nLocal Variables:\neval: (evil)\nEnd:\n"
                     "{{{eval((evil))}}} src_emacs-lisp{(evil)} call_bad() $\\input{secret}$")
        value = capture()
        value.metadata["panes"][0]["sources"][0]["context"]["entries"][0]["code"] = malicious
        kept = self.store.save(value, malicious)
        content = Path(self.store.org_overview()["path"]).read_text()
        self.assertEqual(len(re.findall(r"^\* ", content, re.MULTILINE)), 1)
        self.assertNotIn("\n#+STARTUP: showall", content)
        self.assertNotIn("[[elisp:", content)
        self.assertNotIn("Local Variables:", content)
        self.assertNotIn("#+begin_src", content.lower())
        self.assertNotIn("{{{", content)
        self.assertNotIn("src_emacs-lisp{", content)
        self.assertNotIn("call_bad(", content)
        self.assertNotIn("\\input", content)
        self.assertIn("［［elisp：", content)
        self.assertEqual(self.store.manifest(kept["id"])["note"], malicious)

    def test_org_regenerates_clean_index_and_never_overwrites_edited_report(self):
        kept = self.store.save(capture(), "Before")
        path = Path(self.store.org_overview()["path"])
        self.store.update_note(kept["id"], "After")
        self.store.org_overview()
        self.assertIn("* After", path.read_text())
        os.chmod(path, 0o600)
        edited = path.read_bytes() + b"\n* My report draft\n"
        path.write_bytes(edited)
        with self.assertRaisesRegex(FindingError, "has been edited"):
            self.store.org_overview()
        self.assertEqual(path.read_bytes(), edited)

    def test_org_failure_preserves_prior_index_and_skips_broken_finding(self):
        first = self.store.save(capture(), "Keep me")
        second = self.store.save(capture(), "Missing overview preview")
        (self.root / second["id"] / "overview.png").unlink()
        result = self.store.org_overview()
        self.assertEqual((result["count"], result["skipped"]), (1, 1))
        path = Path(result["path"])
        before = path.read_bytes()
        self.store.update_note(first["id"], "Changed")
        with mock.patch("ejn_viewer.findings.os.replace", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError):
                self.store.org_overview()
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(list(self.root.glob(".overview-*")))

    def test_org_skips_invalid_preview_without_decoding_full_image(self):
        kept = self.store.save(capture())
        path = self.root / kept["id"] / "overview.png"
        oversized_pixels = io.BytesIO()
        Image.new("RGB", (801, 600)).save(oversized_pixels, format="PNG")
        for raw in (b"broken PNG", oversized_pixels.getvalue(), b"x" * (MAX_OVERVIEW_BYTES + 1)):
            with self.subTest(length=len(raw)):
                path.write_bytes(raw)
                with mock.patch("ejn_viewer.findings._png", side_effect=AssertionError("full PNG decoding")):
                    result = self.store.org_overview()
                self.assertEqual((result["count"], result["skipped"]), (0, 1))

    def test_org_context_is_bounded_and_explicitly_marks_excerpt(self):
        value = capture()
        value.metadata["panes"][0]["sources"][0]["context"]["entries"] = [
            {"id": str(index), "code": ("long_value = '" + "x" * 200 + "'\n") * 20}
            for index in range(3)]
        self.store.save(value)
        content = Path(self.store.org_overview()["path"]).read_text()
        context = content.split("** Context\n", 1)[1].strip()
        self.assertLessEqual(len(context.encode("utf-8")), 4096)
        self.assertIn("excerpt shortened", context.lower())

    def test_org_overview_keeps_long_observation_in_visible_body(self):
        note = "The artifact appears in this slice. " * 20
        self.store.save(capture(), note)
        content = Path(self.store.org_overview()["path"]).read_text()
        visible = content.split("** Context", 1)[0]
        self.assertIn(": " + note.strip(), visible)
        heading = next(line for line in content.splitlines() if line.startswith("* "))
        self.assertLess(len(heading), 220)

    def test_org_removes_only_owned_regular_interrupted_overview_staging(self):
        self.store.save(capture())
        stale = self.root / (".overview-" + "a" * 32)
        stale.write_text("partial generated index")
        keep = self.root / ".overview-report-draft"
        keep.write_text("user draft")
        linked = self.root / (".overview-" + "b" * 32)
        linked.symlink_to(keep)
        self.store.org_overview()
        self.assertFalse(stale.exists())
        self.assertEqual(keep.read_text(), "user draft")
        self.assertTrue(linked.is_symlink())


if __name__ == "__main__":
    unittest.main()
