import asyncio
import unittest

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class ExecutionOrderTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_normal_error_and_no_output(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            backend = JupyterBackend(deadline=8)
            assert fixture.connection_path is not None
            loop = asyncio.get_running_loop()
            async def request(operation, params):
                future = loop.create_future(); events = []
                backend.start(operation, params, events.append, future.set_result)
                return await future, events
            connected, _ = await request("connect", {"connection_file": str(fixture.connection_path)})
            self.assertIsNone(connected.error)
            for code, status in (("1 + 1", "ok"), ("raise ValueError('x')", "error"), ("pass", "ok")):
                completion, events = await request("execute", {"code": code})
                self.assertEqual(completion.result.get("status"), status)
                self.assertEqual([event.name for event in events].count("execute_reply"), 1)
                self.assertEqual([event.name for event in events].count("status"), 1)
            backend.close()
            await backend.wait_closed()
            self.assertEqual(backend._tasks, set())
            self.assertEqual(backend._pending, {})
            self.assertEqual(backend._readers, set())

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_ten_fresh_immediate_executes(self):
        for cycle in range(10):
            with self.subTest(cycle=cycle), LocalKernelFixture(startup_timeout=10) as fixture:
                backend = JupyterBackend(deadline=8)
                future = asyncio.get_running_loop().create_future()
                backend.start("connect", {"connection_file": str(fixture.connection_path)}, lambda _event: None, future.set_result)
                self.assertIsNone((await future).error)
                future = asyncio.get_running_loop().create_future()
                backend.start("execute", {"code": "pass"}, lambda _event: None, future.set_result)
                completion = await future
                self.assertIsNone(completion.error)
                self.assertEqual(completion.result.get("status"), "ok")
                backend.close(); await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
