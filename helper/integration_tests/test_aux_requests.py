import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend, MAX_COMPLETION_MATCHES, MAX_DOCUMENTATION_BYTES
from kernel_fixture import LocalKernelFixture


class AuxiliaryIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_auxiliary_requests_against_local_kernel(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifact_dir = Path(directory) / "artifacts"
                artifact_dir.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=8)
                completions = {}

                async def request(operation, params):
                    future = asyncio.get_running_loop().create_future()
                    backend.start(operation, params, lambda _event: None, future.set_result)
                    result = await future
                    completions[operation] = result
                    return result

                try:
                    connected = await request("connect", {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir)})
                    self.assertIsNone(connected.error)
                    info = await request("kernel_info", {})
                    self.assertIsNone(info.error)
                    self.assertEqual(info.result["language_info"]["name"], "python")
                    complete = await request("complete", {"code": "pri", "cursor_pos": 3})
                    self.assertIsNone(complete.error)
                    self.assertIn("print", complete.result["matches"])
                    inspect = await request("inspect", {"code": "print", "cursor_pos": 5})
                    self.assertIsNone(inspect.error)
                    self.assertIs(inspect.result["found"], True)
                    complete_state = await request("is_complete", {"code": "x = 1"})
                    self.assertIsNone(complete_state.error)
                    self.assertEqual(complete_state.result["status"], "complete")

                    # Both requests are dispatched independently; a busy kernel
                    # may legitimately defer the auxiliary reply until execution.
                    execution = asyncio.create_task(request("execute", {"code": "import time; time.sleep(0.25)"}))
                    await asyncio.sleep(0.03)
                    aux = await request("is_complete", {"code": "x = 2"})
                    self.assertIsNone(aux.error)
                    self.assertIn(aux.result["status"], {"complete", "incomplete"})
                    self.assertIsNone((await execution).error)
                finally:
                    backend.close()
                    await backend.wait_closed()
                    self.assertEqual(backend._pending, {})
                    self.assertEqual(backend._readers, set())

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_local_kernel_auxiliary_payloads_remain_bounded(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifact_dir = Path(directory) / "artifacts"
                artifact_dir.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=8)
                try:
                    loop = asyncio.get_running_loop()
                    connected = loop.create_future()
                    backend.start("connect", {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir)}, lambda _e: None, connected.set_result)
                    self.assertIsNone((await connected).error)
                    future = loop.create_future()
                    backend.start("inspect", {"code": "print", "cursor_pos": 5}, lambda _e: None, future.set_result)
                    result = await future
                    self.assertIsNone(result.error)
                    for value in result.result.get("data", {}).values():
                        self.assertLessEqual(len(value.encode()), MAX_DOCUMENTATION_BYTES)
                    future = loop.create_future()
                    backend.start("complete", {"code": "pri", "cursor_pos": 3}, lambda _e: None, future.set_result)
                    result = await future
                    self.assertLessEqual(len(result.result["matches"]), MAX_COMPLETION_MATCHES)
                finally:
                    backend.close()
                    await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
