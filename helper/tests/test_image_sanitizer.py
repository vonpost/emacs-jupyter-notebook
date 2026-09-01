"""EI4D worker boundary tests that do not require a local Pillow install."""

from __future__ import annotations

import base64
import io
import os
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

from ejn_helper.artifacts import ArtifactStore
from ejn_helper.thumbnail import ThumbnailError, run_worker, validate_ppm_fd

try:
    from PIL import Image
except ImportError:  # The Nix package check supplies Pillow; host tests may not.
    if os.environ.get("EJN_REQUIRE_PILLOW") == "1":
        raise
    Image = None


def png_header(width: int = 2, height: int = 3) -> bytes:
    ihdr = b"IHDR" + width.to_bytes(4, "big") + height.to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
    return b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0d" + ihdr + zlib.crc32(ihdr).to_bytes(4, "big")


def ppm(width: int = 2, height: int = 3) -> bytes:
    return f"P6\n{width} {height}\n255\n".encode("ascii") + bytes(range(width * height * 3))


class ImageSanitizerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "artifacts"
        self.directory.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def payload(data: bytes) -> str:
        return base64.b64encode(data).decode("ascii")

    def assert_no_partial(self) -> None:
        self.assertFalse(any(path.name.startswith(".ejn-partial-") for path in self.directory.iterdir()))

    def run_real_worker(self, source: bytes, *, timeout: float = 3.0) -> bytes:
        """Run the fixed Pillow child against a pinned regular-file stdin."""
        source_path = Path(self.temporary.name) / "source.bin"
        output_path = Path(self.temporary.name) / "preview.ppm"
        source_path.write_bytes(source)
        with source_path.open("rb") as source_file, output_path.open("w+b") as output_file:
            with self.assertRaises(ThumbnailError):
                run_worker(source_file.fileno(), output_file.fileno(), timeout=timeout)
            output_file.flush()
            output_file.seek(0)
            return output_file.read()

    def test_complete_prefiltered_image_publishes_distinct_canonical_preview(self) -> None:
        def worker(_input_fd: int, output_fd: int) -> None:
            os.write(output_fd, ppm())

        with ArtifactStore(self.directory) as store:
            with mock.patch("ejn_helper.artifacts.run_worker", side_effect=worker):
                image = store.make_image(self.payload(png_header()), "image/png")
        self.assertIsNotNone(image.preview)
        assert image.preview is not None
        self.assertNotEqual(image.original.path, image.preview.path)
        self.assertNotEqual(image.original._lease.inode, image.preview._lease.inode)
        self.assertEqual((image.width, image.height), (2, 3))
        self.assertEqual(image.preview.path.read_bytes(), ppm())
        fd = os.open(image.preview.path, os.O_RDONLY)
        try:
            self.assertEqual(validate_ppm_fd(fd), (2, 3, len(ppm())))
        finally:
            os.close(fd)
        self.assert_no_partial()

    def test_prefilter_mismatch_truncation_and_one_over_never_start_worker(self) -> None:
        worker = mock.Mock()
        with ArtifactStore(self.directory) as store:
            for payload, mime in (
                (b"not-an-image", "image/png"),
                (png_header(), "image/jpeg"),
                (png_header(2049, 2048), "image/png"),
            ):
                with mock.patch("ejn_helper.artifacts.run_worker", worker):
                    image = store.make_image(self.payload(payload), mime)
                self.assertIsNone(image.preview)
                self.assertTrue(image.original.path.exists())
        worker.assert_not_called()
        self.assert_no_partial()

    def test_worker_failure_timeout_and_invalid_or_oversized_output_keep_original_only(self) -> None:
        cases = (
            ThumbnailError("timeout"),
            RuntimeError("worker crashed"),
            lambda _in, out: os.write(out, b"not ppm"),
            lambda _in, out: os.write(out, b"P6\n1 1\n255\n\x00\x00\x00trailing"),
        )
        with ArtifactStore(self.directory) as store:
            for worker in cases:
                with mock.patch("ejn_helper.artifacts.run_worker", side_effect=worker):
                    image = store.make_image(self.payload(png_header()), "image/png")
                self.assertIsNone(image.preview)
                self.assertTrue(image.original.path.exists())
                self.assert_no_partial()

    def test_preview_publication_failure_rolls_back_only_preview(self) -> None:
        original_replace = os.replace
        calls = 0

        def fail_preview_replace(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("race")
            return original_replace(*args, **kwargs)

        with ArtifactStore(self.directory) as store:
            with mock.patch(
                "ejn_helper.artifacts.run_worker",
                side_effect=lambda _in, out: os.write(out, ppm()),
            ), mock.patch("ejn_helper.artifacts.os.replace", side_effect=fail_preview_replace):
                image = store.make_image(self.payload(png_header()), "image/png")
        self.assertIsNone(image.preview)
        self.assertTrue(image.original.path.exists())
        self.assert_no_partial()

    @unittest.skipIf(Image is None, "Pillow is exercised by the Nix package check")
    def test_real_worker_rejects_corrupt_and_truncated_png_and_jpeg(self) -> None:
        assert Image is not None
        encoded_images: dict[str, bytes] = {}
        for image_format in ("PNG", "JPEG"):
            encoded = io.BytesIO()
            Image.new("RGB", (32, 24), (17, 34, 51)).save(encoded, image_format)
            encoded_images[image_format] = encoded.getvalue()

        for image_format, source in encoded_images.items():
            with self.subTest(image_format=image_format, failure="corrupt"):
                corrupt = bytearray(source)
                if image_format == "PNG":
                    # Corrupt the IHDR CRC, which verify() must reject.
                    corrupt[29] ^= 0xFF
                else:
                    # Make the first required quantization segment malformed.
                    # This preserves the JPEG magic while defeating verify().
                    quantization_marker = source.index(b"\xff\xdb")
                    corrupt[quantization_marker + 2 : quantization_marker + 4] = b"\x00\x00"
                self.assertEqual(self.run_real_worker(bytes(corrupt)), b"")
            with self.subTest(image_format=image_format, failure="truncated"):
                self.assertEqual(self.run_real_worker(source[: len(source) // 2]), b"")

    @unittest.skipIf(Image is None, "Pillow is exercised by the Nix package check")
    def test_real_worker_rejects_bomb_sized_header_without_allocating_pixels(self) -> None:
        # This is only a PNG signature plus IHDR.  Pillow rejects the dimensions
        # before decoding, so the test does not allocate a multi-megapixel image.
        self.assertEqual(self.run_real_worker(png_header(2049, 2048)), b"")

    def test_validator_rejects_noncanonical_ppm_headers(self) -> None:
        payload = bytes(3)
        for header in (
            b"P6\n01 1\n255\n",
            b"P6\n1 01\n255\n",
            b"P6\n1  1\n255\n",
            b"P6\n1 1\n255\n\n",
            b"P6\r\n1 1\n255\n",
        ):
            with self.subTest(header=header):
                path = Path(self.temporary.name) / "noncanonical.ppm"
                path.write_bytes(header + payload)
                fd = os.open(path, os.O_RDONLY)
                try:
                    with self.assertRaises(ThumbnailError):
                        validate_ppm_fd(fd)
                finally:
                    os.close(fd)

    def test_configured_source_budget_only_lowers_the_hard_ceiling(self) -> None:
        with ArtifactStore(self.directory) as store:
            with mock.patch("ejn_helper.artifacts.run_worker") as worker:
                image = store.make_image(
                    self.payload(png_header(11, 10)), "image/png", max_source_pixels=100
                )
        self.assertIsNone(image.preview)
        worker.assert_not_called()

    @unittest.skipIf(Image is None, "Pillow is exercised by the Nix package check")
    def test_real_pillow_worker_publishes_png_and_jpeg_previews(self) -> None:
        assert Image is not None
        with ArtifactStore(self.directory) as store:
            for image_format, mime in (("PNG", "image/png"), ("JPEG", "image/jpeg")):
                encoded = io.BytesIO()
                Image.new("RGB", (7, 5), (17, 34, 51)).save(encoded, image_format)
                source = encoded.getvalue()
                published = store.make_image(self.payload(source), mime)
                self.assertEqual(published.original.path.read_bytes(), source)
                self.assertIsNotNone(published.preview)
                assert published.preview is not None
                self.assertEqual((published.width, published.height), (7, 5))
                preview_fd = os.open(published.preview.path, os.O_RDONLY)
                try:
                    self.assertEqual(
                        validate_ppm_fd(preview_fd),
                        (7, 5, len(b"P6\n7 5\n255\n") + (7 * 5 * 3)),
                    )
                finally:
                    os.close(preview_fd)
                self.assertEqual(published.preview.path.stat().st_mode & 0o777, 0o600)
        self.assert_no_partial()


if __name__ == "__main__":
    unittest.main()
