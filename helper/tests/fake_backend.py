"""Deterministic callback backend for dispatcher unit tests."""

from __future__ import annotations

import asyncio
import copy
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Mapping

from ejn_helper.backend import (
    BackendCompletion,
    BackendEvent,
    BackendOperation,
    CompletionCallback,
    EventCallback,
)


@dataclass(slots=True)
class FakePlan:
    delay: float = 0.0
    result: Mapping[str, object] = field(default_factory=dict)
    error: BaseException | None = None
    events: tuple[object, ...] = ()
    ignore_cancellation: bool = False
    duplicate_completion: bool = False
    raise_on_start: BaseException | None = None
    synchronous: bool = False


@dataclass(slots=True)
class FakeStart:
    operation: str
    params: dict


class _FakeCancellation:
    def __init__(
        self,
        backend: FakeBackend,
        handle: asyncio.Handle | None,
        ignore: bool,
    ) -> None:
        self.backend = backend
        self.handle = handle
        self.ignore = ignore
        self.cancelled = False

    def cancel(self) -> None:
        if self.cancelled:
            return
        self.cancelled = True
        self.backend.cancel_calls += 1
        if not self.ignore and self.handle is not None:
            self.handle.cancel()


class FakeBackend:
    """Scriptable backend with no Jupyter dependency or external I/O."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self._plans: dict[str, deque[FakePlan]] = defaultdict(deque)
        self.starts: list[FakeStart] = []
        self.cancellations: list[_FakeCancellation] = []
        self.callback_exceptions = 0
        self.cancel_calls = 0
        self.close_calls = 0
        self.closed = False

    def queue_plan(self, operation: str, plan: FakePlan) -> None:
        self._plans[operation].append(plan)

    def start(
        self,
        operation: BackendOperation,
        params: Mapping[str, object],
        event_callback: EventCallback,
        completion_callback: CompletionCallback,
    ) -> _FakeCancellation:
        plan = (
            self._plans[operation].popleft()
            if self._plans[operation]
            else FakePlan()
        )
        self.starts.append(FakeStart(operation, copy.deepcopy(dict(params))))
        if plan.raise_on_start is not None:
            raise plan.raise_on_start

        completion = (
            BackendCompletion.failure(plan.error)
            if plan.error is not None
            else BackendCompletion.success(copy.deepcopy(dict(plan.result)))
        )

        def invoke(callback, argument) -> None:
            try:
                callback(argument)
            except BaseException:
                self.callback_exceptions += 1

        def fire() -> None:
            for item in plan.events:
                invoke(event_callback, item)
            invoke(completion_callback, completion)
            if plan.duplicate_completion:
                invoke(completion_callback, completion)

        if plan.synchronous:
            handle = None
        elif plan.delay:
            handle = self.loop.call_later(plan.delay, fire)
        else:
            handle = self.loop.call_soon(fire)
        cancellation = _FakeCancellation(
            self, handle, plan.ignore_cancellation
        )
        self.cancellations.append(cancellation)
        if plan.synchronous:
            fire()
        return cancellation

    def close(self) -> None:
        self.close_calls += 1
        self.closed = True
        for cancellation in self.cancellations:
            if not cancellation.ignore and cancellation.handle is not None:
                cancellation.handle.cancel()
