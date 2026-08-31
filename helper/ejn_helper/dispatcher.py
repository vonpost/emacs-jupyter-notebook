"""Validated, bounded request dispatch for the EJN helper protocol."""

from __future__ import annotations

import asyncio
import copy
import math
import os
from dataclasses import dataclass
from typing import Callable, Mapping, cast

from . import __version__
from .backend import (
    Backend,
    BackendCompletion,
    BackendError,
    BackendEvent,
    BackendOperation,
    Cancellation,
)
from .flow import (
    EJN_MAX_INFLIGHT_REQUESTS,
    EJN_MAX_RESPONSE_FRAME,
    EventQueue,
    FlowControlError,
)
from .framing import FrameCodecError, encode

EJN_PROTOCOL_VERSION = 1
EJN_MAX_CODE_BYTES = 524_288
EJN_MAX_REQUEST_ID_BYTES = 256
EJN_MAX_PATH_BYTES = 4_096

_BACKEND_OPERATIONS = frozenset(
    {
        "connect",
        "kernel_info",
        "execute",
        "complete",
        "inspect",
        "is_complete",
        "input_reply",
        "interrupt",
        "restart",
        "shutdown",
    }
)
_LOCAL_OPERATIONS = frozenset({"hello", "ping", "grant_event_credit", "close"})
_ALLOWED_OPERATIONS = _BACKEND_OPERATIONS | _LOCAL_OPERATIONS
_PRODUCER_EVENTS = frozenset(
    {
        "stream",
        "display_data",
        "execute_result",
        "clear_output",
        "status",
        "execute_reply",
        "input_request",
        "transport_error",
    }
)
_SAFE_ERROR_MESSAGES = {
    "invalid-request": "invalid request",
    "invalid-event": "invalid backend event",
    "unsupported": "operation is unsupported",
    "timeout": "backend request timed out",
    "protocol-error": "backend protocol failure",
    "frame-too-large": "response exceeds the frame limit",
    "credit-exhausted": "event capacity exhausted",
    "transport-error": "backend request failed",
    "busy": "request cannot run in the current state",
}
_CAPABILITIES = (
    "event-credit",
    "request-deadlines",
    "artifact-spooling",
    "local-close",
)

ResponseCallback = Callable[[dict], None]


class _RequestError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(slots=True)
class _Inflight:
    request_id: str
    operation: BackendOperation
    timer: asyncio.TimerHandle
    cancellation: Cancellation | None = None
    cancel_requested: bool = False
    terminal: bool = False


def _bounded_utf8_size(value: str, ceiling: int) -> int:
    if value.isascii():
        return min(len(value), ceiling + 1)
    total = 0
    for character in value:
        codepoint = ord(character)
        if 0xD800 <= codepoint <= 0xDFFF:
            return ceiling + 1
        if codepoint <= 0x7F:
            total += 1
        elif codepoint <= 0x7FF:
            total += 2
        elif codepoint <= 0xFFFF:
            total += 3
        else:
            total += 4
        if total > ceiling:
            return total
    return total


def _has_surrogate(value: str) -> bool:
    return any(0xD800 <= ord(character) <= 0xDFFF for character in value)


def _exact_fields(
    params: dict,
    required: frozenset[str],
    optional: frozenset[str] = frozenset(),
) -> None:
    keys = set(params)
    if not required.issubset(keys) or not keys.issubset(required | optional):
        raise _RequestError("invalid-request", "invalid operation parameters")


class Dispatcher:
    """Translate validated EJN requests into one bounded backend operation.

    The dispatcher owns request deadlines and terminal response arbitration.
    Backend callbacks never carry ``seq`` or ``request_id``; correlation is
    attached here immediately before the event enters :class:`EventQueue`.
    """

    def __init__(
        self,
        backend: Backend,
        response_callback: ResponseCallback,
        *,
        event_queue: EventQueue | None = None,
        loop: asyncio.AbstractEventLoop | None = None,
        request_timeout: float = 30.0,
        operation_timeouts: Mapping[str, float] | None = None,
        max_inflight: int = EJN_MAX_INFLIGHT_REQUESTS,
    ) -> None:
        if (
            isinstance(request_timeout, bool)
            or not isinstance(request_timeout, (int, float))
            or request_timeout <= 0
            or not math.isfinite(request_timeout)
        ):
            raise ValueError("request_timeout must be positive")
        if (
            type(max_inflight) is not int
            or max_inflight <= 0
            or max_inflight > EJN_MAX_INFLIGHT_REQUESTS
        ):
            raise ValueError("max_inflight must be within the protocol ceiling")
        timeouts: dict[str, float] = {}
        for operation, timeout in (operation_timeouts or {}).items():
            if operation not in _BACKEND_OPERATIONS:
                raise ValueError("operation timeout names an unsupported operation")
            if (
                isinstance(timeout, bool)
                or not isinstance(timeout, (int, float))
                or timeout <= 0
                or not math.isfinite(timeout)
            ):
                raise ValueError("operation timeouts must be positive")
            timeouts[operation] = float(timeout)

        self.backend = backend
        self.response_callback = response_callback
        self.event_queue = event_queue if event_queue is not None else EventQueue()
        self.loop = loop
        self.request_timeout = float(request_timeout)
        self.operation_timeouts = timeouts
        self.max_inflight = max_inflight
        self._inflight: dict[str, _Inflight] = {}
        self.negotiated = False
        self.connected = False
        self.closed = False
        self.callback_failures = 0
        self.late_completions = 0
        self.late_events = 0

    @property
    def inflight_count(self) -> int:
        return len(self._inflight)

    def dispatch(self, envelope: object) -> None:
        """Validate and start one request, emitting exactly one response."""
        request_id = self._response_id(envelope)
        try:
            operation, params = self._validate_request(envelope)
        except _RequestError as exc:
            self._send_error(request_id, exc.code, exc.message)
            return

        if operation not in _ALLOWED_OPERATIONS:
            self._send_error(request_id, "unsupported", "operation is unsupported")
            return
        try:
            validated = self._validate_params(operation, params)
        except _RequestError as exc:
            self._send_error(request_id, exc.code, exc.message)
            return

        if self.closed:
            self._send_error(
                request_id, "transport-error", "dispatcher is already closed"
            )
            return
        if request_id in self._inflight:
            self._send_error(request_id, "busy", "request id is already in flight")
            return
        if operation != "hello" and not self.negotiated:
            self._send_error(request_id, "busy", "hello is required first")
            return
        if operation == "hello":
            self._dispatch_hello(request_id, validated)
        elif operation == "ping":
            self._send_success(request_id, {"alive": True})
        elif operation == "grant_event_credit":
            self._dispatch_credit(request_id, validated)
        elif operation == "close":
            self._dispatch_close(request_id)
        else:
            self._dispatch_backend(request_id, operation, validated)

    @staticmethod
    def _response_id(envelope: object) -> str:
        if isinstance(envelope, dict) and isinstance(envelope.get("id"), str):
            request_id = envelope["id"]
            if _bounded_utf8_size(request_id, EJN_MAX_REQUEST_ID_BYTES) <= (
                EJN_MAX_REQUEST_ID_BYTES
            ):
                return request_id
        return ""

    @staticmethod
    def _validate_request(envelope: object) -> tuple[str, dict]:
        if not isinstance(envelope, dict):
            raise _RequestError("invalid-request", "request must be an object")
        version = envelope.get("v")
        if type(version) is not int:
            raise _RequestError("invalid-request", "request version must be integer")
        if version != EJN_PROTOCOL_VERSION:
            raise _RequestError("unsupported", "protocol version is unsupported")
        kind = envelope.get("kind")
        if not isinstance(kind, str):
            raise _RequestError("invalid-request", "request kind must be string")
        if kind != "request":
            raise _RequestError("unsupported", "envelope kind is unsupported")
        request_id = envelope.get("id")
        if not isinstance(request_id, str) or not request_id:
            raise _RequestError("invalid-request", "request id must be non-empty")
        if _bounded_utf8_size(request_id, EJN_MAX_REQUEST_ID_BYTES) > (
            EJN_MAX_REQUEST_ID_BYTES
        ):
            raise _RequestError("invalid-request", "request id is too large")
        operation = envelope.get("op")
        params = envelope.get("params")
        if not isinstance(operation, str) or not isinstance(params, dict):
            raise _RequestError("invalid-request", "request fields are invalid")
        return operation, params

    @staticmethod
    def _validate_params(operation: str, params: dict) -> dict:
        if operation == "hello":
            _exact_fields(params, frozenset({"versions"}))
            versions = params["versions"]
            if (
                not isinstance(versions, list)
                or not versions
                or any(type(version) is not int for version in versions)
            ):
                raise _RequestError("invalid-request", "versions must be integers")
            return {"versions": list(versions)}
        if operation == "grant_event_credit":
            _exact_fields(params, frozenset({"bytes"}))
            amount = params["bytes"]
            if type(amount) is not int or amount < 0:
                raise _RequestError("invalid-request", "credit must be non-negative")
            return {"bytes": amount}
        if operation == "connect":
            _exact_fields(
                params, frozenset({"connection_file", "artifact_dir"})
            )
            result = {}
            for field in ("connection_file", "artifact_dir"):
                value = params[field]
                if (
                    not isinstance(value, str)
                    or not os.path.isabs(value)
                    or _bounded_utf8_size(value, EJN_MAX_PATH_BYTES)
                    > EJN_MAX_PATH_BYTES
                ):
                    raise _RequestError(
                        "invalid-request", "connect paths must be bounded and absolute"
                    )
                result[field] = value
            return result
        if operation in {
            "ping",
            "kernel_info",
            "interrupt",
            "restart",
            "shutdown",
            "close",
        }:
            _exact_fields(params, frozenset())
            return {}
        if operation in {"execute", "is_complete"}:
            _exact_fields(params, frozenset({"code"}))
            return {"code": Dispatcher._validate_code(params["code"])}
        if operation in {"complete", "inspect"}:
            optional = (
                frozenset({"detail_level"})
                if operation == "inspect"
                else frozenset()
            )
            _exact_fields(params, frozenset({"code", "cursor_pos"}), optional)
            code = Dispatcher._validate_code(params["code"])
            cursor = params["cursor_pos"]
            if type(cursor) is not int or cursor < 0 or cursor > len(code):
                raise _RequestError("invalid-request", "cursor position is invalid")
            result = {"code": code, "cursor_pos": cursor}
            if "detail_level" in params:
                detail = params["detail_level"]
                if type(detail) is not int or detail not in (0, 1):
                    raise _RequestError("invalid-request", "detail level is invalid")
                result["detail_level"] = detail
            return result
        if operation == "input_reply":
            _exact_fields(params, frozenset({"request_id", "value"}))
            correlated = params["request_id"]
            value = params["value"]
            if (
                not isinstance(correlated, str)
                or not correlated
                or _bounded_utf8_size(correlated, EJN_MAX_REQUEST_ID_BYTES)
                > EJN_MAX_REQUEST_ID_BYTES
                or not isinstance(value, str)
                or _has_surrogate(value)
            ):
                raise _RequestError("invalid-request", "input reply fields are invalid")
            return {"request_id": correlated, "value": value}
        return dict(params)

    @staticmethod
    def _validate_code(value: object) -> str:
        if not isinstance(value, str):
            raise _RequestError("invalid-request", "code must be a string")
        if _bounded_utf8_size(value, EJN_MAX_CODE_BYTES) > EJN_MAX_CODE_BYTES:
            raise _RequestError("invalid-request", "code exceeds the byte limit")
        return value

    def _dispatch_hello(self, request_id: str, params: dict) -> None:
        if self.negotiated:
            self._send_error(request_id, "busy", "hello is already complete")
            return
        if EJN_PROTOCOL_VERSION not in params["versions"]:
            self._send_error(
                request_id, "unsupported", "no supported protocol version"
            )
            return
        self.negotiated = True
        self._send_success(
            request_id,
            {
                "version": EJN_PROTOCOL_VERSION,
                "helper_version": __version__,
                "capabilities": list(_CAPABILITIES),
            },
        )

    def _dispatch_credit(self, request_id: str, params: dict) -> None:
        try:
            credit = self.event_queue.grant_credit(params["bytes"])
        except FlowControlError as exc:
            self._send_error(request_id, exc.code, _safe_message(exc.code))
            return
        self._send_success(request_id, {"credit": credit})

    def _dispatch_backend(
        self, request_id: str, operation: str, params: dict
    ) -> None:
        if operation != "connect" and not self.connected:
            self._send_error(request_id, "busy", "connect is required first")
            return
        if operation == "connect" and (
            self.connected
            or any(item.operation == "connect" for item in self._inflight.values())
        ):
            self._send_error(request_id, "busy", "backend is already connected")
            return
        if len(self._inflight) >= self.max_inflight:
            self._send_error(request_id, "busy", "too many requests are in flight")
            return

        loop = self.loop
        if loop is None:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                self._send_error(
                    request_id, "transport-error", "dispatcher loop is unavailable"
                )
                return
        timeout = self.operation_timeouts.get(operation, self.request_timeout)
        try:
            timer = loop.call_later(timeout, self._deadline, request_id)
        except BaseException:
            self._send_error(
                request_id, "transport-error", "dispatcher loop is unavailable"
            )
            return
        typed_operation = cast(BackendOperation, operation)
        record = _Inflight(request_id, typed_operation, timer)
        self._inflight[request_id] = record

        try:
            cancellation = self.backend.start(
                typed_operation,
                params,
                lambda item: self._backend_event(request_id, record, item),
                lambda item: self._backend_complete(request_id, record, item),
            )
        except BaseException:
            self._finish_error(request_id, record, "transport-error")
            return
        if self._inflight.get(request_id) is record and not record.terminal:
            record.cancellation = cancellation
        elif record.cancel_requested and cancellation is not None:
            try:
                cancellation.cancel()
            except BaseException:
                pass

    def _backend_event(
        self, request_id: str, record: _Inflight, item: object
    ) -> bool:
        if self._inflight.get(request_id) is not record or record.terminal:
            self.late_events += 1
            return False
        try:
            if (
                not isinstance(item, BackendEvent)
                or item.name not in _PRODUCER_EVENTS
                or not isinstance(item.data, Mapping)
            ):
                raise ValueError
            event = {
                "v": EJN_PROTOCOL_VERSION,
                "kind": "event",
                "event": item.name,
                "request_id": request_id,
                "data": copy.deepcopy(dict(item.data)),
            }
            disposition = self.event_queue.enqueue(event)
            # An ordinary event dropped under queue pressure has not crossed
            # the helper/Emacs ownership boundary.  Artifact producers use
            # this result to discard their private publication lease while the
            # queue still guarantees the request's truncation marker.
            return disposition.queued
        except FlowControlError as exc:
            self._finish_error(request_id, record, exc.code, cancel=True)
        except BaseException:
            self._finish_error(
                request_id, record, "protocol-error", cancel=True
            )
        return False

    def _backend_complete(
        self, request_id: str, record: _Inflight, item: object
    ) -> None:
        if self._inflight.get(request_id) is not record or record.terminal:
            self.late_completions += 1
            return
        try:
            if not isinstance(item, BackendCompletion):
                raise ValueError
            if item.error is not None:
                code = (
                    item.error.code
                    if isinstance(item.error, BackendError)
                    and item.error.code in _SAFE_ERROR_MESSAGES
                    else "transport-error"
                )
                self._finish_error(request_id, record, code)
                return
            if item.result is None or not isinstance(item.result, Mapping):
                raise ValueError
            result = copy.deepcopy(dict(item.result))
        except BaseException:
            self._finish_error(request_id, record, "protocol-error")
            return
        self._finish(request_id, record, True, result)

    def _deadline(self, request_id: str) -> None:
        record = self._inflight.get(request_id)
        if record is None or record.terminal:
            return
        self._finish_error(request_id, record, "timeout", cancel=True)

    def _finish_error(
        self,
        request_id: str,
        record: _Inflight,
        code: str,
        *,
        cancel: bool = False,
    ) -> None:
        self._finish(
            request_id,
            record,
            False,
            {"code": code, "message": _safe_message(code)},
            cancel=cancel,
        )

    def _finish(
        self,
        request_id: str,
        record: _Inflight,
        success: bool,
        payload: dict,
        *,
        cancel: bool = False,
    ) -> None:
        if self._inflight.get(request_id) is not record or record.terminal:
            return
        record.terminal = True
        record.timer.cancel()
        if cancel:
            record.cancel_requested = True
            if record.cancellation is not None:
                try:
                    record.cancellation.cancel()
                except BaseException:
                    pass
        if success:
            candidate = {
                "v": EJN_PROTOCOL_VERSION,
                "kind": "response",
                "id": request_id,
                "ok": True,
                "result": payload,
            }
            try:
                encode(candidate, EJN_MAX_RESPONSE_FRAME)
            except FrameCodecError as exc:
                success = False
                payload = {
                    "code": exc.code,
                    "message": _safe_message(exc.code),
                }
        if success and record.operation == "connect":
            self.connected = True
        if success and record.operation == "shutdown":
            self.connected = False
        try:
            if success:
                self._send_success(request_id, payload)
            else:
                self._send_response(
                    {
                        "v": EJN_PROTOCOL_VERSION,
                        "kind": "response",
                        "id": request_id,
                        "ok": False,
                        "error": payload,
                    }
                )
        finally:
            try:
                self.event_queue.reset_request(request_id)
            except FlowControlError:
                pass
            self._inflight.pop(request_id, None)

    def _dispatch_close(self, request_id: str) -> None:
        # Close the admission gate before cancellation responses can invoke a
        # reentrant response callback and submit work not present in this tuple.
        self.closed = True
        self.connected = False
        for inflight_id, record in tuple(self._inflight.items()):
            self._finish_error(
                inflight_id, record, "transport-error", cancel=True
            )
        try:
            self.backend.close()
        except BaseException:
            self._send_error(request_id, "transport-error", "backend close failed")
            return
        self._send_success(request_id, {"closed": True})

    def _send_success(self, request_id: str, result: dict) -> None:
        self._send_response(
            {
                "v": EJN_PROTOCOL_VERSION,
                "kind": "response",
                "id": request_id,
                "ok": True,
                "result": result,
            }
        )

    def _send_error(self, request_id: str, code: str, message: str) -> None:
        self._send_response(
            {
                "v": EJN_PROTOCOL_VERSION,
                "kind": "response",
                "id": request_id,
                "ok": False,
                "error": {"code": code, "message": message},
            }
        )

    def _send_response(self, response: dict) -> None:
        try:
            encode(response, EJN_MAX_RESPONSE_FRAME)
        except FrameCodecError:
            request_id = response.get("id", "")
            if (
                not isinstance(request_id, str)
                or _bounded_utf8_size(request_id, EJN_MAX_REQUEST_ID_BYTES)
                > EJN_MAX_REQUEST_ID_BYTES
            ):
                request_id = ""
            response = {
                "v": EJN_PROTOCOL_VERSION,
                "kind": "response",
                "id": request_id,
                "ok": False,
                "error": {
                    "code": "frame-too-large",
                    "message": _safe_message("frame-too-large"),
                },
            }
            encode(response, EJN_MAX_RESPONSE_FRAME)
        try:
            self.response_callback(response)
        except BaseException:
            self.callback_failures += 1


def _safe_message(code: str) -> str:
    return _SAFE_ERROR_MESSAGES.get(code, _SAFE_ERROR_MESSAGES["transport-error"])
