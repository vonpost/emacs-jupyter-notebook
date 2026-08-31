"""Async binary runtime for the local EJN helper protocol.

This module owns stdin/stdout and task lifetime.  The dispatcher remains the
only request validator and the EventQueue remains the only event credit store.
"""

from __future__ import annotations

import asyncio
import contextlib
import math
import signal
from collections import deque
from typing import BinaryIO, Callable, NoReturn, Protocol

from .backend import Backend
from .dispatcher import Dispatcher
from .flow import EJN_MAX_PRIORITY_QUEUE, EJN_MAX_RESPONSE_FRAME
from .framing import Decoder, FrameCodecError, encode
from .jupyter_backend import JupyterBackend

EJN_MAX_RAW_ACCUMULATOR = 1_048_576
EJN_PARTIAL_FRAME_TIMEOUT = 5.0
EJN_RUNTIME_ERROR_BYTES = 4_096
EJN_LOCAL_CLOSE_TIMEOUT = 1.0


class AsyncWriter(Protocol):
    def write(self, data: bytes) -> None: ...

    async def drain(self) -> None: ...

    def close(self) -> None: ...


class RuntimeErrorCode(RuntimeError):
    """One bounded runtime failure that is safe to report on stderr."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class ProtocolRuntime:
    """Injectable binary protocol supervisor with one output owner."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: AsyncWriter,
        *,
        backend: Backend | None = None,
        dispatcher_factory: Callable[[Backend, Callable[[dict], None]], Dispatcher]
        | None = None,
        stderr: BinaryIO | None = None,
        partial_timeout: float = EJN_PARTIAL_FRAME_TIMEOUT,
        response_limit: int = EJN_MAX_PRIORITY_QUEUE,
        read_size: int = 65_536,
    ) -> None:
        if (
            isinstance(partial_timeout, bool)
            or not isinstance(partial_timeout, (int, float))
            or partial_timeout <= 0
            or not math.isfinite(partial_timeout)
        ):
            raise ValueError("partial_timeout must be positive")
        if type(response_limit) is not int or response_limit < EJN_MAX_RESPONSE_FRAME:
            raise ValueError("response_limit is too small")
        if response_limit > EJN_MAX_PRIORITY_QUEUE:
            raise ValueError("response_limit exceeds the protocol ceiling")
        if type(read_size) is not int or not 1 <= read_size <= EJN_MAX_RAW_ACCUMULATOR:
            raise ValueError("read_size is invalid")
        self.reader = reader
        self.writer = writer
        self.stderr = stderr
        self.partial_timeout = float(partial_timeout)
        self.read_size = read_size
        self.decoder = Decoder(EJN_MAX_RAW_ACCUMULATOR, EJN_MAX_RAW_ACCUMULATOR)
        self.backend = backend if backend is not None else JupyterBackend()
        self._responses: deque[bytes] = deque()
        self._response_bytes = 0
        self._inflight_response_bytes = 0
        self.max_observed_response_bytes = 0
        self._response_limit = response_limit
        self._wake_writer = asyncio.Event()
        self._stop = asyncio.Event()
        self._failed: RuntimeErrorCode | None = None
        self._closed = False
        self._partial_deadline: float | None = None
        self._writer_task: asyncio.Task[None] | None = None
        factory = dispatcher_factory or self._default_dispatcher
        self.dispatcher = factory(self.backend, self._enqueue_response)

    @staticmethod
    def _default_dispatcher(
        backend: Backend, response_callback: Callable[[dict], None]
    ) -> Dispatcher:
        return Dispatcher(backend, response_callback)

    @property
    def response_bytes(self) -> int:
        return self._response_bytes

    def request_stop(self) -> None:
        """Request local-only shutdown, suitable for SIGTERM injection."""
        self._stop.set()
        self._wake_writer.set()

    def _enqueue_response(self, response: dict) -> None:
        # A response produced after transport failure or local disposal has no
        # valid peer ownership boundary.  Drop it before serializing it.
        if self._stop.is_set() or self._closed:
            return
        try:
            frame = encode(response, EJN_MAX_RESPONSE_FRAME)
        except FrameCodecError:
            self._fail("protocol-error")
            return
        if self._response_bytes + len(frame) > self._response_limit:
            self._fail("credit-exhausted")
            return
        self._responses.append(frame)
        self._response_bytes += len(frame)
        self.max_observed_response_bytes = max(
            self.max_observed_response_bytes, self._response_bytes
        )
        self._wake_writer.set()

    def _fail(self, code: str) -> None:
        if self._failed is None:
            self._failed = RuntimeErrorCode(code)
            # A failed transport cannot make a reliable promise about queued
            # replies.  Keep at most the one frame already owned by drain(),
            # and release every retained response byte immediately.
            self._response_bytes -= sum(map(len, self._responses))
            self._responses.clear()
        self._stop.set()
        self._wake_writer.set()

    def _expire_partial_frame(
        self, cause: BaseException | None = None
    ) -> NoReturn:
        """Convert the decoder's destructive expiry into a runtime code."""
        try:
            self.decoder.partial_frame_expired()
        except FrameCodecError as exc:
            raise RuntimeErrorCode(exc.code) from (cause or exc)
        raise RuntimeErrorCode("protocol-error") from cause

    async def run(self) -> int:
        self._writer_task = asyncio.create_task(self._write_loop())
        reader_task = asyncio.create_task(self._read_loop())
        stop_task = asyncio.create_task(self._stop.wait())
        try:
            done, _pending = await asyncio.wait(
                {reader_task, stop_task, self._writer_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            if self._writer_task in done and not self._stop.is_set():
                try:
                    await self._writer_task
                except asyncio.CancelledError as exc:
                    # Cancellation of the child writer is a transport fault,
                    # not cancellation of this supervisor task.
                    raise RuntimeErrorCode("transport-error") from exc
                raise RuntimeErrorCode("transport-error")
            if stop_task in done and not reader_task.done():
                reader_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await reader_task
            else:
                await reader_task
        except RuntimeErrorCode as exc:
            self._fail(exc.code)
        except asyncio.CancelledError:
            self._fail("transport-error")
            raise
        except BaseException:
            self._fail("transport-error")
        finally:
            self.request_stop()
            if not reader_task.done():
                reader_task.cancel()
            with contextlib.suppress(BaseException):
                await reader_task
            stop_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await stop_task
            await self._close_local()
            if self._writer_task is not None:
                try:
                    await asyncio.wait_for(self._writer_task, EJN_LOCAL_CLOSE_TIMEOUT)
                except asyncio.TimeoutError:
                    self._fail("transport-error")
                    self._writer_task.cancel()
                    with contextlib.suppress(BaseException):
                        await self._writer_task
                except BaseException:
                    self._fail("transport-error")
            try:
                self.writer.close()
            except BaseException:
                self._fail("transport-error")
            wait_closed = getattr(self.writer, "wait_closed", None)
            if callable(wait_closed):
                try:
                    await asyncio.wait_for(wait_closed(), EJN_LOCAL_CLOSE_TIMEOUT)
                except BaseException:
                    self._fail("transport-error")
            self._write_stderr(self._failed.code if self._failed is not None else "")
        return 2 if self._failed is not None else 0

    async def _read_loop(self) -> None:
        while not self._stop.is_set():
            try:
                if self.decoder.partial_frame:
                    if self._partial_deadline is None:
                        self._partial_deadline = (
                            asyncio.get_running_loop().time() + self.partial_timeout
                        )
                    remaining = self._partial_deadline - asyncio.get_running_loop().time()
                    if remaining <= 0:
                        self._expire_partial_frame()
                    chunk = await asyncio.wait_for(
                        self.reader.read(self.read_size), remaining
                    )
                else:
                    chunk = await self.reader.read(self.read_size)
            except asyncio.TimeoutError as exc:
                self._expire_partial_frame(exc)
            if not chunk:
                if self.decoder.partial_frame:
                    try:
                        self.decoder.partial_frame_expired()
                    except FrameCodecError as exc:
                        raise RuntimeErrorCode(exc.code) from exc
                    raise RuntimeErrorCode("protocol-error")
                return
            try:
                frames = self.decoder.feed(chunk)
            except FrameCodecError as exc:
                raise RuntimeErrorCode(exc.code) from exc
            for frame in frames:
                self.dispatcher.dispatch(frame)
                self._wake_writer.set()
                if self._stop.is_set():
                    # A fatal response/queue condition closes admission for
                    # every later frame decoded from the same read chunk.
                    return
                if self.dispatcher.closed:
                    # The protocol close acknowledgement is already queued;
                    # stop input admission and let the sole writer flush it.
                    self.request_stop()
                    return
            if frames:
                # A completed frame closes the deadline that belonged to its
                # prefix, even if trailing bytes begin the next frame.
                self._partial_deadline = None
            if self.decoder.partial_frame:
                if self._partial_deadline is None:
                    self._partial_deadline = (
                        asyncio.get_running_loop().time() + self.partial_timeout
                    )
            else:
                self._partial_deadline = None

    async def _write_loop(self) -> None:
        while True:
            try:
                await asyncio.wait_for(self._wake_writer.wait(), 0.05)
            except asyncio.TimeoutError:
                pass
            self._wake_writer.clear()
            if self._responses:
                frame = self._responses.popleft()
                self._inflight_response_bytes = len(frame)
                try:
                    self.writer.write(frame)
                    await self.writer.drain()
                finally:
                    self._response_bytes -= self._inflight_response_bytes
                    self._inflight_response_bytes = 0
                # Buffered work is already known to exist; do not pay the
                # idle poll interval between consecutive wire frames.
                self._wake_writer.set()
                continue
            try:
                events = self.dispatcher.event_queue.drain(max_events=1)
            except Exception:
                self._fail("transport-error")
                return
            if events:
                item = events[0]
                self.writer.write(item.frame)
                await self.writer.drain()
                # Re-check responses before draining a second event.
                self._wake_writer.set()
                continue
            if self._stop.is_set():
                return

    async def _close_local(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self.dispatcher.dispose()
        except BaseException:
            self._fail("transport-error")
        wait_closed = getattr(self.backend, "wait_closed", None)
        if callable(wait_closed):
            try:
                await asyncio.wait_for(wait_closed(), EJN_LOCAL_CLOSE_TIMEOUT)
            except BaseException:
                self._fail("transport-error")

    def _write_stderr(self, code: str) -> None:
        if not code or self.stderr is None:
            return
        message = f"ejn-helper: {code}\n".encode("ascii", "replace")
        try:
            self.stderr.write(message[:EJN_RUNTIME_ERROR_BYTES])
            flush = getattr(self.stderr, "flush", None)
            if callable(flush):
                flush()
        except BaseException:
            pass


async def run_stdio() -> int:
    """Bind :class:`ProtocolRuntime` to the process's binary standard streams."""
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=EJN_MAX_RAW_ACCUMULATOR)
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, __import__("sys").stdin.buffer)
    # StreamWriter.wait_closed requires a protocol with a close waiter;
    # FlowControlMixin alone deliberately has no such implementation.
    writer_protocol = asyncio.StreamReaderProtocol(asyncio.StreamReader())
    transport, _writer_protocol = await loop.connect_write_pipe(
        lambda: writer_protocol, __import__("sys").stdout.buffer
    )
    writer = asyncio.StreamWriter(transport, writer_protocol, None, loop)
    runtime = ProtocolRuntime(reader, writer, stderr=__import__("sys").stderr.buffer)
    try:
        loop.add_signal_handler(signal.SIGTERM, runtime.request_stop)
    except (NotImplementedError, RuntimeError):
        pass
    return await runtime.run()
