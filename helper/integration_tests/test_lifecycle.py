"""Direct-kernel lifecycle integration tests for the async helper backend."""

from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class DirectLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def _completion(self, backend, operation, params, events=None):
        future = asyncio.get_running_loop().create_future()
        backend.start(
            operation,
            params,
            (events.append if events is not None else lambda _event: True),
            future.set_result,
        )
        return await asyncio.wait_for(future, 12)

    async def _connect(self, fixture, artifact_dir: Path) -> JupyterBackend:
        assert fixture.connection_path is not None
        artifact_dir.mkdir(mode=0o700, exist_ok=True)
        backend = JupyterBackend(deadline=8)
        result = await self._completion(
            backend,
            "connect",
            {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304},
        )
        self.assertIsNone(result.error)
        self.addAsyncCleanup(self._retire, backend)
        return backend

    async def _retire(self, backend) -> None:
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 5)

    async def _wait_for_file(self, path: Path) -> None:
        deadline = asyncio.get_running_loop().time() + 8
        while not path.is_file():
            if asyncio.get_running_loop().time() >= deadline:
                self.fail("timed out waiting for the execution to become busy")
            await asyncio.sleep(0.05)

    @unittest.skipUnless(LocalKernelFixture.available(), "direct local kernel unavailable")
    async def test_close_is_local_only_and_interrupt_preserves_direct_kernel(self):
        with LocalKernelFixture(startup_timeout=12) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                backend = await self._connect(fixture, Path(directory) / "artifacts")
                events = []
                execute = asyncio.get_running_loop().create_future()
                marker = Path(directory) / "busy"
                backend.start(
                    "execute",
                    {
                        "code": (
                            "from pathlib import Path\nimport time\n"
                            f"Path({str(marker)!r}).write_text('busy')\n"
                            "time.sleep(30)"
                        )
                    },
                    events.append,
                    execute.set_result,
                )
                await asyncio.sleep(0)
                await self._wait_for_file(marker)
                interrupted = await self._completion(backend, "interrupt", {})
                self.assertEqual(interrupted.result, {"interrupted": True})
                finished = await asyncio.wait_for(execute, 8)
                self.assertIsNone(finished.error)
                next_execution = await self._completion(backend, "execute", {"code": "40 + 2"})
                self.assertEqual(next_execution.result.get("status"), "ok")
                assert fixture._process is not None
                pid = fixture.kernel_pid
                backend.close()
                await asyncio.wait_for(backend.wait_closed(), 5)
                self.assertEqual(fixture.kernel_pid, pid)
                self.assertIsNone(fixture._process.poll())
                self.assertEqual(fixture.evaluate("assert 40 + 2 == 42").get("status"), "ok")

    @unittest.skipUnless(LocalKernelFixture.available(), "direct local kernel unavailable")
    async def test_shutdown_idle_waits_for_reply_and_exact_direct_process_exit(self):
        with LocalKernelFixture(startup_timeout=12) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                backend = await self._connect(fixture, Path(directory) / "artifacts")
                assert fixture._process is not None and fixture.kernel_pid is not None
                process, pid = fixture._process, fixture.kernel_pid
                stopped = await self._completion(backend, "shutdown", {})
                self.assertEqual(stopped.result, {"shutdown": True})
                self.assertIsNone(stopped.error)
                self.assertEqual(await asyncio.to_thread(fixture.wait_exited, 8), 0)
                self.assertEqual(process.pid, pid)
                self.assertEqual(process.poll(), 0)
                self.assertEqual(backend._pending, {})
                self.assertEqual(backend._readers, set())
                self.assertEqual(backend._tasks, set())
                await self._retire(backend)

    @unittest.skipUnless(LocalKernelFixture.available(), "direct local kernel unavailable")
    async def test_shutdown_while_busy_and_stdin_retires_everything(self):
        for source, expect_stdin in (
            ("", False),
            ("input('value: ')", True),
        ):
            with self.subTest(expect_stdin=expect_stdin), LocalKernelFixture(startup_timeout=12) as fixture:
                with tempfile.TemporaryDirectory() as directory:
                    backend = await self._connect(fixture, Path(directory) / "artifacts")
                    events = []
                    completion = asyncio.get_running_loop().create_future()
                    marker = Path(directory) / "busy"
                    if not expect_stdin:
                        source = (
                            "from pathlib import Path\nimport time\n"
                            f"Path({str(marker)!r}).write_text('busy')\n"
                            "time.sleep(30)"
                        )
                    backend.start("execute", {"code": source}, events.append, completion.set_result)
                    await asyncio.sleep(0)
                    if expect_stdin:
                        deadline = asyncio.get_running_loop().time() + 8
                        while not any(event.name == "input_request" for event in events):
                            if asyncio.get_running_loop().time() >= deadline:
                                self.fail("timed out waiting for stdin request")
                            await asyncio.sleep(0.05)
                    else:
                        await self._wait_for_file(marker)
                    stopped = await self._completion(backend, "shutdown", {})
                    self.assertIsNone(stopped.error)
                    self.assertEqual(stopped.result, {"shutdown": True})
                    self.assertEqual(await asyncio.to_thread(fixture.wait_exited, 8), 0)
                    await asyncio.sleep(0)
                    self.assertEqual(backend._pending, {})
                    self.assertEqual(backend._pending_by_task, {})
                    self.assertEqual(backend._input_prompts, {})
                    self.assertEqual(backend._readers, set())
                    self.assertEqual(backend._tasks, set())
                    await self._retire(backend)


if __name__ == "__main__":
    unittest.main()
