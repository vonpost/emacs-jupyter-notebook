import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import (
    MAX_COMPLETION_MATCHES,
    MAX_DOCUMENTATION_BYTES,
    JupyterBackend,
)
from ejn_helper.dispatcher import EJN_MAX_RESPONSE_FRAME
from ejn_helper.framing import encode


class AuxiliaryRequestTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.queues = {name: asyncio.Queue() for name in ("shell", "iopub", "stdin", "control")}
        outer = self

        class Client:
            sequence = 0

            def load_connection_info(self, _info):
                pass

            def start_channels(self):
                pass

            def stop_channels(self):
                pass

            async def wait_for_ready(self):
                return None

            def is_alive(self):
                return True

            @classmethod
            def _id(cls, prefix):
                cls.sequence += 1
                return f"{prefix}-{cls.sequence}"

            def kernel_info(self): return self._id("info")
            def complete(self, _code, _cursor): return self._id("complete")
            def inspect(self, _code, _cursor, _detail=0): return self._id("inspect")
            def is_complete(self, _code): return self._id("is-complete")
            def execute(self, _code): return self._id("execute")

        for name in self.queues:
            async def getter(self, timeout, name=name):
                return await outer.queues[name].get()
            setattr(Client, f"get_{name}_msg", getter)
        self.old_module = sys.modules.get("jupyter_client")
        sys.modules["jupyter_client"] = types.SimpleNamespace(AsyncKernelClient=Client)
        self.tempdir = tempfile.TemporaryDirectory()
        path = Path(self.tempdir.name) / "connection.json"
        path.write_text(json.dumps({
            "ip": "127.0.0.1", "transport": "tcp", "key": "x",
            "signature_scheme": "hmac-sha256", "shell_port": 1,
            "iopub_port": 2, "stdin_port": 3, "control_port": 4, "hb_port": 5,
        }))
        artifact_dir = Path(self.tempdir.name) / "artifacts"
        artifact_dir.mkdir(mode=0o700)
        self.backend = JupyterBackend(deadline=0.1)
        self.connected = asyncio.get_running_loop().create_future()
        self.backend.start("connect", {"connection_file": str(path), "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304}, lambda _e: None, self.connected.set_result)
        await asyncio.wait_for(self.connected, 1)

    async def asyncTearDown(self):
        self.backend.close()
        await self.backend.wait_closed()
        if self.old_module is None:
            sys.modules.pop("jupyter_client", None)
        else:
            sys.modules["jupyter_client"] = self.old_module
        self.tempdir.cleanup()

    async def _request(self, operation, params):
        future = asyncio.get_running_loop().create_future()
        self.backend.start(operation, params, lambda _e: None, future.set_result)
        await asyncio.sleep(0)
        return future

    async def _request_id(self, operation):
        await asyncio.sleep(0)
        return next(key for key, pending in self.backend._pending.items() if pending.auxiliary == operation)

    @staticmethod
    def _message(message_id, message_type, content):
        return {"parent_header": {"msg_id": message_id}, "msg_type": message_type, "content": content}

    async def test_each_auxiliary_operation_success(self):
        cases = [
            ("kernel_info", {}, "kernel_info_reply", {"language": "python"}),
            ("complete", {"code": "pri", "cursor_pos": 3}, "complete_reply", {"matches": ["print"], "cursor_start": 0, "cursor_end": 3, "status": "ok"}),
            ("inspect", {"code": "print", "cursor_pos": 5}, "inspect_reply", {"found": True, "data": {"text/plain": "help"}, "metadata": {}}),
            ("is_complete", {"code": "x = 1"}, "is_complete_reply", {"status": "complete", "indent": ""}),
        ]
        for operation, params, msg_type, content in cases:
            future = await self._request(operation, params)
            msg_id = await self._request_id(operation)
            await self.queues["shell"].put(self._message(msg_id, msg_type, content))
            result = await asyncio.wait_for(future, 1)
            self.assertIsNone(result.error)
            self.assertEqual(result.result, content)

    async def test_timeout_discards_late_reply(self):
        future = await self._request("complete", {"code": "x", "cursor_pos": 1})
        msg_id = await self._request_id("complete")
        result = await asyncio.wait_for(future, 1)
        self.assertEqual(result.error.code, "timeout")
        await self.queues["shell"].put(self._message(msg_id, "complete_reply", {
            "matches": ["late"], "cursor_start": 0, "cursor_end": 1,
        }))
        await asyncio.sleep(0)
        self.assertEqual(self.backend._pending, {})

    async def test_malformed_replies_fail_without_leaking_data(self):
        cases = [
            ("complete", {"code": "x", "cursor_pos": 1}, "complete_reply", {"matches": "bad"}),
            ("inspect", {"code": "x", "cursor_pos": 1}, "inspect_reply", {"found": "yes"}),
            ("is_complete", {"code": "x"}, "is_complete_reply", {"status": "bad"}),
        ]
        for operation, params, msg_type, content in cases:
            future = await self._request(operation, params)
            msg_id = await self._request_id(operation)
            await self.queues["shell"].put(self._message(msg_id, msg_type, content))
            result = await asyncio.wait_for(future, 1)
            self.assertEqual(result.error.code, "protocol-error")

    async def test_invalid_cursor_status_and_nonfinite_nested_data(self):
        future = await self._request("complete", {"code": "x", "cursor_pos": 1})
        msg_id = await self._request_id("complete")
        await self.queues["shell"].put(self._message(msg_id, "complete_reply", {
            "matches": [], "cursor_start": 1_000_000, "cursor_end": 1, "status": "ok",
        }))
        self.assertEqual((await future).error.code, "protocol-error")
        future = await self._request("kernel_info", {})
        msg_id = await self._request_id("kernel_info")
        await self.queues["shell"].put(self._message(msg_id, "kernel_info_reply", {
            "language_info": {"version": float("inf")},
        }))
        self.assertEqual((await future).error.code, "protocol-error")

    async def test_completion_and_documentation_are_bounded(self):
        complete = await self._request("complete", {"code": "x", "cursor_pos": 1})
        msg_id = await self._request_id("complete")
        await self.queues["shell"].put(self._message(msg_id, "complete_reply", {
            "matches": ["x"] * (MAX_COMPLETION_MATCHES + 100), "cursor_start": 0, "cursor_end": 1,
        }))
        result = await complete
        self.assertEqual(len(result.result["matches"]), MAX_COMPLETION_MATCHES)
        inspect = await self._request("inspect", {"code": "x", "cursor_pos": 1})
        msg_id = await self._request_id("inspect")
        await self.queues["shell"].put(self._message(msg_id, "inspect_reply", {
            "found": True, "data": {"text/plain": "d" * (MAX_DOCUMENTATION_BYTES * 2)},
        }))
        result = await inspect
        self.assertLessEqual(len(result.result["data"]["text/plain"].encode()), MAX_DOCUMENTATION_BYTES)

    async def test_nested_kernel_info_and_worst_case_aux_response_fit_frame(self):
        info = await self._request("kernel_info", {})
        msg_id = await self._request_id("kernel_info")
        await self.queues["shell"].put(self._message(msg_id, "kernel_info_reply", {
            "language_info": {"name": "python", "version": "3.13", "mimes": ["x"]},
            "help_links": [{"text": "docs", "url": "https://example.test"}],
        }))
        info_result = await info
        self.assertEqual(info_result.result["language_info"]["name"], "python")
        self.assertEqual(info_result.result["help_links"][0]["text"], "docs")

        request = await self._request("complete", {"code": "x", "cursor_pos": 1})
        msg_id = await self._request_id("complete")
        await self.queues["shell"].put(self._message(msg_id, "complete_reply", {
            "matches": ["\x00\"\\" * 1400] * (MAX_COMPLETION_MATCHES + 20),
            "cursor_start": 0, "cursor_end": 1, "status": "ok",
            "metadata": {"x": "\x01" * MAX_DOCUMENTATION_BYTES},
        }))
        completion = await request
        self.assertTrue(completion.result["_ejn_truncated"])
        self.assertLess(
            len(encode({"v": 1, "kind": "response", "id": "worst", "ok": True,
                        "result": completion.result}, EJN_MAX_RESPONSE_FRAME)),
            EJN_MAX_RESPONSE_FRAME,
        )

        structural = await self._request("kernel_info", {})
        msg_id = await self._request_id("kernel_info")
        await self.queues["shell"].put(self._message(msg_id, "kernel_info_reply", {
            "tree": [[[True] * 128 for _ in range(128)] for _ in range(4)],
        }))
        structural_result = await structural
        self.assertTrue(structural_result.result["_ejn_truncated"])
        self.assertLess(
            len(encode({"v": 1, "kind": "response", "id": "structure",
                        "ok": True, "result": structural_result.result},
                       EJN_MAX_RESPONSE_FRAME)),
            EJN_MAX_RESPONSE_FRAME,
        )

    async def test_timeout_does_not_block_concurrent_auxiliary(self):
        timed = await self._request("complete", {"code": "x", "cursor_pos": 1})
        successful = await self._request("is_complete", {"code": "x"})
        success_id = await self._request_id("is_complete")
        await self.queues["shell"].put(self._message(success_id, "is_complete_reply", {"status": "complete"}))
        self.assertIsNone((await successful).error)
        self.assertEqual((await timed).error.code, "timeout")

    async def test_auxiliary_requests_are_concurrent_and_do_not_block_execution(self):
        first = await self._request("complete", {"code": "x", "cursor_pos": 1})
        second = await self._request("inspect", {"code": "x", "cursor_pos": 1})
        execution = await self._request("execute", {"code": "x"})
        inspect_id = await self._request_id("inspect")
        complete_id = await self._request_id("complete")
        execute_id = next(key for key, pending in self.backend._pending.items() if pending.state is not None)
        await self.queues["shell"].put(self._message(inspect_id, "inspect_reply", {"found": True, "data": {}}))
        await self.queues["shell"].put(self._message(execute_id, "execute_reply", {"status": "ok"}))
        await self.queues["iopub"].put(self._message(execute_id, "status", {"execution_state": "idle"}))
        await self.queues["shell"].put(self._message(complete_id, "complete_reply", {"matches": [], "cursor_start": 0, "cursor_end": 1}))
        self.assertIsNone((await first).error)
        self.assertIsNone((await second).error)
        self.assertIsNone((await execution).error)


if __name__ == "__main__":
    unittest.main()
