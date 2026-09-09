"""An explicit array slice through the real helper and a test-owned kernel."""

import asyncio
import struct
import tempfile
import unittest
from pathlib import Path

from ejn_array import MIME
from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class VariableViewIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(LocalKernelFixture.available(), "local Jupyter runtime unavailable")
    async def test_selected_plane_artifact_and_history_free_inspection(self):
        publisher = (Path(__file__).resolve().parents[2] /
                     "viewer/ejn_viewer/publisher.py").read_text(encoding="utf-8")
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
                    setup = ("(lambda ns: (exec(compile(" + repr(publisher) +
                             ", '<ejn-publisher>', 'exec'), ns), "
                             "ns['install'](globals()))[1])({})\n"
                             "import numpy as np\n"
                             "cube = np.arange(120, dtype='<u2').reshape(3,4,5,2)\n"
                             "_ejn_before_count = get_ipython().execution_count\n"
                             "_ejn_before_names = set(globals())\n")
                    result, _ = await request("execute", {"code": setup})
                    self.assertEqual(result["status"], "ok")
                    result, events = await request("execute", {
                        "code": 'ejn.view_variable("cube", axes=[2,1], indices=[1,None,None,0])',
                        "store_history": False,
                    })
                    self.assertEqual(result["status"], "ok")
                    publications = [event.data["data"][MIME] for event in events
                                    if event.name == "display_data" and MIME in event.data.get("data", {})]
                    self.assertEqual(len(publications), 1)
                    descriptor = publications[0]
                    self.assertEqual(descriptor["manifest"]["planes"][0]["shape"], [5, 4])
                    self.assertEqual(descriptor["manifest"]["planes"][0]["dtype"], "<u2")
                    payload = Path(descriptor["path"]).read_bytes()
                    header_bytes = struct.unpack(">I", payload[8:12])[0]
                    samples = payload[12 + header_bytes:]
                    self.assertEqual(len(samples), 40)
                    self.assertEqual(struct.unpack("<20H", samples),
                                     tuple(40 + 10 * column + 2 * row
                                           for row in range(5) for column in range(4)))
                    verified, _ = await request("execute", {"code": (
                        "assert get_ipython().execution_count == _ejn_before_count + 1\n"
                        "assert set(globals()) - _ejn_before_names <= {'_ejn_before_names', '_i', '_ii', '_iii', '_i2'}\n"
                        "assert cube.shape == (3, 4, 5, 2)\n")})
                    self.assertEqual(verified["status"], "ok")
                finally:
                    backend.close()
                    await backend.wait_closed()
                    self.assertEqual(backend._pending, {})
                    self.assertEqual(backend._readers, set())


if __name__ == "__main__":
    unittest.main()
