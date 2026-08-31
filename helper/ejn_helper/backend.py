"""Typed, Jupyter-independent backend boundary for the helper dispatcher."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Literal, Mapping, Protocol, TypeAlias

BackendOperation: TypeAlias = Literal[
    "connect",
    "kernel_info",
    "execute",
    "complete",
    "inspect",
    "is_complete",
    "input_reply",
    "interrupt",
    "shutdown",
]


class BackendError(Exception):
    """A classified backend failure whose free-form text is never transported."""

    def __init__(self, code: str = "transport-error") -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True, slots=True)
class BackendEvent:
    """An unsequenced event produced while handling one EJN request."""

    name: str
    data: Mapping[str, object]


@dataclass(frozen=True, slots=True)
class BackendCompletion:
    """Exactly one logical backend completion, before dispatcher deduplication."""

    result: Mapping[str, object] | None = None
    error: BaseException | None = None

    @classmethod
    def success(cls, result: Mapping[str, object] | None = None) -> BackendCompletion:
        return cls(result={} if result is None else result)

    @classmethod
    def failure(cls, error: BaseException) -> BackendCompletion:
        return cls(error=error)


# ``False`` means the dispatcher did not admit the event.  Producers that do
# not own an unpublished resource may ignore the return value.
EventCallback: TypeAlias = Callable[[BackendEvent], bool]
CompletionCallback: TypeAlias = Callable[[BackendCompletion], None]


class Cancellation(Protocol):
    """One local backend operation that can be asked to stop."""

    def cancel(self) -> None:
        """Request local cancellation without making kernel-lifetime promises."""


class Backend(Protocol):
    """Narrow asynchronous interface implemented by the Jupyter adapter."""

    def start(
        self,
        operation: BackendOperation,
        params: Mapping[str, object],
        event_callback: EventCallback,
        completion_callback: CompletionCallback,
    ) -> Cancellation | None:
        """Start one operation and return its local cancellation handle.

        This method must return without blocking.  All correlated events must
        be delivered before completion; callbacks after completion are late
        and the dispatcher deliberately rejects them.  An event callback
        returns whether the local transport admitted the event.
        """

    def close(self) -> None:
        """Return without blocking after releasing only local resources.

        Closing the backend must never terminate the remote kernel.
        """
