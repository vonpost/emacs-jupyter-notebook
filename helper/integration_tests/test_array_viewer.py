"""Opt-in local-kernel -> helper -> numerical viewer vertical integration."""

from __future__ import annotations

import hashlib
import json
import os
import selectors
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np
from ejn_array import read_manifest
from kernel_fixture import LocalKernelFixture
from test_helper_contract import EVENT_CREDIT, ProtocolPeer, _success


ROOT = Path(__file__).resolve().parents[2]


def _publisher_setup() -> str:
    """Inject the repository publisher exactly as the runtime setup does."""
    source = (ROOT / "viewer" / "ejn_viewer" / "publisher.py").read_text()
    return ("(lambda ns: (exec(compile(%r, '<ejn-publisher>', 'exec'), ns), "
            "ns['install'](globals()))[1])({})\n" % source)


def _frame_reader(process: subprocess.Popen[bytes], timeout: float = 10.0) -> dict:
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        data = bytearray()
        while len(data) < 4:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AssertionError("viewer frame timeout")
            chunk = os.read(process.stdout.fileno(), 4 - len(data))
            if not chunk:
                raise AssertionError("viewer exited before frame")
            data.extend(chunk)
        length = struct.unpack(">I", data)[0]
        if not 1 <= length <= 65_532:
            raise AssertionError("invalid viewer frame length")
        while len(data) < length + 4:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AssertionError("viewer payload timeout")
            chunk = os.read(process.stdout.fileno(), length + 4 - len(data))
            if not chunk:
                raise AssertionError("viewer exited during payload")
            data.extend(chunk)
        return json.loads(data[4:])
    finally:
        selector.close()


def _viewer_request(process, identifier, operation, params=None):
    payload = json.dumps({"v": 1, "id": identifier, "op": operation,
                          "params": {} if params is None else params},
                         separators=(",", ":")).encode()
    process.stdin.write(struct.pack(">I", len(payload)) + payload)
    process.stdin.flush()


class ArrayViewerVerticalTest(unittest.TestCase):
    def test_local_kernel_helper_viewer_numeric_path(self):
        previous_pythonpath = os.environ.get("PYTHONPATH")
        previous_path = os.environ.get("PATH", "")
        os.environ["PYTHONPATH"] = os.pathsep.join((str(ROOT / "array_protocol"),
                                                      str(ROOT / "viewer")))
        python_bin = str(Path(sys.executable).parent)
        os.environ["PATH"] = os.pathsep.join((python_bin, previous_path))
        helper = viewer = None
        try:
            with tempfile.TemporaryDirectory(prefix="ejn-array-viewer-") as temporary:
                root = Path(temporary)
                artifacts = root / "artifacts"
                artifacts.mkdir(mode=0o700)
                with LocalKernelFixture(startup_timeout=15) as fixture:
                    helper = ProtocolPeer()
                    hello = _success(helper.request("hello", {"versions": [1]}))
                    self.assertIn("array-group-v1", hello["capabilities"])
                    _success(helper.request("grant_event_credit", {"bytes": EVENT_CREDIT}))
                    _success(helper.request("connect", {
                        "connection_file": str(fixture.connection_path),
                        "artifact_dir": str(artifacts), "image_max_pixels": 4_194_304}))
                    reference = np.arange(2 * 3 * 4, dtype=">u2").reshape(2, 3, 4)
                    candidate = (np.arange(2 * 3 * 4, dtype="<f4") / 10).reshape(2, 3, 4)
                    code = ("%matplotlib inline\nimport numpy as np\n" + _publisher_setup()
                            + "reference = " + repr(reference.tolist()) + "\n"
                            + "candidate = " + repr(candidate.tolist()) + "\n"
                            + "reference = np.asarray(reference, dtype='>u2').reshape(2,3,4)\n"
                            + "candidate = np.asarray(candidate, dtype='<f4').reshape(2,3,4)\n"
                            + "ejn.view({'u16': reference[1], 'f32': candidate[:, :, 2]}, key='vertical', sample_id='slice-1')\n")
                    execution = helper.send_async("execute", {"code": code})
                    response = helper.await_response(execution, timeout=20)
                    self.assertTrue(response.get("ok"), response)
                    try:
                        event = helper.await_event(
                            lambda value: value.get("request_id") == execution
                            and "application/x-ejn-array-group" in value.get("data", {}).get("data", {}),
                            "numerical artifact event", timeout=20)
                    except AssertionError as exc:
                        raise AssertionError(
                            f"{exc}; events={[(item.get('event'), item.get('request_id'), item.get('data')) for item in helper.events]}"
                        ) from exc
                    descriptor = event["data"]["data"]["application/x-ejn-array-group"]
                    self.assertNotIn("EJNARR01", repr(event))
                    path = Path(descriptor["path"])
                    self.assertEqual(path.parent, artifacts)
                    manifest = descriptor["manifest"]
                    self.assertEqual([plane["dtype"] for plane in manifest["planes"]], [">u2", "<f4"])
                    self.assertEqual([plane["shape"] for plane in manifest["planes"]], [[3, 4], [2, 3]])
                    with path.open("rb") as stream:
                        parsed, offset = read_manifest(stream, path.stat().st_size)
                        raw = path.read_bytes()
                    self.assertEqual(parsed, manifest)
                    u16 = np.frombuffer(raw, dtype=np.dtype(">u2"), count=12, offset=offset).reshape(3, 4)
                    f32 = np.frombuffer(raw, dtype=np.dtype("<f4"), count=6, offset=offset + 24).reshape(2, 3)
                    np.testing.assert_array_equal(u16, np.asarray(reference[1], dtype="<u2"))
                    np.testing.assert_array_equal(f32, candidate[:, :, 2])
                    file_stat = path.stat()
                    root_stat = artifacts.stat()
                    with path.open("rb") as stream:
                        digest = hashlib.sha256(stream.read()).hexdigest()
                    open_params = {
                        "workspace": "vertical-test", "generation": 1,
                        "execution": execution, "kind": "array-group", "focus": False,
                        "artifact": {"root": str(artifacts), "path": str(path),
                                      "root_device": root_stat.st_dev, "root_inode": root_stat.st_ino,
                                      "device": file_stat.st_dev, "inode": file_stat.st_ino,
                                      "size": file_stat.st_size, "sha256": digest}}
                    env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
                               PYTHONPATH=os.pathsep.join((str(ROOT / "viewer"), str(ROOT / "array_protocol"))))
                    viewer = subprocess.Popen(
                        [sys.executable, "-c", "from ejn_viewer.ipc import run; raise SystemExit(run())"],
                        cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
                    _viewer_request(viewer, "hello", "hello")
                    hello_viewer = _frame_reader(viewer)
                    self.assertTrue(hello_viewer["ok"])
                    _viewer_request(viewer, "open", "open", open_params)
                    opened = _frame_reader(viewer, timeout=20)
                    self.assertTrue(opened["ok"], opened)
                    self.assertEqual(opened["result"]["state"], "visible")
                    path.unlink()
                    _viewer_request(viewer, "ping", "ping")
                    self.assertEqual(_frame_reader(viewer)["result"], {"alive": True})
                    _viewer_request(viewer, "close", "close")
                    viewer.stdin.close()
                    self.assertEqual(viewer.wait(timeout=5), 0)
                    viewer.stdout.close(); viewer.stderr.close(); viewer = None
                    _success(helper.request("close", {}))
                    helper.close_process()
                    helper = None
                    self.assertEqual(fixture.evaluate("assert int(reference[1,0,0]) == 12", timeout=10).get("status"), "ok")
        finally:
            if previous_pythonpath is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = previous_pythonpath
            os.environ["PATH"] = previous_path
            if viewer is not None:
                if viewer.poll() is None:
                    viewer.kill(); viewer.wait(timeout=5)
                if not viewer.stdin.closed:
                    viewer.stdin.close()
                viewer.stdout.close(); viewer.stderr.close()
            if helper is not None:
                helper.close_process()


if __name__ == "__main__":
    unittest.main()
