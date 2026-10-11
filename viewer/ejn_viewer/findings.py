"""Private, bounded local finding archives. No Qt, kernel or remote access.

A directory rename publishes each self-contained finding. Saved data is never
evicted to make room: users explicitly remove findings in the review window.
All methods are worker operations, including reads.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import uuid

import numpy as np
from PIL import Image

MAX_FINDINGS = 1000
MAX_STORE_BYTES = 2 * 1024**3
MAX_CAPTURE_BYTES = 128 * 1024**2
MAX_IMAGE_PIXELS = 16_777_216
MAX_IMAGE_EXTENT = 16_384
MAX_PNG_BYTES = 64 * 1024**2
MAX_OVERVIEW_BYTES = 2 * 1024**2
OVERVIEW_SIZE = (800, 600)
MAX_MANIFEST_BYTES = 256 * 1024
MAX_CONTEXT_BYTES = 24 * 1024
MAX_NOTE = 2000
MAX_ORG_BYTES = 8 * 1024**2
MAX_ORG_CONTEXT_BYTES = 4096
_ORG_MARKER = b"# EJN generated findings overview v1\n"
_ID = re.compile(r"[0-9a-f]{32}\Z")


class FindingError(ValueError):
    pass


def json_bytes(value, limit=MAX_MANIFEST_BYTES):
    try:
        raw = json.dumps(value, ensure_ascii=False, allow_nan=False,
                         separators=(",", ":")).encode("utf-8")
    except (ValueError, TypeError, UnicodeError, RecursionError) as exc:
        raise FindingError("Invalid finding metadata.") from exc
    if len(raw) > limit:
        raise FindingError("Finding metadata exceeds its size limit.")
    return raw


def copy_context(value):
    if not isinstance(value, dict):
        raise FindingError("Invalid execution context.")
    return json.loads(json_bytes(value, MAX_CONTEXT_BYTES))


def default_directory():
    base = os.environ.get("XDG_DATA_HOME")
    if not base or not os.path.isabs(base):
        base = str(Path.home() / ".local" / "share")
    return Path(base) / "ejn" / "findings"


@dataclass(frozen=True)
class Capture:
    """Immutable references frozen on the GUI thread, persisted by a worker."""

    image: object
    arrays: tuple
    metadata: dict
    sources: tuple = ()


def _write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def _digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _read(path, limit):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                raise FindingError("Invalid or oversized finding file.")
            data = stream.read(limit + 1)
            if len(data) > limit:
                raise FindingError("Finding file exceeds its size limit.")
            return data
    except OSError as exc:
        raise FindingError("Finding file is missing or unreadable.") from exc


def _note(value):
    if not isinstance(value, str) or len(value) > MAX_NOTE:
        raise FindingError("The finding note is too long.")
    return value


def _png(raw):
    if len(raw) > MAX_PNG_BYTES:
        raise FindingError("Saved image exceeds its size limit.")
    try:
        image = Image.open(io.BytesIO(raw))
        if (image.format != "PNG" or image.width * image.height > MAX_IMAGE_PIXELS
                or max(image.size) > MAX_IMAGE_EXTENT):
            image.close()
            raise FindingError("Invalid or oversized saved image.")
        image.load()
        return image
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise FindingError("Invalid saved image.") from exc


def _sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _org_text(value, limit=240):
    """Make captured text inert in headings and fixed-width example lines.

    Full-width delimiters keep user strings out of Org link syntax and the
    Emacs file-local-variable scanner. Exact originals remain in finding.json.
    """
    if not isinstance(value, str):
        value = str(value) if value is not None else ""
    value = " ".join(value.split())
    value = "".join(character for character in value if character.isprintable())
    value = value.translate(str.maketrans({"[": "［", "]": "］", "<": "‹", ">": "›", ":": "：",
                                         "{": "｛", "}": "｝", "(": "（", ")": "）",
                                         "\\": "＼", "$": "＄"}))
    return value[:limit] + ("…" if len(value) > limit else "")


def _org_context(view):
    lines = ["Recorded execution context; not a kernel-state backup.",
             "Text below is an escaped excerpt. The JSON link contains exact saved text."]
    contexts, seen = [], set()
    panes = view.get("panes", [])
    for pane in panes[:6] if isinstance(panes, list) else []:
        if not isinstance(pane, dict):
            continue
        lines.append("Pane: " + _org_text(pane.get("label") or pane.get("name"), 100))
        sources = pane.get("sources", [])
        for source in sources[:2] if isinstance(sources, list) else []:
            if not isinstance(source, dict):
                continue
            execution = source.get("execution", "unknown")
            lines.append("  Execution: " + _org_text(execution, 100))
            if source.get("selection") is not None:
                lines.append("  Slice: " + _org_text(json.dumps(source["selection"], ensure_ascii=False), 160))
            context = source.get("context", {})
            if not isinstance(context, dict):
                continue
            key = (str(source.get("workspace", "")), str(execution), str(context.get("source", "")))
            if key not in seen:
                seen.add(key)
                contexts.append((execution, context))
    for execution, context in contexts:
        lines.extend(("", "Execution " + _org_text(execution, 100),
                      "Source: " + _org_text(context.get("source", "not recorded"), 240)))
        entries = context.get("entries", [])
        entries = entries if isinstance(entries, list) else []
        if context.get("truncated") or len(entries) > 3:
            lines.append("Earlier context omitted here; inspect the complete saved JSON.")
        for entry in entries[-3:]:
            if not isinstance(entry, dict):
                continue
            lines.append("Run: " + _org_text(entry.get("id", ""), 60)
                         + " " + _org_text(entry.get("status", ""), 60))
            code = entry.get("code")
            if not isinstance(code, str):
                lines.append("[Code not retained]")
                continue
            code_lines = code.splitlines()
            lines.extend(_org_text(line, 200) for line in code_lines[:18])
            if len(code_lines) > 18 or entry.get("code_omitted"):
                lines.append("[Code excerpt shortened; see saved JSON]")
    raw = ("\n".join(": " + line for line in lines) + "\n").encode("utf-8")
    marker = b": [Context excerpt shortened; see saved JSON]\n"
    if len(raw) > MAX_ORG_CONTEXT_BYTES:
        raw = raw[:MAX_ORG_CONTEXT_BYTES - len(marker)].decode("utf-8", errors="ignore").encode("utf-8")
        raw = raw.rsplit(b"\n", 1)[0] + b"\n" + marker
    return raw.decode("utf-8")


def _preview_png(path, size, limit):
    raw = _read(path, limit)
    try:
        with Image.open(io.BytesIO(raw)) as image:
            if image.format != "PNG" or image.width > size[0] or image.height > size[1]:
                raise FindingError("Invalid finding preview.")
            image.load()
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise FindingError("Invalid finding preview.") from exc
    return raw


def _resized_png(image, size, limit):
    factor = min(1, size[0] / image.width, size[1] / image.height)
    dimensions = (max(1, round(image.width * factor)), max(1, round(image.height * factor)))
    with image.resize(dimensions, Image.Resampling.LANCZOS) as preview:
        with io.BytesIO() as buffer:
            preview.save(buffer, format="PNG")
            raw = buffer.getvalue()
    if len(raw) > limit:
        raise FindingError("The derived finding preview exceeds its size limit.")
    return raw


class FindingStore:
    def __init__(self, root=None, *, max_bytes=MAX_STORE_BYTES, max_count=MAX_FINDINGS):
        self.root = Path(root) if root is not None else default_directory()
        self.max_bytes = min(max_bytes, MAX_STORE_BYTES)
        self.max_count = min(max_count, MAX_FINDINGS)

    def _ensure(self):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.root.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise FindingError("The findings directory must be private (mode 0700).")

    @contextmanager
    def _lock(self):
        self._ensure()
        fd = os.open(self.root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        except BlockingIOError as exc:
            raise FindingError("Another viewer is updating findings; try again.") from exc
        finally:
            os.close(fd)

    def _path(self, identifier):
        if not isinstance(identifier, str) or not _ID.fullmatch(identifier):
            raise FindingError("Invalid finding identifier.")
        path = self.root / identifier
        try:
            info = path.lstat()
        except OSError as exc:
            raise FindingError("Finding is no longer available.") from exc
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise FindingError("Invalid finding directory.")
        return path

    def _directories(self):
        self._ensure()
        found = []
        # Bound even corrupted directories with excessive foreign entries.
        with os.scandir(self.root) as entries:
            for index, entry in enumerate(entries):
                if index >= MAX_FINDINGS * 8:
                    raise FindingError("Too many files in the findings directory.")
                if _ID.fullmatch(entry.name):
                    found.append(self._path(entry.name))
                    if len(found) > MAX_FINDINGS:
                        raise FindingError("Too many saved findings.")
        return found

    def _usage(self):
        directories = self._directories()
        total = 0
        for directory in directories:
            with os.scandir(directory) as files:
                for index, entry in enumerate(files):
                    if index > 16 or not entry.is_file(follow_symlinks=False):
                        raise FindingError("Unexpected files in a finding directory.")
                    total += entry.stat(follow_symlinks=False).st_size
        try:
            index = (self.root / "findings.org").lstat()
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(index.st_mode):
                raise FindingError("The generated overview path is not a regular file.")
            total += index.st_size
        return len(directories), total

    def _discard_interrupted_saves(self):
        # The nonblocking store lock proves no other writer owns staging.
        # Cleanup is bounded and never touches committed UUID directories.
        with os.scandir(self.root) as entries:
            for index, entry in enumerate(entries):
                if index >= MAX_FINDINGS * 8:
                    raise FindingError("Too many files in the findings directory.")
                if entry.name.startswith(".saving-") and entry.is_dir(follow_symlinks=False):
                    shutil.rmtree(entry.path)
                elif re.fullmatch(r"\.overview-[0-9a-f]{32}", entry.name) and entry.is_file(follow_symlinks=False):
                    info = entry.stat(follow_symlinks=False)
                    if info.st_uid == os.geteuid() and info.st_nlink == 1:
                        os.unlink(entry.path)

    def save(self, capture: Capture, note=""):
        """Persist an already frozen view, with independent numerical samples."""
        metadata = json.loads(json_bytes(capture.metadata))
        _note(note)
        if not 1 <= len(capture.arrays) <= 6:
            raise FindingError("A finding must contain one to six displayed planes.")
        arrays = []
        for array in capture.arrays:
            if (not isinstance(array, np.ndarray) or array.flags.writeable
                    or array.ndim not in (2, 3) or array.dtype.kind not in "uif"
                    or array.dtype.hasobject):
                raise FindingError("Capture requires immutable local image samples.")
            arrays.append(array)
        if sum(array.nbytes for array in arrays) > MAX_CAPTURE_BYTES:
            raise FindingError("Selected planes exceed the capture size limit.")
        image = capture.image
        if not isinstance(image, Image.Image):
            # QImage is detached on the GUI thread. Encoding operates only on
            # this independent value, never on a widget or QPixmap.
            from PySide6 import QtCore
            buffer = QtCore.QBuffer()
            buffer.open(QtCore.QIODevice.OpenModeFlag.WriteOnly)
            if not image.save(buffer, "PNG"):
                raise FindingError("Could not encode the captured image.")
            raw_image = bytes(buffer.data())
            buffer.close()
            del buffer
            image = _png(raw_image)
        else:
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            raw_image = buffer.getvalue()
            _png(raw_image)
        thumb = _resized_png(image, (120, 80), 48 * 1024)
        overview = _resized_png(image, OVERVIEW_SIZE, MAX_OVERVIEW_BYTES)
        identifier = uuid.uuid4().hex
        manifest = {"version": 1, "id": identifier,
                    "created": datetime.now(timezone.utc).isoformat(),
                    "note": note, "view": metadata, "planes": [],
                    "image_sha256": hashlib.sha256(raw_image).hexdigest()}
        with self._lock():
            self._discard_interrupted_saves()
            count, used = self._usage()
            reserve = (sum(array.nbytes + 1024 for array in arrays) + len(raw_image)
                       + len(thumb) + len(overview) + MAX_MANIFEST_BYTES)
            if count >= self.max_count or used + reserve > self.max_bytes:
                raise FindingError("Findings storage is full; remove saved findings to make room.")
            stage = Path(tempfile.mkdtemp(prefix=".saving-", dir=self.root))
            try:
                _write(stage / "image.png", raw_image)
                _write(stage / "thumbnail.png", thumb)
                _write(stage / "overview.png", overview)
                for index, array in enumerate(arrays):
                    name = f"plane-{index}.npy"
                    path = stage / name
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, "wb") as stream:
                        np.save(stream, array, allow_pickle=False)
                        stream.flush()
                        os.fsync(stream.fileno())
                    manifest["planes"].append({"file": name, "shape": list(array.shape),
                                               "dtype": array.dtype.str,
                                               "nbytes": array.nbytes,
                                               "sha256": _digest_file(path)})
                _write(stage / "finding.json", json_bytes(manifest))
                _sync_directory(stage)
                os.rename(stage, self.root / identifier)
                _sync_directory(self.root)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
        return manifest

    def manifest(self, identifier):
        try:
            value = json.loads(_read(self._path(identifier) / "finding.json", MAX_MANIFEST_BYTES))
            if (not isinstance(value, dict) or value.get("version") != 1
                    or value.get("id") != identifier or not isinstance(value.get("view"), dict)
                    or not isinstance(value.get("created"), str) or len(value["created"]) > 64
                    or not isinstance(value.get("planes"), list) or not 1 <= len(value["planes"]) <= 6
                    or not re.fullmatch("[0-9a-f]{64}", value.get("image_sha256", ""))):
                raise FindingError("Invalid saved finding schema.")
            _note(value.get("note"))
            json_bytes(value)
            total = 0
            for index, plane in enumerate(value["planes"]):
                if (plane.get("file") != f"plane-{index}.npy"
                        or not re.fullmatch("[0-9a-f]{64}", plane.get("sha256", ""))
                        or type(plane.get("nbytes")) is not int or not 1 <= plane["nbytes"] <= MAX_CAPTURE_BYTES
                        or not isinstance(plane.get("shape"), list)
                        or len(plane["shape"]) not in (2, 3)
                        or any(type(size) is not int or size <= 0 for size in plane["shape"])):
                    raise FindingError("Invalid saved plane schema.")
                dtype = np.dtype(plane["dtype"])
                if dtype.kind not in "uif" or dtype.hasobject:
                    raise FindingError("Invalid saved plane dtype.")
                size = dtype.itemsize
                for extent in plane["shape"]:
                    size *= extent
                if size != plane["nbytes"]:
                    raise FindingError("Invalid saved plane size.")
                total += size
            if total > MAX_CAPTURE_BYTES:
                raise FindingError("Saved planes exceed the capture size limit.")
            return value
        except (ValueError, TypeError, KeyError, AttributeError, RecursionError) as exc:
            raise FindingError("Invalid saved finding metadata.") from exc

    def catalog(self):
        items, errors = [], 0
        for path in self._directories():
            try:
                value = self.manifest(path.name)
                thumb = _preview_png(path / "thumbnail.png", (120, 80), 48 * 1024)
                items.append({key: value[key] for key in ("id", "created", "note")}
                             | {"thumbnail": thumb})
            except (FindingError, OSError):
                errors += 1
        return sorted(items, key=lambda item: (item["created"], item["id"])), errors

    def load(self, identifier, *, arrays=False):
        manifest = self.manifest(identifier)
        path = self._path(identifier)
        image = _read(path / "image.png", MAX_PNG_BYTES)
        if hashlib.sha256(image).hexdigest() != manifest["image_sha256"]:
            raise FindingError("Saved image is damaged.")
        _png(image)
        values = []
        if arrays:
            for info in manifest["planes"]:
                raw = _read(path / info["file"], info["nbytes"] + 1024)
                if hashlib.sha256(raw).hexdigest() != info["sha256"]:
                    raise FindingError("Saved numerical samples are damaged.")
                # Check the NPY header before NumPy can allocate its contents.
                stream = io.BytesIO(raw)
                version = np.lib.format.read_magic(stream)
                if version not in ((1, 0), (2, 0)):
                    raise FindingError("Unsupported saved plane format.")
                reader = (np.lib.format.read_array_header_1_0 if version == (1, 0)
                          else np.lib.format.read_array_header_2_0)
                shape, _fortran, dtype = reader(stream)
                if list(shape) != info["shape"] or dtype.str != info["dtype"]:
                    raise FindingError("Saved plane header differs from its metadata.")
                value = np.load(io.BytesIO(raw), allow_pickle=False)
                value.setflags(write=False)
                values.append(value)
        return manifest, image, tuple(values)

    def preview(self, identifier):
        manifest, raw, _ = self.load(identifier)
        image = _png(raw)
        image.thumbnail((2048, 2048))
        preview = io.BytesIO()
        image.save(preview, format="PNG")
        return manifest, raw, preview.getvalue()

    def update_note(self, identifier, note):
        _note(note)
        with self._lock():
            manifest = self.manifest(identifier)
            manifest["note"] = note
            path = self._path(identifier)
            temp = path / (".note-" + uuid.uuid4().hex)
            try:
                _write(temp, json_bytes(manifest))
                os.replace(temp, path / "finding.json")
                _sync_directory(path)
            finally:
                temp.unlink(missing_ok=True)
        return manifest

    def delete(self, identifiers):
        with self._lock():
            for identifier in identifiers[:MAX_FINDINGS]:
                shutil.rmtree(self._path(identifier))

    def _org_existing(self):
        path = self.root / "findings.org"
        try:
            info = path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise FindingError("The overview path is not a regular owned file; nothing was replaced.")
        raw = _read(path, MAX_ORG_BYTES)
        lines = raw.split(b"\n", 2)
        if (len(lines) != 3 or lines[0] + b"\n" != _ORG_MARKER
                or lines[1] != b"# body-sha256: " + hashlib.sha256(lines[2]).hexdigest().encode("ascii")):
            raise FindingError("findings.org has been edited. Move your report copy before regenerating the overview.")
        return (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size,
                hashlib.sha256(raw).digest())

    def org_overview(self):
        """Atomically regenerate a safe, portable overview without touching assets."""
        with self._lock():
            self._discard_interrupted_saves()
            original = self._org_existing()
            entries, skipped, section_bytes = [], 0, 0
            for path in self._directories():
                try:
                    manifest = self.manifest(path.name)
                    _preview_png(path / "overview.png", OVERVIEW_SIZE, MAX_OVERVIEW_BYTES)
                    note = manifest["note"] or "Untitled finding"
                    heading = _org_text(note, 200)
                    created = _org_text(manifest["created"], 40)
                    links = [f"[[file:{path.name}/image.png][Full image]]",
                             f"[[file:{path.name}/finding.json][Exact context and note]]"]
                    links.extend(f"[[file:{path.name}/{plane['file']}][Plane {index + 1} samples]]"
                                 for index, plane in enumerate(manifest["planes"]))
                    section = (f"* {heading}\n:PROPERTIES:\n:EJN_FINDING: {path.name}\n:END:\n"
                               f"Captured: {created}\n\n[[file:{path.name}/overview.png]]\n\n"
                               + " · ".join(links) + "\n")
                    if len(note) > 200:
                        section += "\nObservation:\n" + "\n".join(
                            ": " + _org_text(line, MAX_NOTE) for line in note.splitlines()) + "\n"
                    section += "\n** Context\n" + _org_context(manifest["view"]) + "\n"
                except (FindingError, OSError):
                    skipped += 1
                    continue
                encoded = section.encode("utf-8")
                section_bytes += len(encoded)
                if section_bytes > MAX_ORG_BYTES - 1024:
                    raise FindingError("The overview exceeds its 8 MiB text limit.")
                entries.append((manifest["created"], path.name, encoded))
            entries.sort(reverse=True)
            intro = ("#+TITLE: Saved findings\n#+STARTUP: content noinlineimages\n"
                     "#+OPTIONS: toc:nil num:nil\n\n"
                     "Generated read-only overview, newest capture first. Regenerate to refresh.\n"
                     "Save a separate copy to compose a report. Keep it alongside the asset folders\n"
                     "or copy the entire findings folder to preserve the relative links.\n\n"
                     f"{len(entries)} findings; {skipped} unreadable findings skipped.\n\n")
            body = intro.encode("utf-8") + b"".join(entry[2] for entry in entries)
            raw = _ORG_MARKER + b"# body-sha256: " + hashlib.sha256(body).hexdigest().encode("ascii") + b"\n" + body
            if len(raw) > MAX_ORG_BYTES:
                raise FindingError("The overview exceeds its 8 MiB text limit.")
            _count, usage = self._usage()
            if usage - (original[3] if original else 0) + len(raw) > self.max_bytes:
                raise FindingError("Findings storage is full; remove saved findings to make room.")
            stage = self.root / (".overview-" + uuid.uuid4().hex)
            try:
                _write(stage, raw)
                os.chmod(stage, 0o400)
                if self._org_existing() != original:
                    raise FindingError("The overview changed during generation; nothing was replaced.")
                os.replace(stage, self.root / "findings.org")
                _sync_directory(self.root)
            finally:
                stage.unlink(missing_ok=True)
        return {"path": str((self.root / "findings.org").absolute()),
                "count": len(entries), "skipped": skipped}
