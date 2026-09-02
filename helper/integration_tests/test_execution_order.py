import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class ExecutionOrderTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_normal_error_and_no_output(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifact_dir = Path(directory) / "artifacts"
                artifact_dir.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=8)
                assert fixture.connection_path is not None
                loop = asyncio.get_running_loop()
                async def request(operation, params):
                    future = loop.create_future(); events = []
                    backend.start(operation, params, events.append, future.set_result)
                    return await future, events
                connected, _ = await request("connect", {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304})
                self.assertIsNone(connected.error)
                for code, status in (("1 + 1", "ok"), ("raise ValueError('x')", "error"), ("pass", "ok")):
                    completion, events = await request("execute", {"code": code})
                    self.assertEqual(completion.result.get("status"), status)
                    self.assertEqual([event.name for event in events].count("execute_reply"), 1)
                    self.assertEqual(
                        [
                            event.data.get("execution_state")
                            for event in events
                            if event.name == "status"
                        ],
                        ["busy", "idle"],
                    )
                backend.close()
                await backend.wait_closed()
                self.assertEqual(backend._tasks, set())
                self.assertEqual(backend._pending, {})
                self.assertEqual(backend._readers, set())

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_ten_fresh_immediate_executes(self):
        for cycle in range(10):
            with self.subTest(cycle=cycle), LocalKernelFixture(startup_timeout=10) as fixture:
                with tempfile.TemporaryDirectory() as directory:
                    artifact_dir = Path(directory) / "artifacts"
                    artifact_dir.mkdir(mode=0o700)
                    backend = JupyterBackend(deadline=8)
                    future = asyncio.get_running_loop().create_future()
                    backend.start("connect", {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304}, lambda _event: None, future.set_result)
                    self.assertIsNone((await future).error)
                    future = asyncio.get_running_loop().create_future()
                    backend.start("execute", {"code": "pass"}, lambda _event: None, future.set_result)
                    completion = await future
                    self.assertIsNone(completion.error)
                    self.assertEqual(completion.result.get("status"), "ok")
                    backend.close(); await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
