"""Bounded normalization and admission-aware Jupyter output delivery.

The Jupyter client has already decoded an inbound message before this module
sees it. This layer cannot put a hard RSS bound around that decode. It does
avoid retaining the raw message: each job carries only a bounded snapshot,
except for one charged ASCII base64 artifact awaiting the sole worker.
"""

from __future__ import annotations

import asyncio
import math
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping

from ejn_array import MIME as ARRAY_MIME

from .artifacts import ArtifactError, ArtifactStore, PublishedArtifact
from .image_metadata import EJN_MAX_IMAGE_PIXELS
from .backend import BackendEvent

EJN_MAX_OUTPUT_TEXT_BYTES = 524_288
EJN_MAX_OUTPUT_ITEMS = 256
EJN_MAX_EVENT_TEXT_BYTES = 32_768
EJN_MAX_DISPLAY_ID_BYTES = 256
EJN_MAX_PENDING_OUTPUTS = 16
EJN_MAX_ARTIFACT_ENCODED_BYTES = ((67_108_864 + 2) // 3) * 4
EJN_MAX_RETAINED_OUTPUT_BYTES = EJN_MAX_ARTIFACT_ENCODED_BYTES + (
    2 * EJN_MAX_EVENT_TEXT_BYTES
)
EJN_MAX_PENDING_ARTIFACTS = 1
EJN_MAX_PENDING_ARTIFACT_BYTES = EJN_MAX_ARTIFACT_ENCODED_BYTES
EJN_MAX_METADATA_BYTES = 8_192
EJN_MAX_METADATA_ITEMS = 32
EJN_MAX_METADATA_DEPTH = 2
_MARKER_BYTES = 128
_ARTIFACT_MIMES = (
    ARRAY_MIME,
    "application/x-ejn-mpl-pickle",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
)
_WORKER_LIVENESS_INTERVAL = 0.05
_STOP = object()


@dataclass(slots=True)
class _OutputState:
    text_bytes: int = 0
    items: int = 0
    truncated: bool = False
    worker_marker: bool = False


@dataclass(frozen=True, slots=True)
class OutputAttachment:
    """Opaque generation handle returned by :meth:`OutputNormalizer.attach`."""

    generation: int


@dataclass(slots=True)
class _AttachmentState:
    store: ArtifactStore
    image_max_pixels: int
    retired: bool = False


@dataclass(slots=True)
class _OutputJob:
    """A sanitized output snapshot; it never references a raw Jupyter map."""

    attachment: OutputAttachment
    request_id: str
    message: Mapping[str, object] | None
    deliver: Callable[[BackendEvent], bool | None]
    retained_bytes: int
    artifact_bytes: int = 0
    marker_reason: str | None = None

    @property
    def key(self) -> tuple[int, str]:
        return (self.attachment.generation, self.request_id)


@dataclass(slots=True)
class _NormalizedEvent:
    event: BackendEvent
    published: tuple[PublishedArtifact, ...] = ()


def _take_utf8(text: str, ceiling: int) -> tuple[str, int, bool]:
    """Return at most CEILING UTF-8 bytes without encoding all of TEXT."""
    if ceiling <= 0:
        return "", 0, bool(text)
    if text.isascii():
        clipped = text[:ceiling]
        return clipped, len(clipped), len(clipped) != len(text)
    total = 0
    end = 0
    for character in text:
        size = len(character.encode("utf-8", "replace"))
        if total + size > ceiling:
            return text[:end], total, True
        total += size
        end += 1
    return text, total, False


def _small_marker(reason: str) -> str:
    return f"[EJN output omitted: {reason}]\n"


def _safe_metadata(value: object) -> tuple[dict[str, object], int, bool]:
    """Normalize metadata to a bounded JSON-safe subset.

    Protocol v1 retains MIME metadata but not an arbitrary object graph: it
    permits 32 items, two nested levels, and 8 KiB of UTF-8 strings. Excess or
    unsupported values are dropped and recorded by a bounded marker.
    """
    if not isinstance(value, Mapping):
        return {}, 0, value is not None
    budget = EJN_MAX_METADATA_BYTES
    items = 0
    truncated = False

    def take(current: object, depth: int) -> object | None:
        nonlocal budget, items, truncated
        if items >= EJN_MAX_METADATA_ITEMS:
            truncated = True
            return None
        items += 1
        if current is None or isinstance(current, bool):
            return current
        if type(current) is int:
            if -(1 << 53) < current < (1 << 53):
                return current
            truncated = True
            return None
        if type(current) is float:
            if math.isfinite(current):
                return current
            truncated = True
            return None
        if isinstance(current, str):
            clipped, size, shortened = _take_utf8(current, budget)
            budget -= size
            truncated = truncated or shortened
            return clipped
        if depth >= EJN_MAX_METADATA_DEPTH:
            truncated = True
            return None
        if isinstance(current, Mapping):
            output: dict[str, object] = {}
            for examined, (key, nested) in enumerate(current.items()):
                if examined >= EJN_MAX_METADATA_ITEMS or items >= EJN_MAX_METADATA_ITEMS:
                    truncated = True
                    break
                if not isinstance(key, str):
                    truncated = True
                    continue
                safe_key, key_size, key_shortened = _take_utf8(key, min(128, budget))
                budget -= key_size
                truncated = truncated or key_shortened
                if not safe_key:
                    truncated = True
                    continue
                safe_value = take(nested, depth + 1)
                if safe_value is not None:
                    output[safe_key] = safe_value
            return output
        if isinstance(current, (list, tuple)):
            output = []
            for nested in current:
                if items >= EJN_MAX_METADATA_ITEMS:
                    truncated = True
                    break
                safe_value = take(nested, depth + 1)
                if safe_value is not None:
                    output.append(safe_value)
            return output
        truncated = True
        return None

    normalized = take(value, 0)
    result = normalized if isinstance(normalized, dict) else {}
    if truncated:
        result["_ejn_metadata_truncated"] = True
    return result, EJN_MAX_METADATA_BYTES - budget, truncated


class OutputNormalizer:
    """One helper-global, ordered output/artifact coordinator.

    A backend creates exactly one instance for its whole lifetime. Individual
    connect attempts receive attachments, but every generation shares this
    queue, one artifact executor, and the retained-byte/artifact quotas. A
    published artifact remains helper-owned until ``deliver`` explicitly
    admits its event; rejected delivery rolls it back via the store lease.
    """

    def __init__(
        self,
        artifact_dir: str | None = None,
        *,
        artifact_store: ArtifactStore | None = None,
        image_max_pixels: int = EJN_MAX_IMAGE_PIXELS,
    ) -> None:
        if artifact_dir is not None and artifact_store is not None:
            raise ValueError("artifact directory and store are mutually exclusive")
        if (
            type(image_max_pixels) is not int
            or image_max_pixels < 0
            or image_max_pixels > EJN_MAX_IMAGE_PIXELS
        ):
            raise ValueError("image_max_pixels must be within the protocol ceiling")
        self._closed = False
        self._attachments: dict[int, _AttachmentState] = {}
        self._next_generation = 1
        self._default_attachment: OutputAttachment | None = None
        if artifact_dir is not None or artifact_store is not None:
            self._default_attachment = self.attach(
                artifact_dir,
                artifact_store=artifact_store,
                image_max_pixels=image_max_pixels,
            )
        self._executor: ThreadPoolExecutor | None = None
        self._queue: asyncio.Queue[_OutputJob | object] = asyncio.Queue(
            EJN_MAX_PENDING_OUTPUTS
        )
        self._worker_task: asyncio.Task[None] | None = None
        self._active_job: _OutputJob | None = None
        self._states: dict[tuple[int, str], _OutputState] = {}
        self._pending: dict[tuple[int, str], int] = {}
        self._settled: dict[tuple[int, str], asyncio.Future[None]] = {}
        self._overflow: dict[tuple[int, str], _OutputJob] = {}
        self._cancelled: set[tuple[int, str]] = set()
        self._retained_bytes = 0
        self._pending_artifacts = 0
        self._pending_artifact_bytes = 0
        self._worker_artifacts = 0
        self._worker_artifact_bytes = 0
        self._store_futures: set[Future[object]] = set()
        self._worker_failure: BaseException | None = None

    def attach(
        self,
        artifact_dir: str | None = None,
        *,
        artifact_store: ArtifactStore | None = None,
        image_max_pixels: int = EJN_MAX_IMAGE_PIXELS,
    ) -> OutputAttachment:
        """Create a connection generation without creating another worker."""
        if self._closed:
            raise RuntimeError("output normalizer is closed")
        if artifact_dir is not None and artifact_store is not None:
            raise ValueError("artifact directory and store are mutually exclusive")
        if (
            type(image_max_pixels) is not int
            or image_max_pixels < 0
            or image_max_pixels > EJN_MAX_IMAGE_PIXELS
        ):
            raise ValueError("image_max_pixels must be within the protocol ceiling")
        if artifact_store is None:
            if artifact_dir is None:
                raise ValueError("artifact directory is required")
            artifact_store = ArtifactStore(Path(artifact_dir))
        attachment = OutputAttachment(self._next_generation)
        self._next_generation += 1
        self._attachments[attachment.generation] = _AttachmentState(
            artifact_store, image_max_pixels
        )
        return attachment

    def retire(self, attachment: OutputAttachment | None) -> None:
        """Close admission for one detached connection generation."""
        if attachment is None:
            return
        state = self._attachments.get(attachment.generation)
        if state is None or state.retired:
            return
        state.retired = True
        keys = {
            key
            for key in set(self._states) | set(self._pending) | set(self._overflow)
            if key[0] == attachment.generation
        }
        for key in keys:
            self._cancel_key(key)
        self._close_retired_attachment(attachment.generation)

    def submit(self, *args: object) -> None:
        """Queue a bounded message snapshot in strict IOPub receive order.

        The normal form is ``submit(attachment, request_id, message, deliver)``.
        A directly constructed test normalizer may use its initial attachment
        with ``submit(request_id, message, deliver)``.
        """
        if len(args) == 4 and isinstance(args[0], OutputAttachment):
            attachment, request_id, message, deliver = args
        elif len(args) == 3 and self._default_attachment is not None:
            attachment = self._default_attachment
            request_id, message, deliver = args
        else:
            raise TypeError("submit needs an attachment, request id, message, and deliver")
        if (
            self._closed
            or not isinstance(attachment, OutputAttachment)
            or not isinstance(request_id, str)
            or not isinstance(message, Mapping)
            or not callable(deliver)
        ):
            return
        attachment_state = self._attachments.get(attachment.generation)
        if attachment_state is None or attachment_state.retired:
            return
        key = (attachment.generation, request_id)
        state = self._states.setdefault(key, _OutputState())
        if state.truncated or state.worker_marker or key in self._cancelled:
            return
        snapshot, retained_bytes, artifact_bytes, marker_reason = self._snapshot(message)
        if marker_reason is not None:
            self._queue_marker(attachment, request_id, state, deliver, marker_reason)
            return
        assert snapshot is not None
        if (
            self._queue.qsize() >= EJN_MAX_PENDING_OUTPUTS - 1
            or self._retained_bytes + retained_bytes
            > EJN_MAX_RETAINED_OUTPUT_BYTES - _MARKER_BYTES
            or (
                artifact_bytes
                and (
                    self._pending_artifacts >= EJN_MAX_PENDING_ARTIFACTS
                    or self._pending_artifact_bytes + artifact_bytes
                    > EJN_MAX_PENDING_ARTIFACT_BYTES
                )
            )
        ):
            self._queue_marker(
                attachment, request_id, state, deliver, "output worker is busy"
            )
            return
        job = _OutputJob(
            attachment,
            request_id,
            snapshot,
            deliver,
            retained_bytes,
            artifact_bytes,
        )
        self._accept_job(job)
        self._queue.put_nowait(job)
        self._start_worker()

    def _snapshot(
        self, message: Mapping[str, object]
    ) -> tuple[Mapping[str, object] | None, int, int, str | None]:
        """Retain only selected, bounded output fields from one decoded map."""
        message_type = message.get("msg_type")
        content = message.get("content", {})
        if not isinstance(content, Mapping):
            return None, 0, 0, "malformed output"
        if message_type == "stream":
            text = content.get("text")
            if not isinstance(text, str):
                return (
                    {"msg_type": "stream", "content": {"name": "stdout", "text": None}},
                    0,
                    0,
                    None,
                )
            clipped, size, shortened = _take_utf8(text, EJN_MAX_EVENT_TEXT_BYTES)
            return (
                {
                    "msg_type": "stream",
                    "content": {
                        "name": content.get("name")
                        if content.get("name") in {"stdout", "stderr"}
                        else "stdout",
                        "text": clipped,
                    },
                    "_ejn_snapshot_truncated": shortened,
                },
                size,
                0,
                None,
            )
        if message_type == "error":
            values: dict[str, object] = {}
            retained = 0
            truncated = False
            for key, ceiling in (("ename", 256), ("evalue", 2048)):
                value = content.get(key)
                if isinstance(value, str):
                    clipped, size, shortened = _take_utf8(value, ceiling)
                    values[key] = clipped
                    retained += size
                    truncated = truncated or shortened
            lines = content.get("traceback")
            if isinstance(lines, list):
                safe_lines = []
                for line in lines[:8]:
                    if isinstance(line, str):
                        clipped, size, shortened = _take_utf8(line, 2048)
                        safe_lines.append(clipped)
                        retained += size
                        truncated = truncated or shortened
                values["traceback"] = safe_lines
                truncated = truncated or len(lines) > len(safe_lines)
            return (
                {"msg_type": "error", "content": values, "_ejn_snapshot_truncated": truncated},
                retained,
                0,
                None,
            )
        if message_type == "clear_output":
            return (
                {
                    "msg_type": "clear_output",
                    "content": {"wait": content.get("wait") is True},
                },
                0,
                0,
                None,
            )
        if message_type not in {"execute_result", "display_data", "update_display_data"}:
            return None, 0, 0, "unsupported output"

        data = content.get("data")
        if not isinstance(data, Mapping):
            return None, 0, 0, "malformed rich output"
        safe_content: dict[str, object] = {}
        metadata, metadata_bytes, _metadata_truncated = _safe_metadata(
            content.get("metadata")
        )
        safe_content["metadata"] = metadata
        retained = metadata_bytes
        transient = content.get("transient")
        if isinstance(transient, Mapping) and isinstance(transient.get("display_id"), str):
            display_id = transient["display_id"]
            kept, size, shortened = _take_utf8(display_id, EJN_MAX_DISPLAY_ID_BYTES)
            retained += size
            if shortened:
                safe_content["transient"] = {"display_id_omitted": True}
            else:
                safe_content["transient"] = {"display_id": kept}
        if message_type == "execute_result":
            count = content.get("execution_count")
            if type(count) is int and 0 <= count < (1 << 53):
                safe_content["execution_count"] = count
        artifacts: dict[str, str] = {}
        image_added = False
        # Presence is authoritative, even when malformed: numerical output
        # never falls back to a raster/pickle from the same publication.
        if ARRAY_MIME in data:
            payload = data[ARRAY_MIME]
            if not isinstance(payload, str) or not payload:
                return None, 0, 0, "invalid numerical artifact"
            if len(payload) > EJN_MAX_ARTIFACT_ENCODED_BYTES:
                return None, 0, 0, "artifact exceeds the byte limit"
            if not payload.isascii():
                return None, 0, 0, "invalid numerical artifact"
            safe_content["data"] = {ARRAY_MIME: payload}
            return ({"msg_type": message_type, "content": safe_content},
                    retained + len(payload), len(payload), None)
        # A rich figure may carry its thumbnail and interactive pickle.  Keep
        # exactly those two bounded payloads in one job so their publication
        # leases transfer or roll back atomically at delivery.
        for mime in _ARTIFACT_MIMES:
            payload = data.get(mime)
            if payload is None:
                continue
            if not isinstance(payload, str):
                return None, 0, 0, "artifact unavailable"
            if len(payload) > EJN_MAX_ARTIFACT_ENCODED_BYTES:
                return None, 0, 0, "artifact exceeds the byte limit"
            if not payload.isascii():
                return None, 0, 0, "invalid artifact"
            if mime == "application/x-ejn-mpl-pickle" or not image_added:
                artifacts[mime] = payload
                image_added = image_added or mime != "application/x-ejn-mpl-pickle"
            if len(artifacts) == 2:
                break
        if artifacts:
            encoded_bytes = sum(len(payload) for payload in artifacts.values())
            if encoded_bytes > EJN_MAX_PENDING_ARTIFACT_BYTES:
                return None, 0, 0, "artifact exceeds the byte limit"
            safe_content["data"] = artifacts
            return (
                {"msg_type": message_type, "content": safe_content},
                retained + encoded_bytes,
                encoded_bytes,
                None,
            )
        text = data.get("text/plain")
        if isinstance(text, str):
            clipped, size, shortened = _take_utf8(text, EJN_MAX_EVENT_TEXT_BYTES)
            safe_content["data"] = {"text/plain": clipped}
            return (
                {
                    "msg_type": message_type,
                    "content": safe_content,
                    "_ejn_snapshot_truncated": shortened,
                },
                retained + size,
                0,
                None,
            )
        mime = next(iter(data), "unknown")
        if not isinstance(mime, str):
            mime = "unknown"
        mime, size, _shortened = _take_utf8(mime, 128)
        safe_content["data"] = {"_ejn_unsupported_mime": mime}
        return {"msg_type": message_type, "content": safe_content}, retained + size, 0, None

    def _queue_marker(
        self,
        attachment: OutputAttachment,
        request_id: str,
        state: _OutputState,
        deliver: Callable[[BackendEvent], bool | None],
        reason: str,
    ) -> None:
        if state.worker_marker:
            return
        state.worker_marker = True
        if self._retained_bytes + _MARKER_BYTES > EJN_MAX_RETAINED_OUTPUT_BYTES:
            # The aggregate retained-byte ceiling takes precedence over a
            # second local marker. EventQueue still emits its own mandatory
            # marker when an already-normalized event is dropped downstream.
            return
        job = _OutputJob(
            attachment, request_id, None, deliver, _MARKER_BYTES, marker_reason=reason
        )
        self._accept_job(job)
        if self._queue.full():
            self._overflow[job.key] = job
        else:
            self._queue.put_nowait(job)
        self._start_worker()

    def _accept_job(self, job: _OutputJob) -> None:
        self._pending[job.key] = self._pending.get(job.key, 0) + 1
        settled = self._settled.get(job.key)
        if settled is None or settled.done():
            self._settled[job.key] = asyncio.get_running_loop().create_future()
        self._retained_bytes += job.retained_bytes
        if job.artifact_bytes:
            self._pending_artifacts += 1
            self._pending_artifact_bytes += job.artifact_bytes

    def _start_worker(self) -> None:
        if self._worker_task is None:
            self._worker_task = asyncio.create_task(self._worker())
            self._worker_task.add_done_callback(self._worker_stopped)

    def _worker_stopped(self, task: asyncio.Task[None]) -> None:
        """Wake finish waiters if the sole worker ever stops unexpectedly."""
        if task.cancelled():
            self._worker_failure = RuntimeError("output worker was cancelled")
        else:
            try:
                failure = task.exception()
            except asyncio.CancelledError:
                failure = RuntimeError("output worker was cancelled")
            if failure is not None:
                self._worker_failure = failure
        for settled in self._settled.values():
            if not settled.done():
                settled.set_result(None)

    def _raise_worker_failure(self) -> None:
        task = self._worker_task
        if task is not None and task.done() and self._worker_failure is None:
            # Done callbacks run promptly, but inspect the task here as well
            # so a just-stopped worker cannot race a finish waiter.
            self._worker_stopped(task)
        if self._worker_failure is not None:
            raise RuntimeError("output worker stopped") from self._worker_failure

    @staticmethod
    def _set_waiter_result(waiter: asyncio.Future[object], result: object) -> None:
        if not waiter.done():
            waiter.set_result(result)

    @staticmethod
    def _set_waiter_exception(
        waiter: asyncio.Future[object], error: BaseException
    ) -> None:
        if not waiter.done():
            waiter.set_exception(error)

    async def _await_store_future(self, future: Future[object]) -> object:
        """Bridge a concurrent future onto this loop without a completion race."""
        loop = asyncio.get_running_loop()
        waiter: asyncio.Future[object] = loop.create_future()

        def finished(completed: Future[object]) -> None:
            try:
                result = completed.result()
            except BaseException as error:
                try:
                    loop.call_soon_threadsafe(
                        self._set_waiter_exception, waiter, error
                    )
                except RuntimeError:
                    pass
            else:
                try:
                    loop.call_soon_threadsafe(
                        self._set_waiter_result, waiter, result
                    )
                except RuntimeError:
                    pass

        future.add_done_callback(finished)
        return await waiter

    async def finish(self, *args: object) -> None:
        """Flush one request's admitted output without crossing generations."""
        if len(args) == 2 and isinstance(args[0], OutputAttachment):
            attachment, request_id = args
        elif len(args) == 1 and self._default_attachment is not None:
            attachment, request_id = self._default_attachment, args[0]
        else:
            raise TypeError("finish needs an attachment and request id")
        if not isinstance(attachment, OutputAttachment) or not isinstance(request_id, str):
            return
        key = (attachment.generation, request_id)
        # The count is the ownership authority. The settlement future handles
        # ordinary completion. Its bounded liveness check also observes a
        # crashed worker promptly, including runtimes that defer executor
        # wakeups until the next timer tick.
        while self._pending.get(key, 0):
            self._raise_worker_failure()
            settled = self._settled.get(key)
            if settled is None:
                raise RuntimeError("output worker lost its completion signal")
            try:
                await asyncio.wait_for(
                    asyncio.shield(settled), _WORKER_LIVENESS_INTERVAL
                )
            except TimeoutError:
                pass
        self._raise_worker_failure()
        self._states.pop(key, None)
        self._cancelled.discard(key)
        self._settled.pop(key, None)

    def has_pending(self, attachment: OutputAttachment | None, request_id: str) -> bool:
        return attachment is not None and self._pending.get(
            (attachment.generation, request_id), 0
        ) > 0

    def cancel(self, attachment: OutputAttachment | None, request_id: str) -> None:
        if attachment is not None:
            self._cancel_key((attachment.generation, request_id))

    def _cancel_key(self, key: tuple[int, str]) -> None:
        self._cancelled.add(key)
        self._states.pop(key, None)
        overflow = self._overflow.pop(key, None)
        if overflow is not None:
            self._settle(overflow)
        if not self._pending.get(key, 0):
            self._forget_cancelled(key)

    async def _worker(self) -> None:
        while True:
            queued = await self._queue.get()
            if queued is _STOP:
                self._queue.task_done()
                return
            assert isinstance(queued, _OutputJob)
            job = queued
            self._active_job = job
            try:
                attachment_state = self._attachments.get(job.attachment.generation)
                if (
                    job.key not in self._cancelled
                    and attachment_state is not None
                    and not attachment_state.retired
                ):
                    try:
                        if job.artifact_bytes and (
                            job.artifact_bytes > EJN_MAX_PENDING_ARTIFACT_BYTES
                            or self._worker_artifacts >= EJN_MAX_PENDING_ARTIFACTS
                            or self._worker_artifact_bytes + job.artifact_bytes
                            > EJN_MAX_PENDING_ARTIFACT_BYTES
                        ):
                            events = [
                                _NormalizedEvent(
                                    self._marker_for(
                                        job.key, "artifact worker quota reached"
                                    )
                                )
                            ]
                        elif job.marker_reason is not None:
                            events = [
                                _NormalizedEvent(
                                    self._marker_for(job.key, job.marker_reason)
                                )
                            ]
                        else:
                            assert job.message is not None
                            if job.artifact_bytes:
                                self._worker_artifacts += 1
                                self._worker_artifact_bytes += job.artifact_bytes
                            try:
                                events = await self._normalize(job, attachment_state)
                            finally:
                                if job.artifact_bytes:
                                    self._worker_artifacts -= 1
                                    self._worker_artifact_bytes -= job.artifact_bytes
                    except Exception:
                        events = [
                            _NormalizedEvent(
                                self._marker_for(
                                    job.key, "output normalization failed"
                                )
                            )
                        ]
                    for normalized in events:
                        admitted = False
                        if job.key not in self._cancelled and not attachment_state.retired:
                            try:
                                # Direct in-memory sinks normally return None;
                                # Dispatcher returns False only for a dropped event.
                                admitted = job.deliver(normalized.event) is not False
                            except Exception:
                                admitted = False
                        if not admitted:
                            for published in normalized.published:
                                await self._discard(attachment_state.store, published)
            finally:
                # A retired generation with an active artifact must keep its
                # store open through publication/discard, but can be released
                # as soon as that one worker job finishes.
                self._active_job = None
                self._settle(job)
                self._queue.task_done()
                self._drain_overflow()

    async def _discard(
        self, store: ArtifactStore, published: PublishedArtifact
    ) -> None:
        """Roll back through the one artifact executor, never the event loop."""
        try:
            if self._executor is None:
                self._executor = ThreadPoolExecutor(
                    max_workers=1, thread_name_prefix="ejn-artifact"
                )
            future = self._executor.submit(store.discard, published)
            self._store_futures.add(future)
            future.add_done_callback(self._store_futures.discard)
            await self._await_store_future(future)
        except Exception:
            # Never retry using a path from a protocol event.
            pass

    def _drain_overflow(self) -> None:
        while self._overflow and not self._queue.full():
            key = next(iter(self._overflow))
            job = self._overflow.pop(key)
            if key in self._cancelled:
                self._settle(job)
            else:
                self._queue.put_nowait(job)

    def _settle(self, job: _OutputJob) -> None:
        pending = self._pending.get(job.key, 0)
        if pending <= 0 or self._retained_bytes < job.retained_bytes:
            raise RuntimeError("output accounting underflow")
        self._retained_bytes -= job.retained_bytes
        if job.artifact_bytes:
            if (
                self._pending_artifacts <= 0
                or self._pending_artifact_bytes < job.artifact_bytes
            ):
                raise RuntimeError("artifact accounting underflow")
            self._pending_artifacts -= 1
            self._pending_artifact_bytes -= job.artifact_bytes
        remaining = pending - 1
        if remaining <= 0:
            self._pending.pop(job.key, None)
            settled = self._settled.get(job.key)
            if settled is not None and not settled.done():
                settled.set_result(None)
            if job.key in self._cancelled:
                self._forget_cancelled(job.key)
        else:
            self._pending[job.key] = remaining
        self._close_retired_attachment(job.attachment.generation)

    def _forget_cancelled(self, key: tuple[int, str]) -> None:
        self._states.pop(key, None)
        self._cancelled.discard(key)
        self._settled.pop(key, None)

    def _close_retired_attachment(self, generation: int) -> None:
        state = self._attachments.get(generation)
        if state is None or not state.retired:
            return
        active = self._active_job
        if (
            active is not None
            and active.attachment.generation == generation
            and active.artifact_bytes
        ):
            return
        state.store.close()
        self._attachments.pop(generation, None)
        if (
            self._default_attachment is not None
            and self._default_attachment.generation == generation
        ):
            self._default_attachment = None

    def _marker_for(self, key: tuple[int, str], reason: str) -> BackendEvent:
        state = self._states.setdefault(key, _OutputState())
        return self._marker(state, reason)

    async def _normalize(
        self, job: _OutputJob, attachment_state: _AttachmentState
    ) -> list[_NormalizedEvent]:
        state = self._states.setdefault(job.key, _OutputState())
        assert job.message is not None
        message_type = job.message.get("msg_type")
        content = job.message.get("content", {})
        if not isinstance(content, Mapping):
            return [_NormalizedEvent(self._marker(state, "malformed output"))]
        if message_type == "stream":
            events: list[BackendEvent | _NormalizedEvent] = self._stream(state, content)
        elif message_type == "error":
            events = self._error(state, content)
        elif message_type == "clear_output":
            events = [BackendEvent("clear_output", {"wait": content.get("wait") is True})]
        elif message_type in {"execute_result", "display_data", "update_display_data"}:
            events = await self._rich(
                state, message_type, content, attachment_state
            )
        else:
            events = [self._marker(state, "unsupported output")]
        if job.message.get("_ejn_snapshot_truncated") and not state.truncated:
            events.append(self._marker(state, "output limit reached"))
        return [
            event if isinstance(event, _NormalizedEvent) else _NormalizedEvent(event)
            for event in events
        ]

    def _admit_item(self, state: _OutputState) -> bool:
        if state.truncated or state.items >= EJN_MAX_OUTPUT_ITEMS:
            return False
        state.items += 1
        return True

    def _marker(self, state: _OutputState, reason: str) -> BackendEvent:
        state.truncated = True
        return BackendEvent("stream", {"name": "stderr", "text": _small_marker(reason)})

    def _text(self, state: _OutputState, name: str, text: object) -> list[BackendEvent]:
        if state.truncated:
            return []
        if not isinstance(text, str):
            return [self._marker(state, "malformed text")]
        if not self._admit_item(state):
            return [self._marker(state, "output limit reached")]
        remaining = EJN_MAX_OUTPUT_TEXT_BYTES - state.text_bytes
        clipped, byte_count, shortened = _take_utf8(
            text, min(EJN_MAX_EVENT_TEXT_BYTES, max(remaining, 0))
        )
        if byte_count == 0 and text:
            return [self._marker(state, "output limit reached")]
        state.text_bytes += byte_count
        events = [BackendEvent("stream", {"name": name, "text": clipped})]
        if shortened or state.text_bytes >= EJN_MAX_OUTPUT_TEXT_BYTES:
            events.append(self._marker(state, "output limit reached"))
        return events

    def _stream(self, state: _OutputState, content: Mapping[str, object]) -> list[BackendEvent]:
        name = content.get("name")
        return self._text(
            state, name if name in {"stdout", "stderr"} else "stdout", content.get("text")
        )

    def _error(self, state: _OutputState, content: Mapping[str, object]) -> list[BackendEvent]:
        ename = content.get("ename")
        evalue = content.get("evalue")
        lines = content.get("traceback")
        text = ""
        if isinstance(ename, str):
            text += ename
        if isinstance(evalue, str):
            text += (": " if text else "") + evalue
        if isinstance(lines, list):
            safe_lines = [line for line in lines if isinstance(line, str)]
            if safe_lines:
                text += ("\n" if text else "") + "\n".join(safe_lines)
        return self._text(state, "stderr", text or "Jupyter execution error")

    async def _rich(
        self,
        state: _OutputState,
        message_type: object,
        content: Mapping[str, object],
        attachment_state: _AttachmentState,
    ) -> list[BackendEvent | _NormalizedEvent]:
        if state.truncated:
            return []
        if not self._admit_item(state):
            return [self._marker(state, "output limit reached")]
        data = content.get("data")
        metadata = content.get("metadata")
        if not isinstance(data, Mapping) or not isinstance(metadata, Mapping):
            return [self._marker(state, "malformed rich output")]
        event_name = "execute_result" if message_type == "execute_result" else "display_data"
        base: dict[str, object] = {"data": {}, "metadata": dict(metadata)}
        transient = content.get("transient")
        if isinstance(transient, Mapping):
            base["transient"] = dict(transient)
        if message_type == "update_display_data":
            base["update"] = True
        if message_type == "execute_result" and type(content.get("execution_count")) is int:
            base["execution_count"] = content["execution_count"]
        artifacts = [
            (mime, data[mime]) for mime in _ARTIFACT_MIMES if mime in data
        ]
        if artifacts:
            return [
                await self._artifact_event(
                    state, event_name, base, artifacts, attachment_state
                )
            ]
        text = data.get("text/plain")
        if isinstance(text, str):
            remaining = EJN_MAX_OUTPUT_TEXT_BYTES - state.text_bytes
            clipped, byte_count, shortened = _take_utf8(
                text, min(EJN_MAX_EVENT_TEXT_BYTES, max(remaining, 0))
            )
            if byte_count == 0 and text:
                return [self._marker(state, "output limit reached")]
            state.text_bytes += byte_count
            base["data"] = {"text/plain": clipped}
            events: list[BackendEvent | _NormalizedEvent] = [
                BackendEvent(event_name, base)
            ]
            if shortened or state.text_bytes >= EJN_MAX_OUTPUT_TEXT_BYTES:
                events.append(self._marker(state, "output limit reached"))
            return events
        mime = data.get("_ejn_unsupported_mime", "unknown")
        base["data"] = {
            "text/plain": _small_marker(f"unsupported MIME {mime}").rstrip()
        }
        return [BackendEvent(event_name, base)]

    async def _artifact_event(
        self,
        state: _OutputState,
        event_name: str,
        base: dict[str, object],
        artifacts: list[tuple[str, object]],
        attachment_state: _AttachmentState,
    ) -> BackendEvent | _NormalizedEvent:
        published: list[PublishedArtifact] = []
        descriptors: dict[str, object] = {}
        store = attachment_state.store
        try:
            if self._executor is None:
                self._executor = ThreadPoolExecutor(
                    max_workers=1, thread_name_prefix="ejn-artifact"
                )
            for mime, payload in artifacts:
                if not isinstance(payload, str):
                    raise ArtifactError("artifact unavailable")
                image_mime = mime.startswith("image/")
                if mime == ARRAY_MIME:
                    future = self._executor.submit(store.make_array, payload)
                elif image_mime and attachment_state.image_max_pixels:
                    future = self._executor.submit(
                        store.make_image,
                        payload,
                        mime,
                        max_source_pixels=attachment_state.image_max_pixels,
                    )
                else:
                    future = self._executor.submit(store.store_base64, payload)
                self._store_futures.add(future)
                future.add_done_callback(self._store_futures.discard)
                result = await self._await_store_future(future)
                if mime == ARRAY_MIME:
                    artifact = result.original
                    published.append(artifact)
                    descriptor = {
                        "path": str(artifact.path),
                        "bytes": artifact.byte_count,
                        "sha256": artifact.sha256,
                        "manifest": result.manifest,
                    }
                elif image_mime:
                    if attachment_state.image_max_pixels:
                        original = result.original
                        preview = result.preview
                        width = result.width
                        height = result.height
                    else:
                        original = result
                        preview = None
                        width = None
                        height = None
                    published.append(original)
                    descriptor = {
                        "original": {
                            "path": str(original.path),
                            "bytes": original.byte_count,
                            "sha256": original.sha256,
                        }
                    }
                    if preview is not None:
                        published.append(preview)
                        descriptor["preview"] = {
                            "path": str(preview.path),
                            "bytes": preview.byte_count,
                            "sha256": preview.sha256,
                            "mime": "image/x-portable-pixmap",
                            "width": width,
                            "height": height,
                        }
                else:
                    artifact = result
                    published.append(artifact)
                    descriptor = {
                        "path": str(artifact.path),
                        "bytes": artifact.byte_count,
                        "sha256": artifact.sha256,
                    }
                descriptors[mime] = descriptor
        except ArtifactError:
            for artifact in published:
                await self._discard(store, artifact)
            return self._marker(state, "invalid artifact")
        except Exception:
            for artifact in published:
                await self._discard(store, artifact)
            return self._marker(state, "artifact publication failed")
        base["data"] = descriptors
        return _NormalizedEvent(BackendEvent(event_name, base), tuple(published))

    def close(self) -> None:
        """Stop admission, roll back unhanded work, and retain handed files."""
        if self._closed:
            return
        self._closed = True
        for attachment in tuple(
            OutputAttachment(generation) for generation in self._attachments
        ):
            self.retire(attachment)
        while True:
            try:
                queued = self._queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            if isinstance(queued, _OutputJob):
                self._settle(queued)
            self._queue.task_done()
        for job in tuple(self._overflow.values()):
            self._settle(job)
        self._overflow.clear()
        if self._worker_task is not None:
            self._queue.put_nowait(_STOP)
        else:
            for attachment in self._attachments.values():
                attachment.store.close()

    async def wait_closed(self) -> None:
        """Join the one worker and all active store futures before shutdown."""
        if self._worker_task is not None:
            try:
                await self._worker_task
            except (asyncio.CancelledError, Exception):
                pass
        while self._store_futures:
            futures = tuple(self._store_futures)
            await asyncio.gather(
                *(self._await_store_future(future) for future in futures),
                return_exceptions=True,
            )
        if self._executor is not None:
            self._executor.shutdown(wait=True, cancel_futures=True)
        for attachment in self._attachments.values():
            attachment.store.close()
