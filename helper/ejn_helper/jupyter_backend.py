"""Local-only async adapter around Jupyter's asynchronous client."""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import math
import os
import stat
from dataclasses import dataclass
from queue import Empty
from pathlib import Path
from typing import Mapping

from .backend import BackendCompletion, BackendError, BackendEvent
from .outputs import OutputAttachment, OutputNormalizer
from .requests import ExecutionState


_LOOPBACK = {"127.0.0.1", "::1"}
_PORTS = ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")
_CHANNELS = ("shell", "iopub", "stdin", "control")
_LOGGER = logging.getLogger(__name__)

# Auxiliary replies are user-facing data and must not be allowed to turn a
# single completion/doc request into an unbounded response.
MAX_COMPLETION_MATCHES = 256
MAX_COMPLETION_ITEM_BYTES = 4096
MAX_DOCUMENTATION_BYTES = 16_384
MAX_AUX_MAPPING_ITEMS = 128
MAX_AUX_RESPONSE_BYTES = 48_000
MAX_AUX_NESTING = 3
MAX_AUX_INTEGER = 2**53 - 1
MAX_AUX_CURSOR = 524_288
_AUX_OMIT = object()


def _take_aux_text(
    value: str, raw_ceiling: int, wire_ceiling: int
) -> tuple[str, int, bool]:
    """Clip VALUE by raw UTF-8 and worst-case JSON wire bytes.

    Work is proportional to the admitted prefix.  In particular this never
    encodes or scans the full hostile string before enforcing a bound.
    """
    output = []
    raw_bytes = 0
    wire_bytes = 0
    for character in value:
        codepoint = ord(character)
        if 0xD800 <= codepoint <= 0xDFFF:
            raise BackendError("protocol-error")
        if codepoint <= 0x7F:
            raw_size = 1
        elif codepoint <= 0x7FF:
            raw_size = 2
        elif codepoint <= 0xFFFF:
            raw_size = 3
        else:
            raw_size = 4
        if codepoint <= 0x1F:
            wire_size = 6
        elif character in {'"', "\\"}:
            wire_size = 2
        else:
            wire_size = raw_size
        if raw_bytes + raw_size > raw_ceiling or wire_bytes + wire_size > wire_ceiling:
            break
        output.append(character)
        raw_bytes += raw_size
        wire_bytes += wire_size
    return "".join(output), wire_bytes, len(output) != len(value)


class _AuxBudget:
    def __init__(self, remaining: int = MAX_AUX_RESPONSE_BYTES) -> None:
        self.remaining = remaining
        self.items_remaining = MAX_AUX_MAPPING_ITEMS
        self.truncated = False

    def admit_item(self) -> bool:
        if self.items_remaining <= 0:
            self.truncated = True
            return False
        self.items_remaining -= 1
        return True

    def text(
        self, value: object, ceiling: int, *, omit_if_truncated: bool = False
    ) -> str | None:
        if not isinstance(value, str):
            raise BackendError("protocol-error")
        clipped, wire_bytes, shortened = _take_aux_text(
            value, ceiling, self.remaining
        )
        self.remaining -= wire_bytes
        self.truncated |= shortened
        if shortened and omit_if_truncated:
            return None
        return clipped


def _bounded_value(value: object, budget: _AuxBudget, depth: int) -> object:
    if not budget.admit_item():
        return _AUX_OMIT
    if isinstance(value, str):
        return budget.text(value, MAX_DOCUMENTATION_BYTES)
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        if abs(value) > MAX_AUX_INTEGER:
            raise BackendError("protocol-error")
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise BackendError("protocol-error")
        return value
    if depth >= MAX_AUX_NESTING:
        budget.truncated = True
        return "[truncated]"
    if isinstance(value, Mapping):
        result = {}
        for index, (key, item) in enumerate(value.items()):
            if index >= MAX_AUX_MAPPING_ITEMS or budget.remaining <= 0:
                budget.truncated = True
                break
            safe_key = budget.text(key, 1024, omit_if_truncated=True)
            if safe_key is None:
                continue
            safe_value = _bounded_value(item, budget, depth + 1)
            if safe_value is _AUX_OMIT:
                break
            result[safe_key] = safe_value
        return result
    if isinstance(value, list):
        result = []
        for item in value[:MAX_AUX_MAPPING_ITEMS]:
            if budget.remaining <= 0:
                budget.truncated = True
                break
            safe_item = _bounded_value(item, budget, depth + 1)
            if safe_item is _AUX_OMIT:
                break
            result.append(safe_item)
        if len(value) > len(result):
            budget.truncated = True
        return result
    raise BackendError("protocol-error")


def _normalize_auxiliary(operation: str | None, content: Mapping[str, object]) -> dict:
    """Validate and cap one shell auxiliary reply before it reaches EJN."""
    budget = _AuxBudget()
    if operation == "kernel_info":
        result = _bounded_value(content, budget, 0)
        if not isinstance(result, dict):
            raise BackendError("protocol-error")
        if budget.truncated:
            result["_ejn_truncated"] = True
        return result
    if operation == "complete":
        matches = content.get("matches")
        if not isinstance(matches, list):
            raise BackendError("protocol-error")
        bounded_matches = []
        for item in matches[:MAX_COMPLETION_MATCHES]:
            if budget.remaining <= 0:
                budget.truncated = True
                break
            if not isinstance(item, str):
                raise BackendError("protocol-error")
            bounded_matches.append(budget.text(item, MAX_COMPLETION_ITEM_BYTES))
        result = {"matches": bounded_matches}
        if len(matches) > len(bounded_matches):
            budget.truncated = True
        for field in ("cursor_start", "cursor_end"):
            value = content.get(field)
            if type(value) is not int or value < 0 or value > MAX_AUX_CURSOR:
                raise BackendError("protocol-error")
            result[field] = value
        if result["cursor_start"] > result["cursor_end"]:
            raise BackendError("protocol-error")
        status = content.get("status", "ok")
        if not isinstance(status, str) or status not in {"ok", "error"}:
            raise BackendError("protocol-error")
        result["status"] = status
        if "metadata" in content:
            if not isinstance(content["metadata"], Mapping):
                raise BackendError("protocol-error")
            result["metadata"] = _bounded_value(content["metadata"], budget, 0)
        if budget.truncated:
            result["_ejn_truncated"] = True
        return result
    if operation == "inspect":
        found = content.get("found")
        if type(found) is not bool:
            raise BackendError("protocol-error")
        result = {"found": found}
        if "data" in content:
            if not isinstance(content["data"], Mapping):
                raise BackendError("protocol-error")
            result["data"] = _bounded_value(content["data"], budget, 0)
        if "metadata" in content:
            if not isinstance(content["metadata"], Mapping):
                raise BackendError("protocol-error")
            result["metadata"] = _bounded_value(content["metadata"], budget, 0)
        if "status" in content:
            status = content["status"]
            if not isinstance(status, str) or status not in {"ok", "error"}:
                raise BackendError("protocol-error")
            result["status"] = status
        if budget.truncated:
            result["_ejn_truncated"] = True
        return result
    if operation == "is_complete":
        status = content.get("status")
        if not isinstance(status, str) or status not in {"complete", "incomplete", "invalid", "unknown"}:
            raise BackendError("protocol-error")
        result = {"status": status}
        if "indent" in content:
            if not isinstance(content["indent"], str):
                raise BackendError("protocol-error")
            result["indent"] = budget.text(content["indent"], 4096)
        if budget.truncated:
            result["_ejn_truncated"] = True
        return result
    raise BackendError("protocol-error")


@dataclass(slots=True)
class _Pending:
    """One helper operation registered before its Jupyter reply can arrive."""

    future: asyncio.Future[dict]
    state: ExecutionState | None = None
    event_callback: object | None = None
    output_attachment: OutputAttachment | None = None
    finishing: bool = False
    idle_content: Mapping[str, object] | None = None
    status_delivered: bool = False
    idle_received: bool = False
    reply_type: str = "kernel_info_reply"
    auxiliary: str | None = None


class _TaskCancellation:
    def __init__(self, backend: JupyterBackend, task: asyncio.Task[None]) -> None:
        self._backend = backend
        self._task = task

    def cancel(self) -> None:
        self._backend._cancel_operation(self._task)
        self._task.cancel()


class JupyterBackend:
    """Attach to an existing local kernel without ever owning its lifetime."""

    def __init__(self, *, deadline: float = 10.0) -> None:
        if (
            isinstance(deadline, bool)
            or not isinstance(deadline, (int, float))
            or not math.isfinite(deadline)
            or deadline <= 0
        ):
            raise ValueError("deadline must be finite and positive")
        self.deadline = float(deadline)
        self.client = None
        self.closed = False
        self._tasks: set[asyncio.Task[None]] = set()
        self._channels_started = False
        self._connecting = False
        self._readers: set[asyncio.Task[None]] = set()
        self._pending: dict[str, _Pending] = {}
        self._pending_by_task: dict[asyncio.Task[None], tuple[str, _Pending]] = {}
        self._retired_tasks: list[asyncio.Task] = []
        self._timed_out_tasks: set[asyncio.Task[None]] = set()
        self._transport_failed = False
        # One coordinator covers every connect/reattach generation.  Its
        # queue, worker, and retained-byte budget must never multiply.
        self._outputs = OutputNormalizer()
        self._output_attachment: OutputAttachment | None = None
        self._heartbeat_interval = min(1.0, max(0.05, self.deadline / 4))
        self._heartbeat_timeout = min(1.0, max(0.05, self.deadline / 2))

    @staticmethod
    def _connection(path_value: object) -> dict:
        if not isinstance(path_value, str):
            raise BackendError("invalid-request")
        path = Path(path_value)
        if not path.is_absolute():
            raise BackendError("invalid-request")
        descriptor = None
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65_536:
                raise BackendError("invalid-request")
            if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
                raise BackendError("invalid-request")
            chunks = []
            remaining = 65_537
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
        except OSError as exc:
            raise BackendError("invalid-request") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if len(raw) > 65_536:
            raise BackendError("invalid-request")
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise BackendError("invalid-request") from exc
        if (
            not isinstance(data, dict)
            or data.get("ip", data.get("host")) not in _LOOPBACK
        ):
            raise BackendError("invalid-request")
        if (
            data.get("transport") != "tcp"
            or not isinstance(data.get("key"), str)
            or not 0 < len(data["key"]) <= 4096
            or not isinstance(data.get("signature_scheme"), str)
            or not 0 < len(data["signature_scheme"]) <= 128
        ):
            raise BackendError("invalid-request")
        for name in _PORTS:
            value = data.get(name)
            if type(value) is not int or not 1 <= value <= 65535:
                raise BackendError("invalid-request")
        return data

    def start(
        self,
        operation,
        params: Mapping[str, object],
        event_callback,
        completion_callback,
    ):
        if self.closed:
            asyncio.get_running_loop().call_soon(
                self._deliver,
                completion_callback,
                BackendCompletion.failure(BackendError("transport-error")),
            )
            return None
        if operation == "connect" and self._connecting:
            asyncio.get_running_loop().call_soon(
                self._deliver,
                completion_callback,
                BackendCompletion.failure(BackendError("busy")),
            )
            return None
        if operation == "connect":
            self._connecting = True
        task = asyncio.get_running_loop().create_task(
            self._run(operation, params, event_callback, completion_callback)
        )
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return _TaskCancellation(self, task)

    @staticmethod
    def _deliver(callback, completion) -> None:
        try:
            callback(completion)
        except Exception:
            pass

    async def _run(self, operation, params, event_callback, completion_callback) -> None:
        completion = None
        retire_provisional = operation == "connect"
        task = asyncio.current_task()
        assert task is not None
        deadline = asyncio.get_running_loop().call_later(
            self.deadline, self._expire_operation, task
        )
        try:
            # One operation deadline cancels this operation task directly.  It
            # avoids a nested wait_for task racing the reader that resolves the
            # request future, and works on the supported Python 3.10 floor.
            if operation == "connect":
                await self._connect(params)
                result = {"attached": True}
            elif operation == "kernel_info":
                result = await self._kernel_info()
            elif operation in {"complete", "inspect", "is_complete"}:
                result = await self._auxiliary(operation, params)
            elif operation == "execute":
                result = await self._execute(params, event_callback)
            else:
                raise BackendError("unsupported")
            completion = BackendCompletion.success(result)
        except asyncio.CancelledError:
            if retire_provisional:
                self._stop_channels()
            if task in self._timed_out_tasks:
                completion = BackendCompletion.failure(BackendError("timeout"))
            else:
                return
        except BackendError as exc:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(exc)
        except asyncio.TimeoutError:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("timeout"))
        except (OSError, ValueError):
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("transport-error"))
        except Exception:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("transport-error"))
        finally:
            deadline.cancel()
            self._timed_out_tasks.discard(task)
            if operation == "connect":
                self._connecting = False
        if completion is not None and not self.closed:
            self._deliver(completion_callback, completion)

    async def _connect(self, params: Mapping[str, object]) -> None:
        connection = self._connection(params.get("connection_file"))
        try:
            from jupyter_client import AsyncKernelClient
        except ImportError as exc:
            raise BackendError("transport-error") from exc
        self._stop_channels()
        artifact_dir = params.get("artifact_dir")
        if not isinstance(artifact_dir, str):
            raise BackendError("invalid-request")
        try:
            self._output_attachment = self._outputs.attach(artifact_dir)
        except Exception as exc:
            raise BackendError("invalid-request") from exc
        client = AsyncKernelClient()
        client.load_connection_info(connection)
        self.client = client
        client.start_channels()
        self._channels_started = True
        self._transport_failed = False
        # The enclosing connect operation owns the only request deadline.  In
        # particular, do not give wait_for_ready a second, equal timeout: that
        # race used to turn a ready kernel into a spurious transport failure.
        await client.wait_for_ready()
        self._start_readers()

    async def _kernel_info(self) -> dict:
        self._ensure_connected()
        assert self.client is not None
        message_id = self.client.kernel_info()
        pending = _Pending(
            asyncio.get_running_loop().create_future(),
            reply_type="kernel_info_reply",
            auxiliary="kernel_info",
        )
        self._register_pending(message_id, pending)
        try:
            return await pending.future
        finally:
            self._unregister_pending(message_id, pending)

    async def _auxiliary(self, operation: str, params: Mapping[str, object]) -> dict:
        self._ensure_connected()
        assert self.client is not None
        code = params.get("code")
        if not isinstance(code, str):
            raise BackendError("invalid-request")
        cursor = params.get("cursor_pos")
        if operation in {"complete", "inspect"} and (
            type(cursor) is not int or cursor < 0 or cursor > len(code) or cursor > MAX_AUX_CURSOR
        ):
            raise BackendError("invalid-request")
        try:
            if operation == "complete":
                message_id = self.client.complete(code, cursor)
                reply_type = "complete_reply"
            elif operation == "inspect":
                detail = params.get("detail_level", 0)
                if type(detail) is not int or detail not in (0, 1):
                    raise BackendError("invalid-request")
                message_id = self.client.inspect(code, cursor, detail)
                reply_type = "inspect_reply"
            else:
                message_id = self.client.is_complete(code)
                reply_type = "is_complete_reply"
        except BackendError:
            raise
        except (AttributeError, TypeError, ValueError) as exc:
            raise BackendError("invalid-request") from exc
        pending = _Pending(
            asyncio.get_running_loop().create_future(),
            reply_type=reply_type,
            auxiliary=operation,
        )
        self._register_pending(message_id, pending)
        try:
            return await pending.future
        finally:
            self._unregister_pending(message_id, pending)

    async def _execute(self, params: Mapping[str, object], event_callback) -> dict:
        self._ensure_connected()
        assert self.client is not None
        code = params.get("code")
        if not isinstance(code, str):
            raise BackendError("invalid-request")
        message_id = self.client.execute(code)
        pending = _Pending(
            asyncio.get_running_loop().create_future(),
            ExecutionState(message_id),
            event_callback,
            self._output_attachment,
        )
        self._register_pending(message_id, pending)
        try:
            return await pending.future
        finally:
            self._unregister_pending(message_id, pending)

    def _ensure_connected(self) -> None:
        if self._transport_failed:
            raise BackendError("transport-error")
        if self.client is None or not self._channels_started:
            raise BackendError("busy")

    def _start_readers(self) -> None:
        if self._readers:
            return
        for channel in _CHANNELS:
            task = asyncio.create_task(self._reader(channel))
            self._readers.add(task)
        monitor = asyncio.create_task(self._liveness_monitor())
        self._readers.add(monitor)

    async def _reader(self, channel: str) -> None:
        client = self.client
        if client is None:
            return
        getter = getattr(client, f"get_{channel}_msg")
        while not self.closed and self._channels_started:
            try:
                message = await getter(timeout=0.2)
            except Empty:
                continue
            except asyncio.CancelledError:
                raise
            except Exception:
                self._fail_transport()
                return
            self._route(channel, message)

    async def _liveness_monitor(self) -> None:
        """Bounded local heartbeat polling; it never owns the remote kernel."""
        while not self.closed and self._channels_started:
            try:
                await asyncio.sleep(self._heartbeat_interval)
                client = self.client
                if client is None:
                    return
                alive = client.is_alive()
                if inspect.isawaitable(alive):
                    alive = await asyncio.wait_for(alive, self._heartbeat_timeout)
                if not alive:
                    self._fail_transport()
                    return
            except asyncio.CancelledError:
                raise
            except Exception:
                self._fail_transport()
                return

    def _route(self, channel: str, message: object) -> None:
        """Route exactly one message from its sole channel reader.

        HT8 intentionally only consumes shell replies and execution terminal
        IOPub state.  Stdin requests are forwarded as the existing
        ``input_request`` event but do not send replies (HT11 owns that).  The
        control reader correlates messages now, while HT10/HT12 add operations
        that consume control replies.  This keeps all channels single-reader
        without inventing future protocol semantics here.
        """
        if not isinstance(message, Mapping):
            self._fail_transport()
            return
        parent = message.get("parent_header", {})
        if not isinstance(parent, Mapping):
            return
        message_id = parent.get("msg_id")
        if not isinstance(message_id, str):
            return
        pending = self._pending.get(message_id)
        if pending is None or pending.future.done():
            return
        if channel == "shell":
            self._route_shell(pending, message)
        elif channel == "iopub":
            self._route_iopub(pending, message)
        elif channel == "stdin":
            self._route_stdin(pending, message)
        # Control messages are correlated by this sole reader and intentionally
        # have no consumer until HT10/HT12 introduce control operations.

    def _route_shell(self, pending: _Pending, message: Mapping[str, object]) -> None:
        if pending.state is None:
            if message.get("msg_type") != pending.reply_type:
                return
            content = message.get("content")
            if not isinstance(content, Mapping):
                pending.future.set_exception(BackendError("protocol-error"))
                return
            try:
                result = _normalize_auxiliary(pending.auxiliary, content)
            except BackendError as exc:
                pending.future.set_exception(exc)
                return
            pending.future.set_result(result)
            return
        if pending.state.accept_shell(message):
            self._deliver_event(
                pending.event_callback, "execute_reply", pending.state.reply
            )
            self._finish_execution(pending)

    def _route_iopub(self, pending: _Pending, message: Mapping[str, object]) -> None:
        state = pending.state
        if state is None or not state.accepts(message):
            return
        message_type = message.get("msg_type")
        content = message.get("content", {})
        if pending.idle_received:
            # Jupyter can emit a stale correlated output after idle.  It is
            # never allowed to overtake the terminal status on this request.
            if message_type in {
                "stream",
                "error",
                "execute_result",
                "display_data",
                "update_display_data",
                "clear_output",
            }:
                _LOGGER.debug("dropping correlated IOPub output received after idle")
            return
        if message_type in {
            "stream",
            "error",
            "execute_result",
            "display_data",
            "update_display_data",
            "clear_output",
        }:
            if pending.output_attachment is not None:
                self._outputs.submit(
                    pending.output_attachment,
                    state.jupyter_id,
                    message,
                    lambda event: self._output_event(pending, event),
                )
        elif message_type == "status" and state.accept_iopub(message):
            # The terminal status must follow every earlier IOPub output for
            # this execution.  Output normalization is deliberately queued so
            # its worker, not the channel reader, delivers the idle event.
            pending.idle_received = True
            pending.idle_content = content if isinstance(content, Mapping) else {}
            if not self._outputs.has_pending(
                pending.output_attachment, state.jupyter_id
            ):
                self._deliver_event(
                    pending.event_callback, "status", pending.idle_content
                )
                pending.status_delivered = True
            self._finish_execution(pending)

    def _route_stdin(self, pending: _Pending, message: Mapping[str, object]) -> None:
        state = pending.state
        if (
            state is not None
            and state.accepts(message)
            and message.get("msg_type") == "input_request"
        ):
            self._deliver_event(
                pending.event_callback, "input_request", message.get("content", {})
            )

    def _finish_execution(self, pending: _Pending) -> None:
        result = pending.state.complete() if pending.state is not None else None
        if result is None or pending.future.done() or pending.finishing:
            return
        pending.finishing = True
        task = asyncio.create_task(self._complete_after_output(pending, result))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _complete_after_output(self, pending: _Pending, result: dict) -> None:
        if pending.state is not None and pending.output_attachment is not None:
            await self._outputs.finish(
                pending.output_attachment, pending.state.jupyter_id
            )
        if not pending.future.done():
            if not pending.status_delivered:
                self._deliver_event(
                    pending.event_callback, "status", pending.idle_content or {}
                )
            pending.future.set_result(result)

    def _output_event(self, pending: _Pending, event: BackendEvent) -> bool:
        if not pending.future.done():
            admitted = self._deliver_event(
                pending.event_callback, event.name, event.data
            )
            if not admitted and pending.state is not None:
                # EventQueue already retained its one truncation marker. Stop
                # normalizing later output for this request and let the
                # current worker roll back an unpublished artifact lease.
                self._outputs.cancel(
                    pending.output_attachment, pending.state.jupyter_id
                )
            return admitted
        return False

    @staticmethod
    def _deliver_event(callback, name: str, data: object) -> bool:
        if not callable(callback):
            return False
        try:
            return callback(BackendEvent(name, data if isinstance(data, Mapping) else {})) is not False
        except Exception:
            # The client callback must not take down a shared channel reader.
            return False

    def _register_pending(self, message_id: str, pending: _Pending) -> None:
        self._pending[message_id] = pending
        task = asyncio.current_task()
        if task is not None:
            self._pending_by_task[task] = (message_id, pending)

    def _unregister_pending(self, message_id: str, pending: _Pending) -> None:
        if self._pending.get(message_id) is pending:
            self._pending.pop(message_id, None)
        task = asyncio.current_task()
        if task is not None and self._pending_by_task.get(task) == (message_id, pending):
            self._pending_by_task.pop(task, None)
        if pending.state is not None:
            failed = pending.future.cancelled()
            if pending.future.done() and not failed:
                try:
                    failed = pending.future.exception() is not None
                except asyncio.CancelledError:
                    failed = True
            if failed:
                self._outputs.cancel(pending.output_attachment, pending.state.jupyter_id)

    def _cancel_operation(self, task: asyncio.Task[None]) -> None:
        record = self._pending_by_task.pop(task, None)
        if record is None:
            return
        message_id, pending = record
        self._remove_pending(message_id, pending)
        if not pending.future.done():
            pending.future.cancel()

    def _expire_operation(self, task: asyncio.Task[None]) -> None:
        if task.done():
            return
        self._timed_out_tasks.add(task)
        self._cancel_operation(task)
        task.cancel()

    def _remove_pending(self, message_id: str, pending: _Pending) -> None:
        if self._pending.get(message_id) is pending:
            self._pending.pop(message_id, None)

    def _fail_transport(self) -> None:
        if self.closed or self._transport_failed:
            return
        self._transport_failed = True
        for pending in tuple(self._pending.values()):
            if not pending.future.done():
                pending.future.set_exception(BackendError("transport-error"))
        # A failed channel means a future request cannot be safely correlated.
        # Release only local channels; neither this path nor close owns kernel
        # lifetime.
        self._stop_channels(cancel_pending=False)

    def _stop_channels(self, *, cancel_pending: bool = True) -> None:
        self._reap_retired_tasks()
        readers = tuple(self._readers)
        for task in readers:
            task.cancel()
        self._retired_tasks.extend(readers)
        self._readers.clear()
        if cancel_pending:
            for pending in tuple(self._pending.values()):
                if not pending.future.done():
                    pending.future.cancel()
            self._pending.clear()
            self._pending_by_task.clear()
        if self.client is not None and self._channels_started:
            try:
                self.client.stop_channels()
            except Exception:
                pass
        self._channels_started = False
        self.client = None
        self._outputs.retire(self._output_attachment)
        self._output_attachment = None

    def _reap_retired_tasks(self) -> None:
        """Drop finished reader references without hiding still-live tasks."""
        live = []
        for task in self._retired_tasks:
            if not task.done():
                live.append(task)
                continue
            try:
                task.result()
            except (asyncio.CancelledError, Exception):
                pass
        self._retired_tasks = live

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        tasks = tuple(self._tasks)
        for task in tasks:
            task.cancel()
        self._retired_tasks.extend(tasks)
        self._stop_channels()
        self._outputs.close()
        self._connecting = False

    async def wait_closed(self) -> None:
        """Await locally-owned cancelled tasks; never touch kernel lifetime."""
        while True:
            self._reap_retired_tasks()
            tasks = tuple(self._retired_tasks) + tuple(self._tasks) + tuple(self._readers)
            self._retired_tasks.clear()
            if not tasks:
                await self._outputs.wait_closed()
                return
            else:
                await asyncio.gather(*tasks, return_exceptions=True)
