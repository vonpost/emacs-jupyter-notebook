import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class OutputIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_stream_error_result_display_and_png_artifact(self):
        with LocalKernelFixture(startup_timeout=10) as fixture, tempfile.TemporaryDirectory() as directory:
            artifact_dir = Path(directory) / "artifacts"
            artifact_dir.mkdir(mode=0o700)
            backend = JupyterBackend(deadline=8)
            loop = asyncio.get_running_loop()

            async def request(operation, params):
                completion = loop.create_future()
                events = []
                backend.start(operation, params, events.append, completion.set_result)
                return await asyncio.wait_for(completion, 12), events

            assert fixture.connection_path is not None
            connected, _ = await request(
                "connect",
                {"connection_file": str(fixture.connection_path), "artifact_dir": str(artifact_dir)},
            )
            self.assertIsNone(connected.error)
            cases = (
                ("print('ejn-stream')", "stream"),
                ("1 + 1", "execute_result"),
                ("from IPython.display import display; display({'ejn': 1})", "display_data"),
                ("from IPython.display import Image, display; display(Image(data=b'png', format='png'))", "display_data"),
                ("raise ValueError('ejn-error')", "stream"),
            )
            for code, expected in cases:
                result, events = await request("execute", {"code": code})
                self.assertIsNotNone(result.result)
                names = [event.name for event in events]
                self.assertIn(expected, names)
                self.assertEqual(names.count("execute_reply"), 1)
                self.assertEqual(names.count("status"), 1)
                # The normalized IOPub worker flushes output before terminal
                # idle, even when the shell reply races ahead of IOPub.
                self.assertGreater(
                    names.index("status"),
                    max(index for index, name in enumerate(names) if name == expected),
                )
            self.assertTrue(list(artifact_dir.iterdir()))
            backend.close()
            await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
