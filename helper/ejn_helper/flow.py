"""Pure credited event buffering for the EJN helper transport.

This module performs no I/O.  Queue byte counters are exact complete encoded
frame sizes.  Ordinary and priority storage have independent hard ceilings;
ordinary credit starts at zero and is charged only when a frame is drained.
"""

from __future__ import annotations

import copy
from collections import deque
from dataclasses import dataclass

from .framing import FrameCodecError, encode

EJN_MAX_TO_EMACS_FRAME = 262_144
EJN_MAX_RESPONSE_FRAME = 65_536
EJN_MAX_EVENT_QUEUE = 1_048_576
EJN_MAX_PRIORITY_QUEUE = 524_288
EJN_STREAM_CHUNK_BYTES = 32_768
EJN_MAX_EVENT_CREDIT = (1 << 63) - 1
EJN_MAX_INFLIGHT_REQUESTS = 8
EJN_SEQUENCE_START = 10**15
EJN_SEQUENCE_END = 10**16 - 1

PRIORITY_EVENTS = frozenset(
    {
        "status",
        "execute_reply",
        "input_request",
        "transport_error",
        "output_truncated",
    }
)


class FlowControlError(ValueError):
    """A bounded, structured event-flow failure."""

    def __init__(self, code: str, message: str, *, fatal: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.fatal = fatal


@dataclass(frozen=True, slots=True)
class EnqueueResult:
    """Disposition of one event offered to :class:`EventQueue`."""

    queued: bool
    coalesced: bool = False
    dropped: bool = False
    marker_enqueued: bool = False


@dataclass(frozen=True, slots=True)
class DrainedFrame:
    """One encoded frame released to the runtime's output writer."""

    frame: bytes
    priority: bool
    credit_charge: int


@dataclass(slots=True)
class _Record:
    event: dict
    frame_bytes: int
    priority: bool
    order: int
    last_order: int
    stream_bytes: int = 0
    stream_identity: tuple[object, ...] | None = None


def _check_limit(name: str, value: int, ceiling: int) -> int:
    if type(value) is not int or value <= 0 or value > ceiling:
        raise ValueError(
            f"{name} must be a positive value within its protocol ceiling"
        )
    return value


def _bounded_utf8_size(text: str, ceiling: int) -> int:
    """Return TEXT's UTF-8 size, stopping once CEILING is exceeded."""
    if text.isascii():
        return min(len(text), ceiling + 1)
    total = 0
    for character in text:
        codepoint = ord(character)
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


class EventQueue:
    """A no-I/O credited queue with a reserved priority lane.

    Invariants:

    * ``ordinary_bytes <= ordinary_limit`` and
      ``priority_bytes <= priority_limit`` always.
    * queued byte counts are complete frames produced by ``framing.encode``.
      Retained events contain a fixed-width sequence placeholder, so replacing
      it with the next wire sequence cannot change an encoded frame's size.
    * ordinary frames drain only when their exact size is available as credit.
    * priority frames consume no ordinary credit and remain FIFO among
      themselves.  They bypass an older ordinary frame only when it is credit
      blocked.
    * a request receives at most one ``output_truncated`` marker until the
      execution ledger calls :meth:`reset_request`.

    Event dictionaries are defensively copied.  The runtime writes only the
    immutable frames returned by :meth:`drain`.
    """

    def __init__(
        self,
        *,
        ordinary_limit: int = EJN_MAX_EVENT_QUEUE,
        priority_limit: int = EJN_MAX_PRIORITY_QUEUE,
        ordinary_frame_limit: int = EJN_MAX_TO_EMACS_FRAME,
        priority_frame_limit: int = EJN_MAX_RESPONSE_FRAME,
        stream_chunk_bytes: int = EJN_STREAM_CHUNK_BYTES,
        max_credit: int = EJN_MAX_EVENT_CREDIT,
        max_truncated_requests: int = EJN_MAX_INFLIGHT_REQUESTS,
        sequence_start: int = EJN_SEQUENCE_START,
        sequence_end: int = EJN_SEQUENCE_END,
    ) -> None:
        self.ordinary_limit = _check_limit(
            "ordinary_limit", ordinary_limit, EJN_MAX_EVENT_QUEUE
        )
        self.priority_limit = _check_limit(
            "priority_limit", priority_limit, EJN_MAX_PRIORITY_QUEUE
        )
        self.ordinary_frame_limit = _check_limit(
            "ordinary_frame_limit", ordinary_frame_limit, EJN_MAX_TO_EMACS_FRAME
        )
        self.priority_frame_limit = _check_limit(
            "priority_frame_limit", priority_frame_limit, EJN_MAX_RESPONSE_FRAME
        )
        if self.ordinary_frame_limit < 5 or self.priority_frame_limit < 5:
            raise ValueError("frame limits must hold a prefix and JSON payload")
        self.stream_chunk_bytes = _check_limit(
            "stream_chunk_bytes", stream_chunk_bytes, EJN_STREAM_CHUNK_BYTES
        )
        if (
            type(max_credit) is not int
            or max_credit < 0
            or max_credit > EJN_MAX_EVENT_CREDIT
        ):
            raise ValueError("max_credit must be within the protocol ceiling")
        self.max_credit = max_credit
        if (
            type(max_truncated_requests) is not int
            or max_truncated_requests <= 0
            or max_truncated_requests > EJN_MAX_INFLIGHT_REQUESTS
        ):
            raise ValueError(
                "max_truncated_requests must be within the inflight ceiling"
            )
        self.max_truncated_requests = max_truncated_requests
        if (
            type(sequence_start) is not int
            or type(sequence_end) is not int
            or sequence_start < EJN_SEQUENCE_START
            or sequence_end > EJN_SEQUENCE_END
            or sequence_start > sequence_end
        ):
            raise ValueError("sequence range must use the fixed-width protocol range")
        self.sequence_start = sequence_start
        self.sequence_end = sequence_end

        self._ordinary: deque[_Record] = deque()
        self._priority: deque[_Record] = deque()
        self._ordinary_bytes = 0
        self._priority_bytes = 0
        self._credit = 0
        self._next_order = 0
        self._next_sequence = sequence_start
        self._truncated_requests: set[str] = set()
        self._failure: tuple[str, str] | None = None
        self.max_observed_ordinary_bytes = 0
        self.max_observed_priority_bytes = 0
        self.max_observed_total_bytes = 0
        self.dropped_events = 0

    @property
    def credit(self) -> int:
        return self._credit

    @property
    def ordinary_bytes(self) -> int:
        return self._ordinary_bytes

    @property
    def priority_bytes(self) -> int:
        return self._priority_bytes

    @property
    def buffered_bytes(self) -> int:
        """Return total encoded bytes retained across both bounded lanes."""
        return self._ordinary_bytes + self._priority_bytes

    @property
    def ordinary_count(self) -> int:
        return len(self._ordinary)

    @property
    def priority_count(self) -> int:
        return len(self._priority)

    @property
    def failed(self) -> bool:
        return self._failure is not None

    def _require_live(self) -> None:
        if self._failure is not None:
            code, message = self._failure
            raise FlowControlError(code, message, fatal=True)

    def _fatal(self, code: str, message: str) -> FlowControlError:
        self._failure = (code, message)
        self._ordinary.clear()
        self._priority.clear()
        self._ordinary_bytes = 0
        self._priority_bytes = 0
        self._credit = 0
        self._truncated_requests.clear()
        return FlowControlError(code, message, fatal=True)

    def grant_credit(self, amount: int) -> int:
        """Add ordinary event credit and return the new total.

        Boolean, negative, non-integer, and overflowing grants are rejected.
        """
        self._require_live()
        if type(amount) is not int or amount < 0:
            raise FlowControlError("invalid-request", "invalid event credit grant")
        if amount > self.max_credit - self._credit:
            raise FlowControlError("invalid-request", "event credit grant overflow")
        self._credit += amount
        return self._credit

    def reset_request(self, request_id: str) -> None:
        """Allow a future truncation marker after REQUEST_ID terminates/resets."""
        self._require_live()
        if not isinstance(request_id, str) or not request_id:
            raise FlowControlError("invalid-request", "request id must be non-empty")
        self._truncated_requests.discard(request_id)

    def discard(self) -> None:
        """Release all buffered events and unspent credit without wire output.

        Local transport disposal owns no peer to receive queued events.  This
        operation is deliberately idempotent and remains valid after a fatal
        queue error so shutdown can always release retained payloads.
        """
        self._ordinary.clear()
        self._priority.clear()
        self._ordinary_bytes = 0
        self._priority_bytes = 0
        self._credit = 0
        self._truncated_requests.clear()

    @staticmethod
    def _validate_event(event: dict) -> tuple[str, dict, str | None]:
        if not isinstance(event, dict):
            raise FlowControlError("invalid-event", "event must be an object")
        if "seq" in event:
            raise FlowControlError(
                "invalid-event", "event sequence is assigned by the transport"
            )
        event_name = event.get("event")
        data = event.get("data")
        if not isinstance(event_name, str) or not isinstance(data, dict):
            raise FlowControlError("invalid-event", "event fields are invalid")
        request_id = event.get("request_id")
        if request_id is not None and (
            not isinstance(request_id, str) or not request_id
        ):
            raise FlowControlError("invalid-event", "request id must be non-empty")
        if event_name != "transport_error" and request_id is None:
            raise FlowControlError("invalid-event", "execution event needs request id")
        return event_name, data, request_id

    @staticmethod
    def _with_sequence_placeholder(event: dict) -> dict:
        queued_event = copy.deepcopy(event)
        queued_event["seq"] = EJN_SEQUENCE_START
        return queued_event

    def enqueue(self, event: dict) -> EnqueueResult:
        """Offer one event without blocking or performing output I/O."""
        self._require_live()
        event_name, data, request_id = self._validate_event(event)
        order = self._next_order
        self._next_order += 1
        if event_name in PRIORITY_EVENTS:
            self._enqueue_priority(event, order)
            return EnqueueResult(queued=True)

        # Once pressure has truncated a request, reject its remaining ordinary
        # output before UTF-8 scanning, copying, or encoding it.  The execution
        # ledger explicitly reopens the request with reset_request().
        if request_id in self._truncated_requests:
            self.dropped_events += 1
            return EnqueueResult(queued=False, dropped=True)

        stream_bytes = 0
        stream_identity: tuple[object, ...] | None = None
        if event_name == "stream":
            stream_name = data.get("name")
            text = data.get("text")
            if (
                not isinstance(stream_name, str)
                or not isinstance(text, str)
            ):
                raise FlowControlError("invalid-event", "stream fields are invalid")
            stream_bytes = _bounded_utf8_size(text, self.stream_chunk_bytes)
            if stream_bytes > self.stream_chunk_bytes:
                return self._drop_with_marker(event, order)
            metadata = copy.deepcopy(data)
            metadata.pop("text", None)
            stream_identity = (request_id, stream_name, metadata)
            coalesced = self._try_coalesce_stream(
                event, order, stream_bytes, stream_identity
            )
            if coalesced is not None:
                return coalesced

        queued_event = self._with_sequence_placeholder(event)
        try:
            frame = encode(queued_event, self.ordinary_frame_limit)
        except FrameCodecError as exc:
            if exc.code == "frame-too-large":
                return self._drop_with_marker(event, order)
            raise FlowControlError(exc.code, str(exc)) from None
        size = len(frame)
        if self._ordinary_bytes + size > self.ordinary_limit:
            return self._drop_with_marker(event, order)
        record = _Record(
            event=queued_event,
            frame_bytes=size,
            priority=False,
            order=order,
            last_order=order,
            stream_bytes=stream_bytes,
            stream_identity=stream_identity,
        )
        self._ordinary.append(record)
        self._ordinary_bytes += size
        self.max_observed_ordinary_bytes = max(
            self.max_observed_ordinary_bytes, self._ordinary_bytes
        )
        self._observe_total_bytes()
        return EnqueueResult(queued=True)

    def _observe_total_bytes(self) -> None:
        self.max_observed_total_bytes = max(
            self.max_observed_total_bytes, self.buffered_bytes
        )

    def _try_coalesce_stream(
        self,
        event: dict,
        order: int,
        stream_bytes: int,
        identity: tuple[object, ...],
    ) -> EnqueueResult | None:
        if not self._ordinary:
            return None
        tail = self._ordinary[-1]
        if (
            tail.stream_identity != identity
            or tail.last_order != order - 1
            or tail.stream_bytes + stream_bytes > self.stream_chunk_bytes
        ):
            return None
        combined = copy.deepcopy(tail.event)
        combined["data"]["text"] += event["data"]["text"]
        try:
            combined_frame = encode(combined, self.ordinary_frame_limit)
        except FrameCodecError as exc:
            if exc.code == "frame-too-large":
                return None
            raise FlowControlError(exc.code, str(exc)) from None
        combined_size = len(combined_frame)
        new_total = self._ordinary_bytes - tail.frame_bytes + combined_size
        if new_total > self.ordinary_limit:
            return self._drop_with_marker(event, order)
        self._ordinary_bytes = new_total
        tail.event = combined
        tail.frame_bytes = combined_size
        tail.stream_bytes += stream_bytes
        tail.last_order = order
        self.max_observed_ordinary_bytes = max(
            self.max_observed_ordinary_bytes, self._ordinary_bytes
        )
        self._observe_total_bytes()
        return EnqueueResult(queued=True, coalesced=True)

    def _drop_with_marker(self, event: dict, order: int) -> EnqueueResult:
        _event_name, _data, request_id = self._validate_event(event)
        if not isinstance(request_id, str) or not request_id:
            raise FlowControlError(
                "credit-exhausted", "uncorrelated ordinary event cannot be queued"
            )
        self.dropped_events += 1
        marker_enqueued = False
        if request_id not in self._truncated_requests:
            if len(self._truncated_requests) >= self.max_truncated_requests:
                raise self._fatal(
                    "credit-exhausted", "truncated request ledger exhausted"
                )
            marker = {
                "v": event.get("v", 1),
                "kind": "event",
                "event": "output_truncated",
                "request_id": request_id,
                "data": {},
            }
            self._enqueue_priority(marker, order)
            self._truncated_requests.add(request_id)
            marker_enqueued = True
        return EnqueueResult(
            queued=False,
            dropped=True,
            marker_enqueued=marker_enqueued,
        )

    def _enqueue_priority(self, event: dict, order: int) -> None:
        queued_event = self._with_sequence_placeholder(event)
        try:
            frame = encode(queued_event, self.priority_frame_limit)
        except FrameCodecError as exc:
            raise self._fatal(
                exc.code, "priority event exceeds its frame limit"
            ) from None
        size = len(frame)
        if self._priority_bytes + size > self.priority_limit:
            raise self._fatal("credit-exhausted", "priority event queue exhausted")
        self._priority.append(
            _Record(
                event=queued_event,
                frame_bytes=size,
                priority=True,
                order=order,
                last_order=order,
            )
        )
        self._priority_bytes += size
        self.max_observed_priority_bytes = max(
            self.max_observed_priority_bytes, self._priority_bytes
        )
        self._observe_total_bytes()

    def drain(self, max_events: int | None = None) -> list[DrainedFrame]:
        """Return frames currently deliverable under priority and credit rules."""
        self._require_live()
        if max_events is not None and (
            type(max_events) is not int or max_events < 0
        ):
            raise ValueError("max_events must be a non-negative integer or None")
        drained: list[DrainedFrame] = []
        while max_events is None or len(drained) < max_events:
            ordinary = self._ordinary[0] if self._ordinary else None
            priority = self._priority[0] if self._priority else None
            ordinary_ready = (
                ordinary is not None and self._credit >= ordinary.frame_bytes
            )
            if priority is not None and (
                ordinary is None
                or priority.order < ordinary.order
                or not ordinary_ready
            ):
                record = priority
                charge = 0
            elif ordinary_ready:
                record = ordinary
                charge = record.frame_bytes
            else:
                break
            if self._next_sequence > self.sequence_end:
                raise self._fatal(
                    "protocol-error", "event sequence range exhausted"
                )
            wire_event = copy.deepcopy(record.event)
            wire_event["seq"] = self._next_sequence
            try:
                frame = encode(
                    wire_event,
                    self.priority_frame_limit
                    if record.priority
                    else self.ordinary_frame_limit,
                )
            except FrameCodecError as exc:
                raise self._fatal(exc.code, "queued event cannot be encoded") from None
            if len(frame) != record.frame_bytes:
                raise self._fatal("protocol-error", "queued frame accounting changed")
            self._next_sequence += 1
            if record.priority:
                self._priority.popleft()
                self._priority_bytes -= record.frame_bytes
            else:
                self._ordinary.popleft()
                self._ordinary_bytes -= record.frame_bytes
                self._credit -= record.frame_bytes
            drained.append(
                DrainedFrame(
                    frame=frame,
                    priority=record.priority,
                    credit_charge=charge,
                )
            )
        return drained
