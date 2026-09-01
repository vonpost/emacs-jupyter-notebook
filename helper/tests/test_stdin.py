import asyncio
import json
import logging
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from ejn_helper.backend import BackendCompletion, BackendEvent
from ejn_helper.dispatcher import Dispatcher
from ejn_helper.jupyter_backend import JupyterBackend, _normalize_input_request
from ejn_helper.flow import EventQueue
from helper.tests.fake_backend import FakeBackend, FakePlan


TOKEN_A = "a" * 32
TOKEN_B = "b" * 32


def request(request_id, operation, params):
    return {
        "v": 1,
        "kind": "request",
        "id": request_id,
        "op": operation,
        "params": params,
    }


def contains(value, needle):
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(contains(item, needle) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(contains(item, needle) for item in value)
    return False


class DispatcherInputTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.loop = asyncio.get_running_loop()
        self.responses = []
        self.backend = FakeBackend(self.loop)
        self.dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            loop=self.loop,
            event_queue=EventQueue(),
        )
        self.dispatcher.negotiated = True
        self.dispatcher.connected = True
        self.backend.queue_plan("execute", FakePlan(delay=10))
        self.dispatcher.dispatch(request("exec", "execute", {"code": "x"}))
        self.record = self.dispatcher._inflight["exec"]

    def prompt(self, input_id):
        return self.dispatcher._backend_event(
            "exec",
            self.record,
            BackendEvent(
                "input_request",
                {
                    "input_id": input_id,
                    "prompt": "Name: ",
                    "password": False,
                },
            ),
        )

    async def test_claims_one_reply_and_rejects_duplicate_or_wrong_execution(self):
        self.assertTrue(self.prompt(TOKEN_A))
        params = {"request_id": "exec", "input_id": TOKEN_A, "value": "one"}
        self.dispatcher.dispatch(request("reply-a", "input_reply", params))
        await asyncio.sleep(0)
        self.assertEqual(
            [item.operation for item in self.backend.starts],
            ["execute", "input_reply"],
        )
        self.assertTrue(self.responses[-1]["ok"])
        self.dispatcher.dispatch(request("repeat-a", "input_reply", params))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(
            request(
                "wrong-exec", "input_reply", {**params, "request_id": "other"}
            )
        )
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")

    async def test_later_prompt_has_new_token_and_old_duplicate_cannot_answer_it(self):
        self.assertTrue(self.prompt(TOKEN_A))
        self.dispatcher.dispatch(
            request(
                "reply-a",
                "input_reply",
                {"request_id": "exec", "input_id": TOKEN_A, "value": "one"},
            )
        )
        await asyncio.sleep(0)
        self.assertTrue(self.prompt(TOKEN_B))
        self.dispatcher.dispatch(
            request(
                "stale-a",
                "input_reply",
                {"request_id": "exec", "input_id": TOKEN_A, "value": "bad"},
            )
        )
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(
            request(
                "reply-b",
                "input_reply",
                {"request_id": "exec", "input_id": TOKEN_B, "value": "two"},
            )
        )
        await asyncio.sleep(0)
        self.assertEqual(
            [item.operation for item in self.backend.starts],
            ["execute", "input_reply", "input_reply"],
        )

    async def test_invalid_bounds_and_terminal_close_retire_prompt_lease(self):
        invalid = [
            {"request_id": "exec", "input_id": "x", "value": "ok"},
            {"request_id": "exec", "input_id": TOKEN_A, "value": "€" * 21846},
            {"request_id": "exec", "input_id": TOKEN_A, "value": "\ud800"},
        ]
        for number, params in enumerate(invalid):
            self.dispatcher.dispatch(request(f"invalid-{number}", "input_reply", params))
            self.assertEqual(self.responses[-1]["error"]["code"], "invalid-request")
        self.assertTrue(self.prompt(TOKEN_A))
        self.dispatcher._backend_complete(
            "exec", self.record, BackendCompletion.success({"status": "ok"})
        )
        self.assertNotIn("exec", self.dispatcher._prompt_leases)
        self.dispatcher.dispatch(
            request(
                "late",
                "input_reply",
                {"request_id": "exec", "input_id": TOKEN_A, "value": "x"},
            )
        )
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(request("close", "close", {}))
        self.assertEqual(self.dispatcher._prompt_leases, {})

    async def test_deadline_retires_prompt_and_cancels_claimed_reply(self):
        self.assertTrue(self.prompt(TOKEN_A))
        self.backend.queue_plan(
            "input_reply", FakePlan(delay=10, ignore_cancellation=True)
        )
        self.dispatcher.dispatch(
            request(
                "reply",
                "input_reply",
                {"request_id": "exec", "input_id": TOKEN_A, "value": "x"},
            )
        )
        self.assertIn("reply", self.dispatcher._inflight)
        self.dispatcher._deadline("exec")
        self.assertNotIn("exec", self.dispatcher._prompt_leases)
        self.assertNotIn("reply", self.dispatcher._inflight)
        self.assertEqual(
            next(item for item in self.responses if item["id"] == "reply")[
                "error"
            ]["code"],
            "busy",
        )

    async def test_backend_start_failure_consumes_ambiguous_reply(self):
        self.assertTrue(self.prompt(TOKEN_A))
        self.backend.queue_plan(
            "input_reply", FakePlan(raise_on_start=RuntimeError("ambiguous"))
        )
        params = {"request_id": "exec", "input_id": TOKEN_A, "value": "one"}
        self.dispatcher.dispatch(request("reply-a", "input_reply", params))
        self.assertEqual(self.responses[-1]["error"]["code"], "transport-error")
        self.dispatcher.dispatch(request("retry-a", "input_reply", params))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.assertEqual(
            [item.operation for item in self.backend.starts],
            ["execute", "input_reply"],
        )

    async def test_pre_admission_capacity_failure_does_not_claim_prompt(self):
        self.assertTrue(self.prompt(TOKEN_A))
        self.dispatcher.max_inflight = 1
        params = {"request_id": "exec", "input_id": TOKEN_A, "value": "one"}
        self.dispatcher.dispatch(request("blocked", "input_reply", params))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.assertIsNone(self.dispatcher._prompt_leases["exec"].reply_request_id)
        self.dispatcher.max_inflight = 2
        self.dispatcher.dispatch(request("retry", "input_reply", params))
        await asyncio.sleep(0)
        self.assertTrue(self.responses[-1]["ok"])
        self.assertEqual(
            [item.operation for item in self.backend.starts],
            ["execute", "input_reply"],
        )


class BackendInputTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.queues = {
            name: asyncio.Queue()
            for name in ("shell", "iopub", "stdin", "control")
        }
        self.inputs = []
        self.fail_input = False
        outer = self

        class Client:
            def load_connection_info(self, _info):
                pass

            def start_channels(self):
                pass

            def stop_channels(self):
                pass

            async def wait_for_ready(self):
                pass

            def is_alive(self):
                return True

            def execute(self, _code):
                return "exec-1"

            def input(self, value):
                if outer.fail_input:
                    raise RuntimeError("send failed")
                outer.inputs.append(value)

        for name in self.queues:

            async def getter(self, timeout, name=name):
                return await outer.queues[name].get()

            setattr(Client, f"get_{name}_msg", getter)
        self.old_client = sys.modules.get("jupyter_client")
        sys.modules["jupyter_client"] = types.SimpleNamespace(AsyncKernelClient=Client)
        self.addCleanup(self._restore_client)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def _restore_client(self):
        if self.old_client is None:
            sys.modules.pop("jupyter_client", None)
        else:
            sys.modules["jupyter_client"] = self.old_client

    async def backend(self):
        connection = Path(self.directory.name) / "connection.json"
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
            )
        )
        artifact = Path(self.directory.name) / "artifacts"
        artifact.mkdir(mode=0o700)
        backend = JupyterBackend(deadline=2)
        future = asyncio.get_running_loop().create_future()
        backend.start(
            "connect",
            {
                "connection_file": str(connection),
                "artifact_dir": str(artifact),
                "image_max_pixels": 4_194_304,
            },
            lambda _event: None,
            future.set_result,
        )
        self.assertIsNone((await asyncio.wait_for(future, 1)).error)
        self.addAsyncCleanup(self.close_backend, backend)
        return backend

    async def close_backend(self, backend):
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 1)

    @staticmethod
    def message(parent, message_type, content):
        return {
            "parent_header": {"msg_id": parent},
            "msg_type": message_type,
            "content": content,
        }

    async def start(self, backend, operation, params, events=None):
        future = asyncio.get_running_loop().create_future()
        event_callback = events.append if events is not None else lambda _event: None
        token = backend.start(
            operation, params, event_callback, future.set_result
        )
        await asyncio.sleep(0)
        return token, future

    async def reply(self, backend, input_id, value):
        _token, future = await self.start(
            backend, "input_reply", {"input_id": input_id, "value": value}
        )
        return await asyncio.wait_for(future, 1)

    async def test_normal_password_sequential_duplicate_and_secret_canary(self):
        backend = await self.backend()
        self.assertEqual(len(backend._readers), 5)
        events = []
        _token, execution = await self.start(
            backend, "execute", {"code": "x"}, events
        )
        secret = "sensitive-stdin-value"
        records = []
        handler = logging.Handler()
        handler.emit = lambda record: records.append(record.getMessage())
        logger = logging.getLogger("ejn_helper.jupyter_backend")
        logger.addHandler(handler)
        self.addCleanup(logger.removeHandler, handler)
        with patch(
            "ejn_helper.jupyter_backend.secrets.token_hex",
            side_effect=[TOKEN_A, TOKEN_B],
        ):
            await self.queues["stdin"].put(
                self.message(
                    "exec-1",
                    "input_request",
                    {"prompt": "Name: ", "password": False},
                )
            )
            await self.queues["stdin"].put(
                self.message(
                    "exec-1",
                    "input_request",
                    {"prompt": "ignored", "password": True},
                )
            )
            for _ in range(4):
                await asyncio.sleep(0)
            self.assertEqual(len(events), 1)
            self.assertEqual(
                events[0].data,
                {
                    "input_id": TOKEN_A,
                    "prompt": "Name: ",
                    "password": False,
                },
            )
            first = await self.reply(backend, TOKEN_A, "one")
            self.assertEqual(first.result, {"accepted": True})
            duplicate = await self.reply(backend, TOKEN_A, "duplicate")
            self.assertEqual(getattr(duplicate.error, "code", None), "busy")
            await self.queues["stdin"].put(
                self.message(
                    "exec-1",
                    "input_request",
                    {"prompt": "Secret: ", "password": True},
                )
            )
            for _ in range(4):
                await asyncio.sleep(0)
            self.assertEqual(
                events[-1].data,
                {
                    "input_id": TOKEN_B,
                    "prompt": "Secret: ",
                    "password": True,
                },
            )
            second = await self.reply(backend, TOKEN_B, secret)
            self.assertEqual(second.result, {"accepted": True})
        self.assertEqual(self.inputs, ["one", secret])
        self.assertFalse(contains(events, secret))
        self.assertFalse(contains([first, second, records], secret))
        await self.queues["shell"].put(
            self.message("exec-1", "execute_reply", {"status": "ok"})
        )
        await self.queues["iopub"].put(
            self.message("exec-1", "status", {"execution_state": "idle"})
        )
        self.assertEqual(
            (await asyncio.wait_for(execution, 1)).result, {"status": "ok"}
        )
        self.assertFalse(backend._input_prompts)

    async def test_bounds_stale_parent_cancel_and_close_retire_without_send(self):
        prompt, password = _normalize_input_request(
            {"prompt": "€" * 2000, "password": 1}
        )
        self.assertLessEqual(len(prompt.encode()), 4096)
        self.assertFalse(password)
        self.assertEqual(
            _normalize_input_request({"prompt": "\ud800", "password": True}),
            ("", True),
        )
        backend = await self.backend()
        events = []
        token, execution = await self.start(backend, "execute", {"code": "x"}, events)
        with patch("ejn_helper.jupyter_backend.secrets.token_hex", return_value=TOKEN_A):
            await self.queues["stdin"].put(
                self.message("other", "input_request", {"prompt": "no"})
            )
            await self.queues["stdin"].put(
                self.message(
                    "exec-1",
                    "input_request",
                    {"prompt": "go", "password": True},
                )
            )
            for _ in range(4):
                await asyncio.sleep(0)
        self.assertEqual(len(events), 1)
        assert token is not None
        token.cancel()
        await asyncio.sleep(0)
        late = await self.reply(backend, TOKEN_A, "should-not-send")
        self.assertEqual(getattr(late.error, "code", None), "busy")
        self.assertEqual(self.inputs, [])
        self.assertFalse(backend._input_prompts)
        backend.close()
        await backend.wait_closed()
        self.assertFalse(backend._input_prompts)
        self.assertFalse(backend._tasks)
        self.assertFalse(backend._readers)
        self.assertFalse(execution.done())

    async def test_send_failure_consumes_prompt_and_fails_waiting_execution(self):
        backend = await self.backend()
        events = []
        _token, execution = await self.start(
            backend, "execute", {"code": "input()"}, events
        )
        with patch("ejn_helper.jupyter_backend.secrets.token_hex", return_value=TOKEN_A):
            await self.queues["stdin"].put(
                self.message("exec-1", "input_request", {"prompt": "Value: "})
            )
            for _ in range(4):
                await asyncio.sleep(0)
        self.fail_input = True
        reply = await self.reply(backend, TOKEN_A, "not-retained")
        self.assertEqual(getattr(reply.error, "code", None), "transport-error")
        completion = await asyncio.wait_for(execution, 1)
        self.assertEqual(getattr(completion.error, "code", None), "transport-error")
        self.assertTrue(backend._transport_failed)
        self.assertFalse(backend._input_prompts)
        self.assertEqual(self.inputs, [])

    async def test_input_id_collision_is_retried_before_prompt_publication(self):
        backend = await self.backend()
        backend._input_prompts[TOKEN_A] = types.SimpleNamespace()
        events = []
        token, _execution = await self.start(
            backend, "execute", {"code": "input()"}, events
        )
        with patch(
            "ejn_helper.jupyter_backend.secrets.token_hex",
            side_effect=[TOKEN_A, TOKEN_B],
        ) as token_hex:
            await self.queues["stdin"].put(
                self.message("exec-1", "input_request", {"prompt": "Value: "})
            )
            for _ in range(4):
                await asyncio.sleep(0)
        self.assertEqual(token_hex.call_count, 2)
        self.assertEqual(events[0].data["input_id"], TOKEN_B)
        self.assertNotEqual(events[0].data["input_id"], TOKEN_A)
        assert token is not None
        token.cancel()


if __name__ == "__main__":
    unittest.main()
