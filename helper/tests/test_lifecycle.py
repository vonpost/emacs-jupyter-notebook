"""Deterministic lifecycle tests for the single-reader Jupyter adapter."""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from queue import Empty

from ejn_helper.jupyter_backend import JupyterBackend


class LifecycleBackendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.queues = {
            name: asyncio.Queue() for name in ("shell", "iopub", "stdin", "control")
        }
        self.clients = []
        outer = self

        class Session:
            def __init__(self, client) -> None:
                self.client = client

            def send(self, _socket, message_type, *, content):
                if self.client.send_error is not None:
                    raise self.client.send_error
                self.client.control_count += 1
                message_id = f"control-{self.client.control_count}"
                self.client.sent.append((message_id, message_type, dict(content)))
                return {"header": {"msg_id": message_id}}

        class Client:
            def __init__(self) -> None:
                self.alive = True
                self.liveness_error = None
                self.send_error = None
                self.control_count = 0
                self.sent = []
                self.stopped = 0
                self.session = Session(self)
                self.control_channel = types.SimpleNamespace(socket=object())
                outer.clients.append(self)

            def load_connection_info(self, _info):
                pass

            def start_channels(self):
                pass

            def stop_channels(self):
                self.stopped += 1

            async def wait_for_ready(self):
                return None

            def is_alive(self):
                if self.liveness_error is not None:
                    raise self.liveness_error
                return self.alive

            def execute(self, _code):
                return "execute-1"

            def kernel_info(self):
                return "kernel-info-1"

        for name in self.queues:
            async def getter(self, timeout, name=name):
                try:
                    return await asyncio.wait_for(outer.queues[name].get(), timeout)
                except asyncio.TimeoutError as exc:
                    raise Empty from exc

            setattr(Client, f"get_{name}_msg", getter)

        self._old_module = sys.modules.get("jupyter_client")
        sys.modules["jupyter_client"] = types.SimpleNamespace(AsyncKernelClient=Client)
        self.addCleanup(self._restore_module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def _restore_module(self) -> None:
        if self._old_module is None:
            sys.modules.pop("jupyter_client", None)
        else:
            sys.modules["jupyter_client"] = self._old_module

    async def _connected(
        self,
        *,
        deadline: float = 0.15,
        operation_deadlines: dict[str, float] | None = None,
    ):
        root = Path(self.directory.name)
        connection = root / "connection.json"
        connection.write_text(
            json.dumps(
                {
                    "ip": "127.0.0.1",
                    "transport": "tcp",
                    "key": "x",
                    "signature_scheme": "hmac-sha256",
                    "shell_port": 1,
                    "iopub_port": 2,
                    "stdin_port": 3,
                    "control_port": 4,
                    "hb_port": 5,
                }
            ),
            encoding="utf-8",
        )
        artifacts = root / "artifacts"
        artifacts.mkdir(mode=0o700, exist_ok=True)
        backend = JupyterBackend(
            deadline=deadline, operation_deadlines=operation_deadlines
        )
        complete = asyncio.get_running_loop().create_future()
        backend.start(
            "connect",
            {"connection_file": str(connection), "artifact_dir": str(artifacts), "image_max_pixels": 4_194_304},
            lambda _event: None,
            complete.set_result,
        )
        result = await asyncio.wait_for(complete, 1)
        self.assertIsNone(result.error)
        self.addAsyncCleanup(self._close, backend)
        return backend, self.clients[-1]

    async def _close(self, backend) -> None:
        backend.close()
        await backend.wait_closed()

    async def _request(self, backend, operation: str):
        complete = asyncio.get_running_loop().create_future()
        params = {"code": "x"} if operation == "execute" else {}
        token = backend.start(operation, params, lambda _event: True, complete.set_result)
        await asyncio.sleep(0)
        return token, complete

    @staticmethod
    def _message(message_id: str, message_type: str, content: dict):
        return {
            "parent_header": {"msg_id": message_id},
            "msg_type": message_type,
            "content": content,
        }

    async def _ack_shutdown(self, client) -> None:
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "ok"})
        )
        for _ in range(10):
            await asyncio.sleep(0)
            if len(client.sent) == 2:
                break
        self.assertEqual(
            client.sent[1], ("control-2", "shutdown_request", {"restart": False})
        )
        await self.queues["control"].put(
            # The portable Jupyter reply shape contains only ``restart``.
            self._message("control-2", "shutdown_reply", {"restart": False})
        )

    async def test_interrupt_is_correlated_and_execution_remains_usable(self):
        backend, client = await self._connected()
        _token, interrupt = await self._request(backend, "interrupt")
        self.assertEqual(client.sent, [("control-1", "interrupt_request", {})])
        await self.queues["control"].put(
            self._message("control-1", "shutdown_reply", {"status": "ok", "restart": False})
        )
        await self.queues["control"].put(
            self._message("other", "interrupt_reply", {"status": "ok"})
        )
        self.assertFalse(interrupt.done())
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "ok"})
        )
        self.assertEqual((await asyncio.wait_for(interrupt, 1)).result, {"interrupted": True})
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "ok"})
        )
        _token, execute = await self._request(backend, "execute")
        await self.queues["shell"].put(
            self._message("execute-1", "execute_reply", {"status": "ok"})
        )
        await self.queues["iopub"].put(
            self._message("execute-1", "status", {"execution_state": "idle"})
        )
        self.assertEqual((await asyncio.wait_for(execute, 1)).result, {"status": "ok"})
        self.assertFalse(backend._transport_failed)

    async def test_kernel_info_deadline_override_leaves_execute_to_its_owner(self):
        backend, _client = await self._connected(
            deadline=0.01, operation_deadlines={"kernel_info": 0.08}
        )
        self.assertIsNone(backend._operation_deadline("execute"))
        self.assertEqual(backend._operation_deadline("kernel_info"), 0.08)

        _token, kernel_info = await self._request(backend, "kernel_info")
        _token, execute = await self._request(backend, "execute")
        await asyncio.sleep(0.03)
        self.assertFalse(execute.done())
        self.assertFalse(kernel_info.done())
        kernel_info_result = await asyncio.wait_for(kernel_info, 1)
        self.assertEqual(kernel_info_result.error.code, "timeout")
        backend.close()
        await backend.wait_closed()
        # Local close deliberately does not manufacture a terminal reply for
        # an admitted execute.  Emacs owns that ambiguity and has already
        # classified it before retiring its helper transport.
        self.assertFalse(execute.done())
        execute.cancel()

    async def test_operation_deadline_overrides_are_finite_and_kernel_info_only(self):
        for invalid in (False, 0, float("nan"), float("inf")):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    JupyterBackend(operation_deadlines={"kernel_info": invalid})
        with self.assertRaises(ValueError):
            JupyterBackend(operation_deadlines={"execute": 0.1})

    async def test_transient_liveness_misses_recover_without_transport_failure(self):
        backend, client = await self._connected(deadline=0.05)
        observed = []
        backend.set_transport_failure_callback(lambda: observed.append("lost"))
        responses = iter((False, True, OSError("transient heartbeat failure"), True))
        sampled = asyncio.Event()
        samples = 0

        def is_alive():
            nonlocal samples
            samples += 1
            value = next(responses, True)
            if samples == 4:
                sampled.set()
            if isinstance(value, Exception):
                raise value
            return value

        client.is_alive = is_alive
        await asyncio.wait_for(sampled.wait(), 1)
        await asyncio.sleep(backend._heartbeat_interval * 1.5)

        self.assertEqual(observed, [])
        self.assertFalse(backend._transport_failed)
        self.assertIs(backend.client, client)

    async def test_idle_liveness_failure_notifies_once_without_a_request(self):
        backend, client = await self._connected(deadline=0.05)
        observed = []
        backend.set_transport_failure_callback(lambda: observed.append("lost"))
        client.alive = False

        for _ in range(30):
            if observed:
                break
            await asyncio.sleep(0.01)

        self.assertEqual(observed, ["lost"])
        self.assertTrue(backend._transport_failed)
        self.assertIsNone(backend.client)
        self.assertGreaterEqual(client.stopped, 1)
        await asyncio.sleep(0.08)
        self.assertEqual(observed, ["lost"])

    async def test_shutdown_requires_reply_and_terminal_liveness_then_retires_local_state(self):
        backend, client = await self._connected()
        _token, execute = await self._request(backend, "execute")
        _token, shutdown = await self._request(backend, "shutdown")
        self.assertEqual(
            client.sent,
            [("control-1", "interrupt_request", {})],
        )
        await self._ack_shutdown(client)
        self.assertFalse(shutdown.done())
        client.alive = False
        result = await asyncio.wait_for(shutdown, 1)
        self.assertEqual(result.result, {"shutdown": True})
        self.assertIsNone(result.error)
        retired_execute = await asyncio.wait_for(execute, 1)
        self.assertEqual(retired_execute.error.code, "transport-error")
        await asyncio.sleep(0)
        self.assertEqual(backend._pending, {})
        self.assertEqual(backend._pending_by_task, {})
        self.assertEqual(backend._input_prompts, {})
        self.assertEqual(backend._readers, set())
        self.assertEqual(backend._tasks, set())
        self.assertIsNone(backend.client)
        self.assertGreaterEqual(client.stopped, 1)

    async def test_shutdown_reply_timeout_cancellation_send_and_liveness_failure_retire_local_state(self):
        async def assert_retired(backend) -> None:
            await asyncio.sleep(0)
            self.assertEqual(backend._pending, {})
            self.assertEqual(backend._pending_by_task, {})
            self.assertEqual(backend._readers, set())
            self.assertEqual(backend._tasks, set())
            self.assertIsNone(backend.client)

        backend, _client = await self._connected(deadline=0.05)
        _token, timed = await self._request(backend, "shutdown")
        self.assertEqual((await asyncio.wait_for(timed, 1)).error.code, "timeout")
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "ok"})
        )
        await assert_retired(backend)

        backend, client = await self._connected()
        client.send_error = OSError("send failed")
        _token, sent = await self._request(backend, "shutdown")
        self.assertEqual((await asyncio.wait_for(sent, 1)).error.code, "transport-error")
        await assert_retired(backend)

        backend, _client = await self._connected()
        _token, malformed = await self._request(backend, "shutdown")
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "error"})
        )
        self.assertEqual(
            (await asyncio.wait_for(malformed, 1)).error.code, "protocol-error"
        )
        await assert_retired(backend)

        backend, client = await self._connected()
        _token, malformed = await self._request(backend, "shutdown")
        await self.queues["control"].put(
            self._message("control-1", "interrupt_reply", {"status": "ok"})
        )
        for _ in range(10):
            await asyncio.sleep(0)
            if len(client.sent) == 2:
                break
        await self.queues["control"].put(
            self._message("control-2", "shutdown_reply", {"restart": True})
        )
        self.assertEqual(
            (await asyncio.wait_for(malformed, 1)).error.code, "protocol-error"
        )
        await assert_retired(backend)

        backend, client = await self._connected()
        _token, liveness = await self._request(backend, "shutdown")
        await self._ack_shutdown(client)
        client.liveness_error = OSError("heartbeat failed")
        self.assertEqual(
            (await asyncio.wait_for(liveness, 1)).error.code, "transport-error"
        )
        await assert_retired(backend)

        backend, client = await self._connected()
        token, cancelled = await self._request(backend, "shutdown")
        assert token is not None
        token.cancel()
        await asyncio.sleep(0)
        self.assertFalse(cancelled.done())
        self.assertEqual(client.sent, [("control-1", "interrupt_request", {})])
        await assert_retired(backend)


if __name__ == "__main__":
    unittest.main()
