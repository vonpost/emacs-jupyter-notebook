"""Metadata requests against a test-owned local Python kernel."""

import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class VariableIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "local Jupyter runtime unavailable")
    async def test_numpy_metadata_without_values_getters_history_or_output(self):
        with LocalKernelFixture(startup_timeout=15) as fixture:
            with tempfile.TemporaryDirectory() as directory:
                artifact_dir = Path(directory) / "artifacts"
                artifact_dir.mkdir(mode=0o700)
                backend = JupyterBackend(deadline=10)

                async def request(operation, params):
                    future = asyncio.get_running_loop().create_future()
                    events = []
                    backend.start(operation, params, events.append, future.set_result)
                    completion = await asyncio.wait_for(future, 15)
                    self.assertIsNone(completion.error)
                    return completion.result, events

                try:
                    await request("connect", {
                        "connection_file": str(fixture.connection_path),
                        "artifact_dir": str(artifact_dir), "image_max_pixels": 4_194_304,
                    })
                    await request("execute", {"code": """
import numpy as np
image = np.zeros((128, 64), dtype=np.float32)
scalar = np.asarray(7)
empty = np.empty((0, 3))
class Tricky(np.ndarray):
    @property
    def shape(self):
        raise AssertionError('overridden shape invoked')
    @property
    def dtype(self):
        raise AssertionError('overridden dtype invoked')
    def __repr__(self):
        raise AssertionError('repr invoked')
tricky = image.view(Tricky)
_ejn_metadata_execution_count = get_ipython().execution_count
"""})
                    result, events = await request("variables", {
                        "names": ["image", "scalar", "empty", "tricky", "undefined"], "limit": 5,
                    })
                    self.assertEqual(events, [])
                    by_name = {row["name"]: row for row in result["variables"]}
                    self.assertEqual(set(by_name), {"image", "scalar", "empty", "tricky"})
                    self.assertEqual(by_name["image"]["shape"], [128, 64])
                    self.assertEqual(by_name["image"]["dtype"], "float32")
                    self.assertEqual(by_name["scalar"]["shape"], [])
                    self.assertEqual(by_name["empty"]["shape"], [0, 3])
                    self.assertEqual(by_name["tricky"]["shape"], [128, 64])
                    self.assertEqual(by_name["tricky"]["dtype"], "float32")
                    listed, events = await request("variables", {"names": None, "limit": 200})
                    self.assertEqual(events, [])
                    self.assertIn("image", [row["name"] for row in listed["variables"]])
                    verified, _ = await request("execute", {"code": """
assert get_ipython().execution_count == _ejn_metadata_execution_count + 1
assert '_ejn_variables' not in globals()
assert '_scope' not in globals()
"""})
                    self.assertEqual(verified["status"], "ok")
                finally:
                    backend.close()
                    await backend.wait_closed()
                    self.assertEqual(backend._pending, {})
                    self.assertEqual(backend._readers, set())


if __name__ == "__main__":
    unittest.main()
