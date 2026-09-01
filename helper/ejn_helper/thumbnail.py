"""Parent-side fixed thumbnail-worker launcher and PPM verifier."""

from __future__ import annotations

import importlib.util
import os
import signal
import stat
import subprocess
import sys
import time
from functools import lru_cache
from pathlib import Path

from .thumbnail_worker import EJN_MAX_PREVIEW_BYTES, EJN_MAX_PREVIEW_DIMENSION

EJN_THUMBNAIL_TIMEOUT_SECONDS = 3.0
_POLL_SECONDS = 0.01


class ThumbnailError(Exception):
    """The worker did not produce a complete canonical preview."""


def _worker_argv() -> tuple[str, str, str]:
    """Return the sole statically fixed decoder invocation.

    Supplying a file path rather than module arguments makes this robust for
    checkout tests under isolated Python while keeping all arguments fixed in
    production source.
    """
    return (sys.executable, "-I", str(Path(__file__).with_name("thumbnail_worker.py")))


@lru_cache(maxsize=1)
def _pillow_site_directory() -> str:
    """Return Pillow's pinned, non-writable import root for the worker.

    Nix console-script wrappers add propagated dependencies to ``sys.path`` in
    the parent process rather than to the base interpreter.  ``python -I``
    correctly drops that wrapper state, so pass back only Pillow's validated
    package root through a private worker variable.  No general ``PYTHONPATH``
    or caller-selected command crosses the decoder boundary.
    """
    spec = importlib.util.find_spec("PIL")
    locations = tuple(spec.submodule_search_locations or ()) if spec else ()
    if len(locations) != 1:
        raise ThumbnailError("Pillow package location is unavailable")
    try:
        # Python environments assembled from immutable package stores expose
        # individual packages as symlinks.  Pin the resolved target itself;
        # the child never follows the environment-level package name.
        package = Path(locations[0]).resolve(strict=True)
    except OSError as exc:
        raise ThumbnailError("Pillow package location is unsafe") from exc
    site_directory = package.parent
    try:
        package_metadata = package.stat(follow_symlinks=False)
        site_metadata = site_directory.stat(follow_symlinks=False)
    except OSError as exc:
        raise ThumbnailError("Pillow package location is unsafe") from exc
    if (
        not package.is_absolute()
        or package != Path(os.path.normpath(package))
        or package.is_symlink()
        or site_directory.is_symlink()
        or not stat.S_ISDIR(package_metadata.st_mode)
        or not stat.S_ISDIR(site_metadata.st_mode)
        or stat.S_IMODE(package_metadata.st_mode) & 0o022
        or stat.S_IMODE(site_metadata.st_mode) & 0o022
    ):
        raise ThumbnailError("Pillow package location is unsafe")
    return str(site_directory)


def _worker_environment() -> dict[str, str]:
    """Return the worker's minimal environment with one pinned import root."""
    return {
        "EJN_PINNED_PILLOW_SITE": _pillow_site_directory(),
        "PYTHONNOUSERSITE": "1",
        "LC_ALL": "C",
    }


def _signal_process_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            process.send_signal(signal_number)
        except OSError:
            pass


def run_worker(input_fd: int, output_fd: int, *, timeout: float = EJN_THUMBNAIL_TIMEOUT_SECONDS) -> None:
    """Run the one fixed worker with inherited pinned source and destination FDs."""
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        raise ThumbnailError("invalid thumbnail timeout")
    try:
        process = subprocess.Popen(
            _worker_argv(),
            stdin=input_fd,
            stdout=output_fd,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            shell=False,
            start_new_session=True,
            env=_worker_environment(),
        )
    except (OSError, ValueError) as exc:
        raise ThumbnailError("thumbnail worker could not start") from exc
    deadline = time.monotonic() + float(timeout)
    while process.poll() is None:
        if time.monotonic() >= deadline:
            _signal_process_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                _signal_process_group(process, signal.SIGKILL)
                try:
                    process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    # The caller still returns at a finite deadline.  A child
                    # stuck in an uninterruptible kernel wait cannot be reaped
                    # synchronously without violating the helper no-hang rule.
                    pass
            raise ThumbnailError("thumbnail worker timed out")
        time.sleep(_POLL_SECONDS)
    if process.returncode != 0:
        raise ThumbnailError("thumbnail worker failed")


def validate_ppm_fd(fd: int) -> tuple[int, int, int]:
    """Validate exact canonical P6 grammar and return ``(width, height, size)``."""
    try:
        metadata = os.fstat(fd)
        size = metadata.st_size
        if size < 11 or size > EJN_MAX_PREVIEW_BYTES:
            raise ThumbnailError("preview size is invalid")
        prefix = os.pread(fd, min(size, 64), 0)
    except OSError as exc:
        raise ThumbnailError("preview could not be inspected") from exc
    if not prefix.startswith(b"P6\n"):
        raise ThumbnailError("preview is not P6 PPM")
    newline = prefix.find(b"\n", 3)
    if newline < 0:
        raise ThumbnailError("preview header is incomplete")
    dimensions = prefix[3:newline].split(b" ")
    if len(dimensions) != 2 or any(
        not field or field.startswith(b"0") or not field.isdigit()
        for field in dimensions
    ):
        raise ThumbnailError("preview dimensions are not canonical")
    try:
        width, height = (int(field) for field in dimensions)
    except ValueError as exc:
        raise ThumbnailError("preview dimensions are invalid") from exc
    header = f"P6\n{width} {height}\n255\n".encode("ascii")
    if (
        width <= 0
        or height <= 0
        or width > EJN_MAX_PREVIEW_DIMENSION
        or height > EJN_MAX_PREVIEW_DIMENSION
        or not prefix.startswith(header)
        or size != len(header) + (width * height * 3)
    ):
        raise ThumbnailError("preview payload is invalid")
    return width, height, size
