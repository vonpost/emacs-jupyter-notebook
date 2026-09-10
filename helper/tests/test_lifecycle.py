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

from ejn_helper.jupyter_backend import JupyterBackend, _Pending
from ejn_helper.requests import ExecutionState


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
                self.execute_codes = []
                self.info_count = 0
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
                self.execute_codes.append(_code)
                return "execute-1"

            def kernel_info(self):
                self.info_count += 1
                return f"kernel-info-{self.info_count}"

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
        backend.set_transport_failure_callback(observed.append)
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

    async def test_liveness_misses_are_suspended_through_execution_output_drain(self):
        backend, client = await self._connected(deadline=0.05)
        observed = []
        backend.set_transport_failure_callback(observed.append)
        # Execution keeps this future unresolved until ordered output draining
        # finishes, even after reply and idle have both arrived.
        pending = _Pending(
            asyncio.get_running_loop().create_future(), ExecutionState("execute-1")
        )
        backend._pending["execute-1"] = pending
        client.alive = False
        await asyncio.sleep(backend._heartbeat_interval * 4.5)

        self.assertEqual(observed, [])
        self.assertIs(backend.client, client)
        pending.future.set_result({})

    async def test_idle_liveness_failure_notifies_once_without_a_request(self):
        backend, client = await self._connected(deadline=0.05)
        observed = []
        backend.set_transport_failure_callback(observed.append)
        client.alive = False

        for _ in range(30):
            if observed:
                break
            await asyncio.sleep(0.01)

        self.assertEqual(observed, ["heartbeat"])
        self.assertFalse(backend._transport_failed)
        self.assertTrue(backend._suspended)
        self.assertIs(backend.client, client)
        self.assertEqual(client.stopped, 0)
        await asyncio.sleep(0.08)
        self.assertEqual(observed, ["heartbeat"])

    async def _resume_recovery(self, backend, client):
        _token, resumed = await self._request(backend, "resume")
        for _ in range(10):
            await asyncio.sleep(0)
            if client.sent:
                break
        probe = client.sent[-1][0]
        self.assertEqual(client.sent[-1][1], "kernel_info_request")
        await self.queues["control"].put(
            self._message(probe, "kernel_info_reply", {"status": "ok"})
        )
        # The control reply alone cannot prove the IOPub subscription works.
        await asyncio.sleep(0)
        self.assertFalse(resumed.done())
        await self.queues["iopub"].put(
            self._message(probe, "status", {"execution_state": "idle"})
        )
        self.assertEqual((await asyncio.wait_for(resumed, 1)).result, {"attached": True})
        for _ in range(10):
            await asyncio.sleep(0)
            if backend._recovery_barrier is None or client.info_count:
                break

    async def test_suspend_resume_keeps_execution_and_reader_ownership(self):
        backend, client = await self._connected(deadline=1)
        events, completed = [], asyncio.get_running_loop().create_future()
        backend.start("execute", {"code": "side_effect()"}, events.append, completed.set_result)
        await asyncio.sleep(0)
        old_pending = backend._pending["execute-1"]
        old_readers = set(backend._readers)
        _token, suspended = await self._request(backend, "suspend")
        self.assertEqual((await suspended).result, {"suspended": True})
        self.assertIs(backend._pending["execute-1"], old_pending)
        self.assertEqual(backend._readers, old_readers)
        self.assertFalse(completed.done())
        await self._resume_recovery(backend, client)
        self.assertFalse(completed.done())
        for channel, kind, data in (
            ("iopub", "stream", {"name": "stdout", "text": "after reconnect"}),
            ("shell", "execute_reply", {"status": "ok", "execution_count": 1}),
            ("iopub", "status", {"execution_state": "idle"}),
        ):
            await self.queues[channel].put(self._message("execute-1", kind, data))
        self.assertEqual((await asyncio.wait_for(completed, 1)).result["status"], "ok")
        self.assertIn("after reconnect", "".join(e.data.get("text", "") for e in events))
        self.assertEqual(client.execute_codes, ["side_effect()"])
        self.assertIsNone(backend._recovery_barrier)
        self.assertEqual(backend._pending, {})

    async def test_recovery_barrier_resolves_offline_completion_without_replay(self):
        backend, client = await self._connected(deadline=1)
        events, completed = [], asyncio.get_running_loop().create_future()
        backend.start("execute", {"code": "side_effect()"}, events.append, completed.set_result)
        await asyncio.sleep(0)
        backend._suspend()
        await self._resume_recovery(backend, client)
        probe = f"kernel-info-{client.info_count}"
        await self.queues["shell"].put(self._message(probe, "kernel_info_reply", {"status": "ok"}))
        await asyncio.sleep(0)
        self.assertFalse(completed.done())
        await self.queues["iopub"].put(self._message(probe, "status", {"execution_state": "idle"}))
        self.assertEqual((await asyncio.wait_for(completed, 1)).result, {"status": "completed"})
        self.assertEqual([(e.name, dict(e.data)) for e in events], [
            ("execute_reply", {"status": "completed"}),
            ("status", {"execution_state": "idle"}),
        ])
        self.assertEqual(client.execute_codes, ["side_effect()"])
        self.assertEqual(backend._pending, {})

    async def test_recovery_barrier_preserves_an_observed_error_reply(self):
        backend, client = await self._connected(deadline=1)
        _token, execution = await self._request(backend, "execute")
        reply = {"status": "error", "ename": "ValueError", "execution_count": 8}
        backend._route("shell", self._message("execute-1", "execute_reply", reply))
        backend._suspend()
        await self._resume_recovery(backend, client)
        probe = f"kernel-info-{client.info_count}"
        backend._route("iopub", self._message(probe, "status", {"execution_state": "idle"}))
        backend._route("shell", self._message(probe, "kernel_info_reply", {"status": "ok"}))
        self.assertEqual((await asyncio.wait_for(execution, 1)).result, reply)

    async def test_second_outage_cancels_barrier_and_ignores_old_probe(self):
        backend, client = await self._connected(deadline=1)
        token, execution = await self._request(backend, "execute")
        backend._suspend()
        await self._resume_recovery(backend, client)
        probe = f"kernel-info-{client.info_count}"
        barrier = backend._recovery_barrier
        backend._suspend()
        await asyncio.sleep(0)
        self.assertTrue(barrier.done())
        self.assertEqual(set(backend._pending), {"execute-1"})
        backend._route("shell", self._message(probe, "kernel_info_reply", {"status": "ok"}))
        backend._route("iopub", self._message(probe, "status", {"execution_state": "idle"}))
        self.assertFalse(execution.done())
        token.cancel()
        await asyncio.sleep(0)
        self.assertEqual(backend._pending, {})
        self.assertEqual(client.execute_codes, ["x"])

    async def test_resume_timeout_retains_work_and_close_reaps_recovery(self):
        backend, client = await self._connected(deadline=0.1)
        _token, execution = await self._request(backend, "execute")
        backend._suspend()
        _token, resumed = await self._request(backend, "resume")
        self.assertEqual((await asyncio.wait_for(resumed, 1)).error.code, "timeout")
        self.assertTrue(backend._suspended)
        self.assertFalse(execution.done())
        self.assertEqual(set(backend._pending), {"execute-1"})
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 1)
        self.assertFalse(backend._tasks)
        self.assertFalse(backend._pending)
        self.assertIsNone(backend._recovery_barrier)
        self.assertEqual(client.stopped, 1)
        self.assertTrue(all(kind == "kernel_info_request" for _id, kind, _data in client.sent))

    async def test_resume_retries_a_lost_subscription_probe_without_leaking_waiters(self):
        backend, client = await self._connected(deadline=0.3)
        backend._suspend()
        _token, resumed = await self._request(backend, "resume")
        for _ in range(30):
            if len(client.sent) >= 2:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(len(client.sent), 2)
        first, second = (record[0] for record in client.sent)
        self.assertNotIn(first, backend._pending)
        self.assertEqual(set(backend._pending), {second})
        backend._route("control", self._message(first, "kernel_info_reply", {}))
        backend._route("iopub", self._message(first, "status", {"execution_state": "idle"}))
        self.assertFalse(resumed.done())
        backend._route("control", self._message(second, "kernel_info_reply", {}))
        backend._route("iopub", self._message(second, "status", {"execution_state": "idle"}))
        self.assertEqual((await asyncio.wait_for(resumed, 1)).result, {"attached": True})
        self.assertFalse(backend._pending)
        self.assertFalse(backend._pending_by_task)

    async def test_fatal_reader_failure_while_suspended_still_retires_execution(self):
        backend, client = await self._connected(deadline=1)
        _token, execution = await self._request(backend, "execute")
        origins = []
        backend.set_transport_failure_callback(origins.append)
        backend._suspend()
        backend._fail_transport("channel-reader")
        self.assertEqual((await asyncio.wait_for(execution, 1)).error.code, "transport-error")
        self.assertEqual(origins, ["channel-reader"])
        self.assertIsNone(backend.client)
        self.assertEqual(client.stopped, 1)

    async def test_shutdown_terminal_heartbeat_does_not_start_recovery(self):
        backend, _client = await self._connected(deadline=1)
        origins = []
        backend.set_transport_failure_callback(origins.append)
        backend._shutting_down = True
        backend._shutdown_reply_received = True
        backend._fail_transport("heartbeat")
        self.assertEqual(origins, [])
        self.assertFalse(backend._suspended)

    async def test_resume_requires_suspension_before_sending_any_probe(self):
        backend, client = await self._connected(deadline=1)
        _token, execution = await self._request(backend, "execute")
        _token, resumed = await self._request(backend, "resume")
        self.assertEqual((await asyncio.wait_for(resumed, 1)).error.code, "busy")
        self.assertFalse(execution.done())
        self.assertFalse(backend._suspended)
        self.assertEqual(client.sent, [])
        self.assertEqual(client.info_count, 0)

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
        observed = []
        backend.set_transport_failure_callback(observed.append)
        client.send_error = OSError("send failed")
        _token, sent = await self._request(backend, "shutdown")
        self.assertEqual((await asyncio.wait_for(sent, 1)).error.code, "transport-error")
        self.assertEqual(observed, ["channel-send"])
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
