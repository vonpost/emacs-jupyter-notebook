import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from queue import Empty

from ejn_helper.requests import ExecutionState
from ejn_helper.jupyter_backend import JupyterBackend


class ExecutionStateTests(unittest.TestCase):
    def test_busy_is_correlated_once_and_cannot_follow_idle(self):
        state = ExecutionState("jupyter")
        busy = {
            "parent_header": {"msg_id": "jupyter"},
            "msg_type": "status",
            "content": {"execution_state": "busy"},
        }
        idle = {
            "parent_header": {"msg_id": "jupyter"},
            "msg_type": "status",
            "content": {"execution_state": "idle"},
        }
        self.assertTrue(state.accept_iopub(busy))
        self.assertFalse(state.accept_iopub(busy))
        self.assertTrue(state.accept_iopub(idle))
        self.assertFalse(state.accept_iopub(busy))

    def test_reply_idle_any_order_duplicate_and_unrelated(self):
        state = ExecutionState("jupyter")
        unrelated = {"parent_header": {"msg_id": "other"}, "msg_type": "execute_reply", "content": {}}
        self.assertFalse(state.accept_shell(unrelated))
        reply = {"parent_header": {"msg_id": "jupyter"}, "msg_type": "execute_reply", "content": {"status": "ok"}}
        idle = {"parent_header": {"msg_id": "jupyter"}, "msg_type": "status", "content": {"execution_state": "idle"}}
        self.assertTrue(state.accept_iopub(idle)); self.assertIsNone(state.complete())
        self.assertTrue(state.accept_shell(reply)); self.assertEqual(state.complete(), {"status": "ok"})
        self.assertFalse(state.accept_shell(reply)); self.assertIsNone(state.complete())

    def test_reply_before_idle(self):
        state = ExecutionState("jupyter")
        self.assertTrue(state.accept_shell({"parent_header": {"msg_id": "jupyter"}, "msg_type": "execute_reply", "content": {}}))
        self.assertIsNone(state.complete())
        self.assertTrue(state.accept_iopub({"parent_header": {"msg_id": "jupyter"}, "msg_type": "status", "content": {"execution_state": "idle"}}))
        self.assertEqual(state.complete(), {})

    def test_two_parents_reverse_order_and_unrelated_messages(self):
        first, second = ExecutionState("one"), ExecutionState("two")
        idle_one = {"parent_header": {"msg_id": "one"}, "msg_type": "status", "content": {"execution_state": "idle"}}
        reply_one = {"parent_header": {"msg_id": "one"}, "msg_type": "execute_reply", "content": {"status": "ok", "n": 1}}
        idle_two = {"parent_header": {"msg_id": "two"}, "msg_type": "status", "content": {"execution_state": "idle"}}
        reply_two = {"parent_header": {"msg_id": "two"}, "msg_type": "execute_reply", "content": {"status": "ok", "n": 2}}
        unrelated = {"parent_header": {"msg_id": "other"}, "msg_type": "status", "content": {"execution_state": "idle"}}
        self.assertFalse(first.accept_iopub(unrelated))
        self.assertTrue(second.accept_shell(reply_two))
        self.assertTrue(first.accept_iopub(idle_one))
        self.assertFalse(first.accept_iopub(idle_one))
        self.assertTrue(second.accept_iopub(idle_two))
        self.assertEqual(second.complete(), {"status": "ok", "n": 2})
        self.assertTrue(first.accept_shell(reply_one))
        self.assertEqual(first.complete(), {"status": "ok", "n": 1})
        self.assertFalse(first.accept_iopub(idle_one))
        self.assertFalse(second.accept_shell(reply_two))


class BackendReaderTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.queues = {
            name: asyncio.Queue() for name in ("shell", "iopub", "stdin", "control")
        }
        self.active = {name: 0 for name in self.queues}
        self.maximum = dict(self.active)
        self.clients = []

        outer = self

        class Client:
            def __init__(self):
                self.stopped = 0
                self.alive = True
                self.never_alive = False
                self.kernel_info_count = 0
                self.execute_count = 0
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
                if self.never_alive:
                    return self._never_alive()
                return self.alive

            async def _never_alive(self):
                await asyncio.Event().wait()

            def kernel_info(self):
                self.kernel_info_count += 1
                return f"info-{self.kernel_info_count}"

            def execute(self, _code):
                self.execute_count += 1
                return f"exec-{self.execute_count}"

        for name in self.queues:
            async def getter(self, timeout, name=name):
                outer.active[name] += 1
                outer.maximum[name] = max(outer.maximum[name], outer.active[name])
                try:
                    item = await outer.queues[name].get()
                    if isinstance(item, BaseException):
                        raise item
                    return item
                finally:
                    outer.active[name] -= 1

            setattr(Client, f"get_{name}_msg", getter)

        self._old_jupyter_client = sys.modules.get("jupyter_client")
        sys.modules["jupyter_client"] = types.SimpleNamespace(AsyncKernelClient=Client)
        self.addCleanup(self._restore_jupyter_client)
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)

    def _restore_jupyter_client(self):
        if self._old_jupyter_client is None:
            sys.modules.pop("jupyter_client", None)
        else:
            sys.modules["jupyter_client"] = self._old_jupyter_client

    async def _backend(self):
        path = Path(self._directory.name) / "connection.json"
        path.write_text(
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
            )
        )
        self.connection_path = path
        artifact_dir = Path(self._directory.name) / "artifacts"
        artifact_dir.mkdir(mode=0o700, exist_ok=True)
        backend = JupyterBackend(deadline=0.2)
        future = asyncio.get_running_loop().create_future()
        backend.start(
            "connect",
            {"connection_file": str(path), "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304},
            lambda _event: None,
            future.set_result,
        )
        connected = await asyncio.wait_for(future, 1)
        self.assertIsNone(connected.error)
        self.addAsyncCleanup(self._close_backend, backend)
        return backend, self.clients[-1]

    async def _close_backend(self, backend):
        backend.close()
        await backend.wait_closed()

    @staticmethod
    def _message(message_id, message_type, content):
        return {
            "parent_header": {"msg_id": message_id},
            "msg_type": message_type,
            "content": content,
        }

    async def _start(self, backend, operation, params, events=None):
        future = asyncio.get_running_loop().create_future()
        token = backend.start(
            operation,
            params,
            (events.append if events is not None else lambda _event: None),
            future.set_result,
        )
        # Let the operation send and register its Jupyter message ID before a
        # fake channel is allowed to deliver its corresponding reply.
        await asyncio.sleep(0)
        return token, future

    async def test_one_reader_per_channel_reverse_replies_and_unrelated_messages(self):
        backend, _client = await self._backend()
        _info_token, info = await self._start(backend, "kernel_info", {})
        events = []
        _exec_token, execute = await self._start(backend, "execute", {"code": "x"}, events)
        await self.queues["iopub"].put(self._message("other", "stream", {}))
        await self.queues["shell"].put(self._message("exec-1", "execute_reply", {"status": "ok"}))
        await self.queues["shell"].put(self._message("info-1", "kernel_info_reply", {"language": "python"}))
        await self.queues["iopub"].put(self._message("exec-1", "status", {"execution_state": "idle"}))
        self.assertEqual((await asyncio.wait_for(info, 1)).result, {"language": "python"})
        self.assertEqual((await asyncio.wait_for(execute, 1)).result, {"status": "ok"})
        self.assertCountEqual(
            [event.name for event in events], ["execute_reply", "status"]
        )
        self.assertTrue(all(value == 1 for value in self.maximum.values()))

    async def test_duplicate_terminal_messages_and_callback_failure_are_isolated(self):
        backend, _client = await self._backend()
        completions = []
        future = asyncio.get_running_loop().create_future()

        def exploding_callback(_event):
            raise RuntimeError("consumer failure")

        backend.start("execute", {"code": "x"}, exploding_callback, completions.append)
        await self.queues["iopub"].put(self._message("exec-1", "status", {"execution_state": "idle"}))
        await self.queues["iopub"].put(self._message("exec-1", "status", {"execution_state": "idle"}))
        await self.queues["shell"].put(self._message("exec-1", "execute_reply", {"status": "ok"}))
        await self.queues["shell"].put(self._message("exec-1", "execute_reply", {"status": "ok"}))
        for _ in range(4):
            await asyncio.sleep(0)
            if completions:
                break
        self.assertEqual(len(completions), 1)
        self.assertEqual(completions[0].result, {"status": "ok"})
        self.assertFalse(backend._transport_failed)
        self.assertFalse(future.done())

    async def test_terminal_event_order_is_monotonic_in_both_channel_orders(self):
        backend, _client = await self._backend()
        events = []
        _token, completion = await self._start(backend, "execute", {"code": "x"}, events)
        await self.queues["shell"].put(
            self._message("exec-1", "execute_reply", {"status": "ok"})
        )
        await asyncio.sleep(0)
        self.assertEqual([event.name for event in events], ["execute_reply"])
        self.assertFalse(completion.done())
        await self.queues["shell"].put(
            self._message("exec-1", "execute_reply", {"status": "ok"})
        )
        await self.queues["iopub"].put(
            self._message("exec-1", "status", {"execution_state": "idle"})
        )
        await asyncio.sleep(0)
        await self.queues["iopub"].put(
            self._message("exec-1", "status", {"execution_state": "idle"})
        )
        self.assertEqual((await asyncio.wait_for(completion, 1)).result, {"status": "ok"})
        self.assertEqual([event.name for event in events], ["execute_reply", "status"])

        backend.close()
        await backend.wait_closed()
        backend, _client = await self._backend()
        events = []
        _token, completion = await self._start(backend, "execute", {"code": "x"}, events)
        await self.queues["iopub"].put(
            self._message("exec-1", "status", {"execution_state": "idle"})
        )
        await asyncio.sleep(0)
        self.assertEqual([event.name for event in events], ["status"])
        self.assertFalse(completion.done())
        await self.queues["iopub"].put(
            self._message("exec-1", "status", {"execution_state": "idle"})
        )
        await self.queues["shell"].put(
            self._message("exec-1", "execute_reply", {"status": "ok"})
        )
        await asyncio.sleep(0)
        await self.queues["shell"].put(
            self._message("exec-1", "execute_reply", {"status": "ok"})
        )
        self.assertEqual((await asyncio.wait_for(completion, 1)).result, {"status": "ok"})
        self.assertEqual([event.name for event in events], ["status", "execute_reply"])

    async def test_busy_status_is_correlated_once_without_completing_execution(self):
        backend, _client = await self._backend()
        events = []
        _token, completion = await self._start(backend, "execute", {"code": "x"}, events)
        busy = self._message("exec-1", "status", {"execution_state": "busy"})
        await self.queues["iopub"].put(busy)
        await self.queues["iopub"].put(busy)
        await asyncio.sleep(0)
        self.assertEqual(
            [(event.name, event.data) for event in events],
            [("status", {"execution_state": "busy"})],
        )
        self.assertFalse(completion.done())
        await self.queues["shell"].put(
            self._message("exec-1", "execute_reply", {"status": "ok"})
        )
        await self.queues["iopub"].put(
            self._message("exec-1", "status", {"execution_state": "idle"})
        )
        self.assertEqual((await asyncio.wait_for(completion, 1)).result, {"status": "ok"})
        self.assertEqual(
            [(event.name, event.data) for event in events],
            [
                ("status", {"execution_state": "busy"}),
                ("execute_reply", {"status": "ok"}),
                ("status", {"execution_state": "idle"}),
            ],
        )

    async def test_queue_empty_does_not_fail_readers_and_stdin_is_correlated(self):
        backend, _client = await self._backend()
        for queue in self.queues.values():
            await queue.put(Empty())
        events = []
        _token, completion = await self._start(backend, "execute", {"code": "x"}, events)
        await self.queues["stdin"].put(self._message("exec-1", "input_request", {"prompt": "value: "}))
        await self.queues["shell"].put(self._message("exec-1", "execute_reply", {"status": "ok"}))
        await self.queues["iopub"].put(self._message("exec-1", "status", {"execution_state": "idle"}))
        self.assertEqual((await asyncio.wait_for(completion, 1)).result, {"status": "ok"})
        self.assertEqual(
            [event.name for event in events],
            ["input_request", "execute_reply", "status"],
        )
        self.assertFalse(backend._transport_failed)

    async def test_channel_failure_finishes_each_pending_request_once(self):
        backend, _client = await self._backend()
        info_callbacks, execute_callbacks = [], []
        origins = []
        backend.set_transport_failure_callback(origins.append)
        backend.start("kernel_info", {}, lambda _event: None, info_callbacks.append)
        backend.start("execute", {"code": "x"}, lambda _event: None, execute_callbacks.append)
        await self.queues["iopub"].put(RuntimeError("channel failed"))
        for _ in range(8):
            await asyncio.sleep(0)
            if info_callbacks and execute_callbacks:
                break
        self.assertEqual(len(info_callbacks), 1)
        self.assertEqual(len(execute_callbacks), 1)
        self.assertEqual(getattr(info_callbacks[0].error, "code", None), "transport-error")
        self.assertEqual(getattr(execute_callbacks[0].error, "code", None), "transport-error")
        await asyncio.sleep(0)
        self.assertEqual(backend._pending, {})
        self.assertTrue(backend._transport_failed)
        self.assertEqual(origins, ["channel-reader"])

    async def test_cancelling_one_request_leaves_other_request_and_readers_live(self):
        backend, _client = await self._backend()
        info_token, info = await self._start(backend, "kernel_info", {})
        _execute_token, execute = await self._start(backend, "execute", {"code": "x"})
        assert info_token is not None
        info_token.cancel()
        self.assertNotIn("info-1", backend._pending)
        await asyncio.sleep(0)
        await self.queues["shell"].put(self._message("exec-1", "execute_reply", {"status": "ok"}))
        await self.queues["iopub"].put(self._message("exec-1", "status", {"execution_state": "idle"}))
        self.assertEqual((await asyncio.wait_for(execute, 1)).result, {"status": "ok"})
        self.assertFalse(info.done())
        self.assertFalse(backend._transport_failed)
        self.assertTrue(backend._readers)

    async def test_heartbeat_loss_preserves_channels_until_auxiliary_timeout(self):
        backend, client = await self._backend()
        callbacks = []
        backend.start("kernel_info", {}, lambda _event: None, callbacks.append)
        client.alive = False
        for _ in range(12):
            await asyncio.sleep(0.05)
            if callbacks:
                break
        self.assertEqual(len(callbacks), 1)
        self.assertEqual(getattr(callbacks[0].error, "code", None), "timeout")
        self.assertTrue(backend._suspended)
        self.assertIs(backend.client, client)
        backend.close()
        tasks = tuple(backend._retired_tasks)
        await asyncio.wait_for(backend.wait_closed(), 1)
        self.assertTrue(all(task.done() for task in tasks))
        self.assertEqual(backend._pending, {})
        self.assertFalse(backend._readers)
        self.assertFalse(backend._tasks)
        self.assertFalse(backend._timed_out_tasks)

    async def test_wait_closed_reaps_done_operation_without_done_callback_turn(self):
        """Joining completed tasks cannot depend on a call_soon callback turn."""
        backend, _client = await self._backend()

        async def already_done():
            return None

        task = asyncio.create_task(already_done())
        await task
        # Insert a completed operation directly, emulating the narrow window
        # after gather observes completion but before the normal discard done
        # callback gets to run.
        backend._tasks.add(task)
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 1)
        self.assertFalse(backend._tasks)
        self.assertFalse(backend._retired_tasks)

    async def test_awaitable_heartbeat_timeout_suspends_and_reaps_cleanly(self):
        backend, client = await self._backend()
        backend.operation_deadlines["kernel_info"] = 1.0
        callbacks = []
        backend.start("kernel_info", {}, lambda _event: None, callbacks.append)
        client.never_alive = True
        for _ in range(12):
            await asyncio.sleep(0.05)
            if backend._suspended:
                break
        self.assertEqual(callbacks, [])
        self.assertTrue(backend._suspended)
        self.assertIs(backend.client, client)
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 1)
        self.assertFalse(backend._pending)
        self.assertFalse(backend._retired_tasks)
        self.assertFalse(backend._readers)

    async def test_repeated_reader_failure_and_reattach_reaps_retired_tasks(self):
        backend, _client = await self._backend()
        for cycle in range(4):
            callbacks = []
            backend.start("kernel_info", {}, lambda _event: None, callbacks.append)
            await asyncio.sleep(0)
            await self.queues["iopub"].put(RuntimeError(f"channel failed {cycle}"))
            for _ in range(8):
                await asyncio.sleep(0)
                if callbacks:
                    break
            self.assertEqual(len(callbacks), 1)
            self.assertEqual(getattr(callbacks[0].error, "code", None), "transport-error")
            future = asyncio.get_running_loop().create_future()
            backend.start(
                "connect",
                {
                    "connection_file": str(self.connection_path),
                    "artifact_dir": str(
                        Path(self._directory.name) / "artifacts"
                    ),
                    "image_max_pixels": 4_194_304,
                },
                lambda _event: None,
                future.set_result,
            )
            self.assertIsNone((await asyncio.wait_for(future, 1)).error)
            await asyncio.sleep(0)
            self.assertEqual(backend._pending, {})
            self.assertEqual(backend._retired_tasks, [])
            self.assertEqual(len(backend._readers), 5)
