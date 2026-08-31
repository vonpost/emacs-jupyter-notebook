import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class LocalKernelStdinTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_input_and_getpass_resume_one_execution(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifacts = Path(directory) / "artifacts"
                artifacts.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=8)
                loop = asyncio.get_running_loop()

                async def start(operation, params, events=None):
                    future = loop.create_future()
                    event_callback = (
                        events.append if events is not None else lambda _event: None
                    )
                    backend.start(
                        operation, params, event_callback, future.set_result
                    )
                    return future

                try:
                    connected = await asyncio.wait_for(
                        await start(
                            "connect",
                            {
                                "connection_file": str(fixture.connection_path),
                                "artifact_dir": str(artifacts),
                            },
                        ),
                        12,
                    )
                    self.assertIsNone(connected.error)
                    for code, password, value in (
                        ("name = input('Name: '); print(name)", False, "Ada"),
                        (
                            "import getpass\n"
                            "secret = getpass.getpass('Secret: ')\n"
                            "print(len(secret))",
                            True,
                            "local-secret",
                        ),
                    ):
                        events = []
                        execution = await start("execute", {"code": code}, events)
                        deadline = loop.time() + 8
                        while (
                            not any(
                                event.name == "input_request" for event in events
                            )
                            and loop.time() < deadline
                        ):
                            await asyncio.sleep(0.01)
                        prompt = next(
                            event
                            for event in events
                            if event.name == "input_request"
                        )
                        self.assertEqual(prompt.data["password"], password)
                        reply = await start(
                            "input_reply",
                            {
                                "input_id": prompt.data["input_id"],
                                "value": value,
                            },
                        )
                        self.assertEqual(
                            (await asyncio.wait_for(reply, 2)).result,
                            {"accepted": True},
                        )
                        completion = await asyncio.wait_for(execution, 10)
                        self.assertIsNone(completion.error)
                        self.assertEqual(completion.result.get("status"), "ok")
                finally:
                    backend.close()
                    await asyncio.wait_for(backend.wait_closed(), 2)

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_close_while_prompting_releases_only_local_resources(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifacts = Path(directory) / "artifacts"
                artifacts.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=8)
                loop = asyncio.get_running_loop()
                events = []
                try:
                    connected = loop.create_future()
                    backend.start(
                        "connect",
                        {
                            "connection_file": str(fixture.connection_path),
                            "artifact_dir": str(artifacts),
                        },
                        lambda _event: None,
                        connected.set_result,
                    )
                    self.assertIsNone(
                        (await asyncio.wait_for(connected, 12)).error
                    )
                    completion = loop.create_future()
                    backend.start(
                        "execute",
                        {"code": "input('wait: ')"},
                        events.append,
                        completion.set_result,
                    )
                    deadline = loop.time() + 8
                    while (
                        not any(event.name == "input_request" for event in events)
                        and loop.time() < deadline
                    ):
                        await asyncio.sleep(0.01)
                    self.assertTrue(
                        any(event.name == "input_request" for event in events)
                    )
                finally:
                    backend.close()
                    await asyncio.wait_for(backend.wait_closed(), 2)
                self.assertFalse(backend._input_prompts)
                self.assertFalse(backend._readers)
                self.assertFalse(backend._tasks)


if __name__ == "__main__":
    unittest.main()
