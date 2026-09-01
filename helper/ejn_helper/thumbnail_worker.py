"""The fixed, short-lived decoder process for EJN image previews.

The parent gives this module a read-only source image as stdin and an already
private unpublished preview file as stdout.  It deliberately has no command
line interface: its executable and arguments are fixed by ``thumbnail.py``.
"""

from __future__ import annotations

import os
import platform
import resource
import stat
import sys
import warnings

EJN_MAX_SOURCE_PIXELS = 4_194_304
EJN_MAX_PREVIEW_DIMENSION = 1_024
EJN_MAX_PREVIEW_BYTES = 4 * 1_024 * 1_024
EJN_LINUX_ADDRESS_SPACE_LIMIT = 256 * 1_024 * 1_024
# macOS's dyld shared cache and the native image libraries it maps leave a
# substantially larger virtual-address baseline than Linux.  Keep decoding
# bounded while leaving enough headroom for Pillow to load on Apple Silicon.
EJN_DARWIN_ADDRESS_SPACE_LIMIT = 1_024 * 1_024 * 1_024


def _supported_platform() -> bool:
    machine = platform.machine().lower()
    return (sys.platform.startswith("linux") and machine in {"x86_64", "amd64"}) or (
        sys.platform == "darwin" and machine in {"arm64", "aarch64"}
    )


def _address_space_limit() -> int:
    """Return the fixed virtual-address ceiling for the supported platform."""
    if sys.platform.startswith("linux"):
        return EJN_LINUX_ADDRESS_SPACE_LIMIT
    if sys.platform == "darwin":
        return EJN_DARWIN_ADDRESS_SPACE_LIMIT
    raise RuntimeError("unsupported thumbnail-worker platform")


def _set_limit(name: str, value: int) -> None:
    limit = getattr(resource, name, None)
    if limit is None:
        raise RuntimeError(f"missing {name}")
    _soft, hard = resource.getrlimit(limit)
    if hard != resource.RLIM_INFINITY and hard < value:
        raise RuntimeError(f"insufficient {name}")
    resource.setrlimit(limit, (value, hard))
    current, _hard = resource.getrlimit(limit)
    if current > value:
        raise RuntimeError(f"failed to set {name}")


def apply_limits() -> None:
    """Set every mandatory limit before importing Pillow, or fail closed."""
    if not _supported_platform():
        raise RuntimeError("unsupported thumbnail-worker platform")
    _set_limit("RLIMIT_CPU", 3)
    _set_limit("RLIMIT_FSIZE", EJN_MAX_PREVIEW_BYTES)
    _set_limit("RLIMIT_NOFILE", 16)
    _set_limit("RLIMIT_CORE", 0)
    _set_limit("RLIMIT_AS", _address_space_limit())


def _install_pinned_pillow_site() -> None:
    """Admit only the parent-pinned Pillow root into isolated ``sys.path``."""
    value = os.environ.pop("EJN_PINNED_PILLOW_SITE", None)
    if not value or not os.path.isabs(value) or os.path.normpath(value) != value:
        raise RuntimeError("missing pinned Pillow package root")
    try:
        metadata = os.stat(value, follow_symlinks=False)
    except OSError as exc:
        raise RuntimeError("unsafe pinned Pillow package root") from exc
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise RuntimeError("unsafe pinned Pillow package root")
    sys.path.append(value)


def _ppm_header(width: int, height: int) -> bytes:
    return f"P6\n{width} {height}\n255\n".encode("ascii")


def main() -> int:
    try:
        apply_limits()
        _install_pinned_pillow_site()
        # Limits must be live before Pillow and image codecs are imported.
        from PIL import Image, ImageFile

        Image.MAX_IMAGE_PIXELS = EJN_MAX_SOURCE_PIXELS
        ImageFile.LOAD_TRUNCATED_IMAGES = False
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            input_stream = sys.stdin.buffer
            magic = input_stream.read(16)
            input_stream.seek(0)
            expected_format = (
                "PNG"
                if magic.startswith(b"\x89PNG\r\n\x1a\n")
                else "JPEG"
                if magic.startswith(b"\xff\xd8")
                else None
            )
            if expected_format is None:
                return 1
            with Image.open(input_stream) as source:
                width, height = source.size
                if (
                    source.format != expected_format
                    or type(width) is not int
                    or type(height) is not int
                    or width <= 0
                    or height <= 0
                    or width * height > EJN_MAX_SOURCE_PIXELS
                ):
                    return 1
                source.verify()
            input_stream.seek(0)
            with Image.open(input_stream) as decoded:
                if decoded.format != expected_format or decoded.size != (width, height):
                    return 1
                decoded.load()
                rgb = decoded.convert("RGB")
                if max(rgb.size) > EJN_MAX_PREVIEW_DIMENSION:
                    rgb.thumbnail(
                        (EJN_MAX_PREVIEW_DIMENSION, EJN_MAX_PREVIEW_DIMENSION),
                        Image.Resampling.LANCZOS,
                    )
                preview_width, preview_height = rgb.size
                payload_bytes = preview_width * preview_height * 3
                if (
                    preview_width <= 0
                    or preview_height <= 0
                    or payload_bytes > EJN_MAX_PREVIEW_BYTES
                ):
                    return 1
                output = sys.stdout.buffer
                output.write(_ppm_header(preview_width, preview_height))
                output.write(rgb.tobytes("raw", "RGB"))
                output.flush()
        return 0
    except BaseException:
        # No traceback or decoder diagnostics are allowed to become a retained
        # parent-process stream.  The parent treats every non-zero exit equally.
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
