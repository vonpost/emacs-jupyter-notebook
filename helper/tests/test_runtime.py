"""Pure async tests for the helper's binary protocol runtime."""

from __future__ import annotations

import asyncio
import io
import re
import unittest
from pathlib import Path
from unittest import mock

from ejn_helper.backend import BackendCompletion, BackendEvent
from ejn_helper.flow import EJN_MAX_PRIORITY_QUEUE, EJN_MAX_RESPONSE_FRAME
from ejn_helper.framing import Decoder, encode
from ejn_helper.jupyter_backend import JupyterBackend
from ejn_helper.runtime import (
    EJN_EMACS_KERNEL_INFO_DEADLINE,
    EJN_STARTUP_KERNEL_INFO_BACKEND_DEADLINE,
    EJN_STARTUP_KERNEL_INFO_DISPATCHER_DEADLINE,
    ProtocolRuntime,
)


class _Writer:
    def __init__(self) -> None:
        self.frames: list[bytes] = []
        self.drains = 0

    def write(self, data: bytes) -> None:
        self.frames.append(bytes(data))

    async def drain(self) -> None:
        self.drains += 1

    def close(self) -> None:
        pass


class _Backend:
    def __init__(self) -> None:
        self.closed = 0

    def start(self, operation, _params, _events, complete):
        complete(type("Done", (), {"result": {}, "error": None})())
        return None

    def close(self) -> None:
        self.closed += 1

    async def wait_closed(self) -> None:
        return None


class _GateWriter(_Writer):
    """A single-owner writer whose first drain is explicitly backpressured."""

    def __init__(self) -> None:
        super().__init__()
        self.first_drain = asyncio.Event()
        self.release = asyncio.Event()
        self._block_once = True
        self.active_drains = 0
        self.max_active_drains = 0

    async def drain(self) -> None:
        self.drains += 1
        self.active_drains += 1
        self.max_active_drains = max(self.max_active_drains, self.active_drains)
        try:
            if self._block_once:
                self._block_once = False
                self.first_drain.set()
                await self.release.wait()
        finally:
            self.active_drains -= 1


class _Cancellation:
    def __init__(self) -> None:
        self.calls = 0

    def cancel(self) -> None:
        self.calls += 1


class _HoldingBackend:
    """Backend fixture that can synchronously attach or retain one operation."""

    def __init__(self, *, attach: bool = True, produce: bool = False) -> None:
        self.attach = attach
        self.produce = produce
        self.starts: list[str] = []
        self.cancellations: list[_Cancellation] = []
        self.completions = []
        self.closed = 0
        self.producer: asyncio.Task | None = None

    def start(self, operation, _params, event_callback, completion_callback):
        self.starts.append(operation)
        cancellation = _Cancellation()
        self.cancellations.append(cancellation)
        if operation == "connect" and self.attach:
            completion_callback(BackendCompletion.success({"attached": True}))
        elif operation == "execute" and self.produce:
            self.completions.append(completion_callback)
            async def produce() -> None:
                await asyncio.sleep(60)
                event_callback(BackendEvent("stream", {"name": "stdout", "text": "late"}))

            self.producer = asyncio.create_task(produce())
        else:
            self.completions.append(completion_callback)
        return cancellation

    def close(self) -> None:
        self.closed += 1
        if self.producer is not None:
            self.producer.cancel()

    async def wait_closed(self) -> None:
        if self.producer is not None:
            await asyncio.gather(self.producer, return_exceptions=True)


def _decode(frames: list[bytes]) -> list[dict]:
    decoder = Decoder(262_144)
    result = []
    for frame in frames:
        result.extend(decoder.feed(frame))
    return result


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_startup_kernel_info_deadline_hierarchy(self):
        runtime = ProtocolRuntime(asyncio.StreamReader(), _Writer())
        self.assertIsInstance(runtime.backend, JupyterBackend)
        self.assertEqual(
            runtime.backend.operation_deadlines["kernel_info"],
            EJN_STARTUP_KERNEL_INFO_BACKEND_DEADLINE,
        )
        self.assertEqual(
            runtime.dispatcher.operation_timeouts["kernel_info"],
            EJN_STARTUP_KERNEL_INFO_DISPATCHER_DEADLINE,
        )
        self.assertLess(
            EJN_STARTUP_KERNEL_INFO_BACKEND_DEADLINE,
            EJN_STARTUP_KERNEL_INFO_DISPATCHER_DEADLINE,
        )
        self.assertLess(
            EJN_STARTUP_KERNEL_INFO_DISPATCHER_DEADLINE,
            EJN_EMACS_KERNEL_INFO_DEADLINE,
        )

    async def test_emacs_source_uses_the_tested_kernel_info_deadline(self):
        root = Path(__file__).resolve().parents[2]
        adapter = (root / "emacs-jupyter-notebook-helper-backend.el").read_text()
        match = re.search(
            r"\(defconst\s+emacs-jupyter-notebook-helper-backend--verify-timeout\s+([0-9.]+)",
            adapter,
        )
        self.assertIsNotNone(match)
        self.assertEqual(float(match.group(1)), EJN_EMACS_KERNEL_INFO_DEADLINE)

    async def test_injected_dispatcher_factory_keeps_two_argument_contract(self):
        backend = _Backend()
        received = []

        def factory(current_backend, response_callback):
            received.append((current_backend, response_callback))
            return ProtocolRuntime._default_dispatcher(current_backend, response_callback)

        runtime = ProtocolRuntime(
            asyncio.StreamReader(), _Writer(), backend=backend, dispatcher_factory=factory
        )
        self.assertEqual(len(received), 1)
        self.assertIs(received[0][0], backend)
        self.assertIs(runtime.backend, backend)

    async def _run(self, chunks: list[bytes], *, partial_timeout=0.05):
        reader = asyncio.StreamReader()
        for chunk in chunks:
            reader.feed_data(chunk)
        reader.feed_eof()
        writer, stderr, backend = _Writer(), io.BytesIO(), _Backend()
        runtime = ProtocolRuntime(
            reader, writer, backend=backend, stderr=stderr, partial_timeout=partial_timeout
        )
        code = await asyncio.wait_for(runtime.run(), 1)
        return code, _decode(writer.frames), stderr.getvalue(), backend

    async def test_golden_hello_ping_and_fragmentation(self):
        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        ping = encode({"v": 1, "kind": "request", "id": "p", "op": "ping", "params": {}}, 1_048_576)
        code, frames, stderr, backend = await self._run([hello[:3], hello[3:] + ping])
        self.assertEqual(code, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual([item["id"] for item in frames], ["h", "p"])
        self.assertTrue(all(item["ok"] for item in frames))
        self.assertEqual(backend.closed, 1)

    async def test_every_split_and_truncated_eof_boundary(self):
        frame = encode(
            {"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}},
            1_048_576,
        )
        for split in range(len(frame) + 1):
            with self.subTest(split=split):
                code, frames, _stderr, _backend = await self._run([frame[:split], frame[split:]])
                self.assertEqual(code, 0)
                self.assertEqual(frames[0]["id"], "h")
        for cut in range(1, len(frame)):
            with self.subTest(cut=cut):
                code, frames, _stderr, _backend = await self._run([frame[:cut]])
                self.assertEqual(code, 2)
                self.assertEqual(frames, [])

    async def test_partial_eof_and_invalid_payload_fail_without_stdout_garbage(self):
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        reader.feed_data(b"\x00\x00")
        reader.feed_eof()
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=io.BytesIO(), partial_timeout=0.05)
        code = await asyncio.wait_for(runtime.run(), 1)
        frames, stderr = _decode(writer.frames), runtime.stderr.getvalue()
        self.assertEqual(code, 2)
        self.assertEqual(frames, [])
        self.assertEqual(stderr, b"ejn-helper: protocol-error\n")
        self.assertEqual(backend.closed, 1)
        self.assertTrue(runtime.decoder.failed)
        self.assertFalse(runtime.decoder.partial_frame)
        self.assertEqual(runtime.decoder.buffered_bytes, 0)
        code, frames, stderr, _backend = await self._run([b"\x00\x00\x00\x02[]"])
        self.assertEqual(code, 2)
        self.assertEqual(frames, [])
        self.assertEqual(stderr, b"ejn-helper: protocol-error\n")

    async def test_silent_peer_stops_locally_without_partial_timeout(self):
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend, partial_timeout=0.02)
        task = asyncio.create_task(runtime.run())
        await asyncio.sleep(0.06)
        self.assertFalse(task.done())
        runtime.request_stop()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        self.assertEqual(backend.closed, 1)

    async def test_partial_deadline_is_absolute_across_trickle_reads(self):
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        stderr = io.BytesIO()
        runtime = ProtocolRuntime(
            reader,
            writer,
            backend=backend,
            stderr=stderr,
            partial_timeout=0.04,
        )
        task = asyncio.create_task(runtime.run())
        reader.feed_data(b"\x00")
        await asyncio.sleep(0.025)
        reader.feed_data(b"\x00")
        await asyncio.sleep(0.03)
        self.assertEqual(await asyncio.wait_for(task, 1), 2)
        self.assertEqual(stderr.getvalue(), b"ejn-helper: protocol-error\n")
        self.assertTrue(runtime.decoder.failed)
        self.assertFalse(runtime.decoder.partial_frame)
        self.assertEqual(runtime.decoder.buffered_bytes, 0)
        self.assertEqual(backend.closed, 1)

    async def test_broken_writer_terminates_a_silent_runtime(self):
        class TrackingReader(asyncio.StreamReader):
            def __init__(self) -> None:
                super().__init__()
                self.read_finished = asyncio.Event()

            async def read(self, n=-1):
                try:
                    return await super().read(n)
                finally:
                    self.read_finished.set()

        class BrokenWriter(_Writer):
            async def drain(self) -> None:
                raise OSError("broken stdout")

        reader, writer, backend = TrackingReader(), BrokenWriter(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend)
        task = asyncio.create_task(runtime.run())
        runtime._enqueue_response(
            {"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}}
        )
        self.assertEqual(await asyncio.wait_for(task, 1), 2)
        self.assertTrue(reader.read_finished.is_set())
        self.assertEqual(backend.closed, 1)

    async def test_blocked_final_flush_is_a_bounded_transport_error(self):
        class BlockedWriter(_Writer):
            def __init__(self) -> None:
                super().__init__()
                self.started = asyncio.Event()

            async def drain(self) -> None:
                self.started.set()
                await asyncio.Future()

        reader, writer, backend, stderr = (
            asyncio.StreamReader(),
            BlockedWriter(),
            _Backend(),
            io.BytesIO(),
        )
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
        runtime._enqueue_response(
            {"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}}
        )
        reader.feed_eof()
        with mock.patch("ejn_helper.runtime.EJN_LOCAL_CLOSE_TIMEOUT", 0.02):
            self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
        self.assertTrue(writer.started.is_set())
        self.assertEqual(runtime.response_bytes, 0)
        self.assertEqual(stderr.getvalue(), b"ejn-helper: transport-error\n")
        self.assertEqual(backend.closed, 1)

    def test_response_limit_has_protocol_ceiling(self):
        with self.assertRaises(ValueError):
            ProtocolRuntime(
                asyncio.StreamReader(), _Writer(), backend=_Backend(), response_limit=524_289
            )

    def test_runtime_bound_arguments_reject_nonfinite_boolean_and_invalid_values(self):
        for value in (float("nan"), float("inf"), float("-inf"), True, False, 0, -1):
            with self.subTest(partial_timeout=value):
                with self.assertRaises(ValueError):
                    ProtocolRuntime(asyncio.StreamReader(), _Writer(), backend=_Backend(), partial_timeout=value)
        for value in (False, True, 0, EJN_MAX_RESPONSE_FRAME - 1, EJN_MAX_PRIORITY_QUEUE + 1):
            with self.subTest(response_limit=value):
                with self.assertRaises(ValueError):
                    ProtocolRuntime(asyncio.StreamReader(), _Writer(), backend=_Backend(), response_limit=value)
        for value in (False, True, 0, -1, 1_048_577):
            with self.subTest(read_size=value):
                with self.assertRaises(ValueError):
                    ProtocolRuntime(asyncio.StreamReader(), _Writer(), backend=_Backend(), read_size=value)

    async def test_malformed_frames_have_exact_safe_failures_and_no_stdout_text(self):
        malformed = {
            "oversized-prefix": (1_048_573).to_bytes(4, "big"),
            "invalid-utf8": b"\x00\x00\x00\x01\xff",
            "invalid-json": b"\x00\x00\x00\x01{",
            "json-non-object": b"\x00\x00\x00\x02[]",
        }
        for name, payload in malformed.items():
            with self.subTest(name=name):
                reader, writer, backend, stderr = asyncio.StreamReader(), _Writer(), _Backend(), io.BytesIO()
                reader.feed_data(payload)
                reader.feed_eof()
                runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr, partial_timeout=0.05)
                code = await asyncio.wait_for(runtime.run(), 1)
                expected = b"ejn-helper: frame-too-large\n" if name == "oversized-prefix" else b"ejn-helper: protocol-error\n"
                self.assertEqual(code, 2)
                self.assertEqual(writer.frames, [])
                self.assertEqual(stderr.getvalue(), expected)
                self.assertTrue(runtime.decoder.failed)
                self.assertEqual(runtime.decoder.buffered_bytes, 0)
                self.assertEqual(backend.closed, 1)

    async def test_partial_deadline_resets_for_trailing_partial_frame(self):
        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        ping = encode({"v": 1, "kind": "request", "id": "p", "op": "ping", "params": {}}, 1_048_576)
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend, partial_timeout=0.06)
        task = asyncio.create_task(runtime.run())
        reader.feed_data(hello[:4])
        await asyncio.sleep(0.035)
        reader.feed_data(hello[4:] + ping[:2])
        # The old hello deadline must not govern the new ping prefix.
        await asyncio.sleep(0.04)
        self.assertFalse(task.done())
        reader.feed_data(ping[2:])
        reader.feed_eof()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        self.assertEqual([frame["id"] for frame in _decode(writer.frames)], ["h", "p"])

    async def test_response_lane_overflow_is_bounded_while_stdout_is_blocked(self):
        reader, writer, backend, stderr = asyncio.StreamReader(), _GateWriter(), _Backend(), io.BytesIO()
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
        task = asyncio.create_task(runtime.run())
        response = {"v": 1, "kind": "response", "id": "x", "ok": True, "result": {"text": "x" * 64_000}}
        runtime._enqueue_response(response)
        await asyncio.wait_for(writer.first_drain.wait(), 1)
        for index in range(32):
            runtime._enqueue_response({**response, "id": f"x-{index}"})
            if runtime._failed is not None:
                break
        self.assertIsNotNone(runtime._failed)
        self.assertEqual(runtime._failed.code, "credit-exhausted")
        self.assertLessEqual(runtime.max_observed_response_bytes, EJN_MAX_PRIORITY_QUEUE)
        self.assertLessEqual(runtime.response_bytes, EJN_MAX_PRIORITY_QUEUE)
        reader.feed_eof()
        writer.release.set()
        self.assertEqual(await asyncio.wait_for(task, 1), 2)
        self.assertEqual(stderr.getvalue(), b"ejn-helper: credit-exhausted\n")
        self.assertTrue(all(isinstance(item, dict) for item in _decode(writer.frames)))
        self.assertLessEqual(len(writer.frames), 1)
        self.assertEqual(runtime.response_bytes, 0)
        self.assertEqual(runtime.dispatcher.inflight_count, 0)
        self.assertEqual(backend.closed, 1)
        self.assertTrue(runtime._writer_task is not None and runtime._writer_task.done())

    async def test_fatal_response_overflow_stops_same_chunk_admission(self):
        hello = encode(
            {
                "v": 1,
                "kind": "request",
                "id": "hello",
                "op": "hello",
                "params": {"versions": [1]},
            },
            1_048_576,
        )
        ping_frames = b"".join(
            encode(
                {
                    "v": 1,
                    "kind": "request",
                    "id": f"ping-{index}",
                    "op": "ping",
                    "params": {},
                },
                1_048_576,
            )
            for index in range(1_000)
        )
        connect = encode(
            {
                "v": 1,
                "kind": "request",
                "id": "must-not-start",
                "op": "connect",
                "params": {
                    "connection_file": "/tmp/connection.json",
                    "artifact_dir": "/tmp/artifacts",
                },
            },
            1_048_576,
        )
        reader, writer, backend, stderr = (
            asyncio.StreamReader(),
            _Writer(),
            _HoldingBackend(),
            io.BytesIO(),
        )
        reader.feed_data(hello + ping_frames + connect)
        reader.feed_eof()
        runtime = ProtocolRuntime(
            reader,
            writer,
            backend=backend,
            stderr=stderr,
            response_limit=EJN_MAX_RESPONSE_FRAME,
            read_size=1_048_576,
        )

        self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
        self.assertEqual(backend.starts, [])
        self.assertEqual(stderr.getvalue(), b"ejn-helper: credit-exhausted\n")
        self.assertEqual(runtime.response_bytes, 0)

    async def test_response_preempts_second_event_after_unavoidable_blocked_event(self):
        reader, writer, backend = asyncio.StreamReader(), _GateWriter(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend)
        for number in (1, 2):
            runtime.dispatcher.event_queue.enqueue(
                {"v": 1, "kind": "event", "event": "display_data", "request_id": f"e-{number}", "data": {"number": number}}
            )
        runtime.dispatcher.event_queue.grant_credit(1_000_000)
        runtime._wake_writer.set()
        task = asyncio.create_task(runtime.run())
        await asyncio.wait_for(writer.first_drain.wait(), 1)
        runtime._enqueue_response({"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}})
        writer.release.set()
        reader.feed_eof()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        decoded = _decode(writer.frames)
        self.assertEqual([(item["kind"], item.get("id"), item.get("request_id")) for item in decoded], [("event", None, "e-1"), ("response", "r", None), ("event", None, "e-2")])
        self.assertEqual(writer.max_active_drains, 1)
        self.assertEqual(runtime.dispatcher.event_queue.buffered_bytes, 0)
        self.assertEqual(len(writer.frames), 3)

    async def test_backend_start_failure_is_one_safe_response_and_clean_exit(self):
        class BoomBackend(_Backend):
            def start(self, *_args):
                raise RuntimeError("private backend failure")

        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        connect = encode({"v": 1, "kind": "request", "id": "c", "op": "connect", "params": {"connection_file": "/tmp/x", "artifact_dir": "/tmp/y"}}, 1_048_576)
        reader, writer, stderr, backend = asyncio.StreamReader(), _Writer(), io.BytesIO(), BoomBackend()
        reader.feed_data(hello + connect)
        reader.feed_eof()
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr, partial_timeout=0.05)
        code = await asyncio.wait_for(runtime.run(), 1)
        frames = _decode(writer.frames)
        stderr = stderr.getvalue()
        self.assertEqual(code, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual([item["id"] for item in frames], ["h", "c"])
        self.assertEqual(frames[-1]["error"]["code"], "transport-error")
        self.assertNotIn("private", repr(frames))
        self.assertEqual(backend.closed, 1)

    async def test_synchronous_reentrant_backend_callbacks_are_bounded_and_retired(self):
        class ReentrantBackend(_Backend):
            def __init__(self) -> None:
                super().__init__()
                self.starts = []

            def start(self, operation, _params, event_callback, completion_callback):
                self.starts.append(operation)
                if operation == "connect":
                    completion_callback(BackendCompletion.success({"attached": True}))
                else:
                    event_callback(BackendEvent("stream", {"name": "stdout", "text": "one"}))
                    completion_callback(BackendCompletion.success({"done": True}))
                    completion_callback(BackendCompletion.success({"duplicate": True}))
                return _Cancellation()

        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        connect = encode({"v": 1, "kind": "request", "id": "c", "op": "connect", "params": {"connection_file": "/tmp/x", "artifact_dir": "/tmp/y"}}, 1_048_576)
        credit = encode({"v": 1, "kind": "request", "id": "g", "op": "grant_event_credit", "params": {"bytes": 10_000}}, 1_048_576)
        execute = encode({"v": 1, "kind": "request", "id": "e", "op": "execute", "params": {"code": "x"}}, 1_048_576)
        reader, writer, stderr, backend = asyncio.StreamReader(), _Writer(), io.BytesIO(), ReentrantBackend()
        reader.feed_data(hello + connect + credit + execute)
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
        task = asyncio.create_task(runtime.run())
        for _ in range(100):
            if any(
                item.get("event") == "stream" for item in _decode(writer.frames)
            ):
                break
            await asyncio.sleep(0)
        runtime.request_stop()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        decoded = _decode(writer.frames)
        self.assertEqual([item["id"] for item in decoded if item["kind"] == "response"], ["h", "c", "g", "e"])
        self.assertEqual([item["event"] for item in decoded if item["kind"] == "event"], ["stream"])
        self.assertEqual(runtime.dispatcher.inflight_count, 0)
        self.assertEqual(runtime.dispatcher.late_completions, 1)
        self.assertEqual(stderr.getvalue(), b"")

    async def test_stop_disposes_active_connect_and_active_request_once(self):
        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        connect = encode({"v": 1, "kind": "request", "id": "c", "op": "connect", "params": {"connection_file": "/tmp/x", "artifact_dir": "/tmp/y"}}, 1_048_576)
        execute = encode({"v": 1, "kind": "request", "id": "e", "op": "execute", "params": {"code": "x"}}, 1_048_576)

        active_connect = _HoldingBackend(attach=False)
        reader, writer = asyncio.StreamReader(), _Writer()
        reader.feed_data(hello + connect)
        reader.feed_eof()
        runtime = ProtocolRuntime(reader, writer, backend=active_connect)
        self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 0)
        self.assertEqual(active_connect.closed, 1)
        self.assertEqual([item.calls for item in active_connect.cancellations], [1])
        self.assertEqual(runtime.dispatcher.inflight_count, 0)

        active_request = _HoldingBackend(attach=True, produce=True)
        reader, writer = asyncio.StreamReader(), _Writer()
        reader.feed_data(hello + connect + execute)
        runtime = ProtocolRuntime(reader, writer, backend=active_request)
        task = asyncio.create_task(runtime.run())
        for _ in range(10):
            await asyncio.sleep(0)
            if len(active_request.starts) == 2:
                break
        self.assertEqual(active_request.starts, ["connect", "execute"])
        # This is the same local-only path installed by the SIGTERM handler.
        runtime.request_stop()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        self.assertEqual(active_request.closed, 1)
        self.assertEqual([item.calls for item in active_request.cancellations], [0, 1])
        self.assertIsNotNone(active_request.producer)
        self.assertTrue(active_request.producer.done())
        self.assertEqual(runtime.dispatcher.inflight_count, 0)
        before = list(writer.frames)
        active_request.completions[0](BackendCompletion.success({"late": True}))
        self.assertEqual(writer.frames, before)

    async def test_close_and_wait_closed_failures_are_bounded_transport_errors(self):
        class CloseFails(_Backend):
            def close(self) -> None:
                self.closed += 1
                raise RuntimeError("secret close failure")

        class WaitFails(_Backend):
            async def wait_closed(self) -> None:
                raise RuntimeError("secret wait failure")

        for backend in (CloseFails(), WaitFails()):
            with self.subTest(backend=type(backend).__name__):
                reader, writer, stderr = asyncio.StreamReader(), _Writer(), io.BytesIO()
                reader.feed_eof()
                runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
                self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
                self.assertEqual(writer.frames, [])
                self.assertEqual(stderr.getvalue(), b"ejn-helper: transport-error\n")
                self.assertEqual(backend.closed, 1)

    async def test_cancelled_backend_teardown_still_retires_blocked_writer(self):
        class CancelledWaitBackend(_Backend):
            async def wait_closed(self) -> None:
                raise asyncio.CancelledError

        class BlockedWriter(_Writer):
            async def drain(self) -> None:
                await asyncio.Future()

        reader, writer, backend, stderr = (
            asyncio.StreamReader(),
            BlockedWriter(),
            CancelledWaitBackend(),
            io.BytesIO(),
        )
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
        runtime._enqueue_response(
            {"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}}
        )
        reader.feed_eof()
        with mock.patch("ejn_helper.runtime.EJN_LOCAL_CLOSE_TIMEOUT", 0.02):
            self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
        self.assertEqual(stderr.getvalue(), b"ejn-helper: transport-error\n")
        self.assertEqual(runtime.response_bytes, 0)
        self.assertTrue(runtime._writer_task is not None)
        self.assertTrue(runtime._writer_task.done())
        self.assertEqual(backend.closed, 1)

    async def test_writer_teardown_failures_are_bounded_transport_errors(self):
        class CloseFailsWriter(_Writer):
            def close(self) -> None:
                raise RuntimeError("private close failure")

        class WaitFailsWriter(_Writer):
            async def wait_closed(self) -> None:
                raise RuntimeError("private wait failure")

        class WaitCancelledWriter(_Writer):
            async def wait_closed(self) -> None:
                raise asyncio.CancelledError

        for writer in (CloseFailsWriter(), WaitFailsWriter(), WaitCancelledWriter()):
            with self.subTest(writer=type(writer).__name__):
                reader, backend, stderr = asyncio.StreamReader(), _Backend(), io.BytesIO()
                reader.feed_eof()
                runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
                self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
                self.assertEqual(writer.frames, [])
                self.assertEqual(stderr.getvalue(), b"ejn-helper: transport-error\n")
                self.assertEqual(backend.closed, 1)

    async def test_cancelled_child_writer_is_a_bounded_transport_error(self):
        class CancelledWriter(_Writer):
            async def drain(self) -> None:
                raise asyncio.CancelledError

        reader, writer, backend, stderr = (
            asyncio.StreamReader(),
            CancelledWriter(),
            _Backend(),
            io.BytesIO(),
        )
        runtime = ProtocolRuntime(reader, writer, backend=backend, stderr=stderr)
        runtime._enqueue_response(
            {"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}}
        )
        self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 2)
        self.assertEqual(stderr.getvalue(), b"ejn-helper: transport-error\n")
        self.assertEqual(runtime.response_bytes, 0)
        self.assertTrue(runtime._writer_task is not None)
        self.assertTrue(runtime._writer_task.done())
        self.assertEqual(backend.closed, 1)

    async def test_protocol_close_finishes_busy_request_before_close_ack(self):
        hello = encode({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}}, 1_048_576)
        connect = encode({"v": 1, "kind": "request", "id": "c", "op": "connect", "params": {"connection_file": "/tmp/x", "artifact_dir": "/tmp/y"}}, 1_048_576)
        execute = encode({"v": 1, "kind": "request", "id": "e", "op": "execute", "params": {"code": "x"}}, 1_048_576)
        close = encode({"v": 1, "kind": "request", "id": "z", "op": "close", "params": {}}, 1_048_576)
        backend = _HoldingBackend(attach=True)
        reader, writer = asyncio.StreamReader(), _Writer()
        reader.feed_data(hello + connect + execute + close)
        runtime = ProtocolRuntime(reader, writer, backend=backend)
        self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 0)
        decoded = _decode(writer.frames)
        ids = [item["id"] for item in decoded]
        self.assertLess(ids.index("e"), ids.index("z"))
        self.assertEqual(next(item for item in decoded if item["id"] == "e")["error"]["code"], "transport-error")
        self.assertEqual(next(item for item in decoded if item["id"] == "z")["result"], {"closed": True})
        self.assertEqual(backend.closed, 1)
        self.assertNotIn("shutdown", backend.starts)
        self.assertEqual([item.calls for item in backend.cancellations], [0, 1])
        self.assertEqual(runtime.dispatcher.inflight_count, 0)

    async def test_responses_drain_before_priority_and_credit_blocked_events(self):
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend)
        runtime.dispatcher.event_queue.enqueue(
            {"v": 1, "kind": "event", "event": "status", "request_id": "x", "data": {}}
        )
        runtime._enqueue_response({"v": 1, "kind": "response", "id": "r", "ok": True, "result": {}})
        task = asyncio.create_task(runtime.run())
        for _ in range(100):
            if len(writer.frames) >= 2:
                break
            await asyncio.sleep(0)
        runtime.request_stop()
        self.assertEqual(await asyncio.wait_for(task, 1), 0)
        decoded = _decode(writer.frames)
        self.assertEqual(decoded[0]["kind"], "response")
        self.assertEqual(decoded[1]["event"], "status")

    async def test_local_stop_discards_credit_blocked_events(self):
        reader, writer, backend = asyncio.StreamReader(), _Writer(), _Backend()
        runtime = ProtocolRuntime(reader, writer, backend=backend)
        runtime.dispatcher.event_queue.enqueue(
            {
                "v": 1,
                "kind": "event",
                "event": "display_data",
                "request_id": "blocked",
                "data": {"text/plain": "retained"},
            }
        )
        runtime.request_stop()
        self.assertEqual(await asyncio.wait_for(runtime.run(), 1), 0)
        self.assertEqual(writer.frames, [])
        self.assertEqual(runtime.dispatcher.event_queue.buffered_bytes, 0)

    async def test_protocol_close_flushes_ack_then_stops(self):
        hello = encode(
            {"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}},
            1_048_576,
        )
        close = encode(
            {"v": 1, "kind": "request", "id": "c", "op": "close", "params": {}},
            1_048_576,
        )
        code, frames, stderr, backend = await self._run([hello + close])
        self.assertEqual(code, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual(frames[-1]["id"], "c")
        self.assertEqual(frames[-1]["result"], {"closed": True})
        self.assertEqual(backend.closed, 1)


if __name__ == "__main__":
    unittest.main()
