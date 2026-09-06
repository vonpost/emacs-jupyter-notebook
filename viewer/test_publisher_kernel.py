#!/usr/bin/env python3
"""Publisher contract checks, plus an optional real-ipykernel smoke test."""

import base64
import json
import os
import struct
import sys
import unittest
from collections.abc import Mapping
from unittest import mock

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from ejn_viewer import publisher


class PublisherTests(unittest.TestCase):
    def test_install_needs_no_array_dependencies_and_missing_dependency_is_local(self):
        with mock.patch.dict(sys.modules, {"numpy": None, "IPython.display": None}):
            namespace = {}
            publisher.install(namespace)
            with self.assertRaises(ImportError):
                namespace["ejn"].view({}, sample_id="s")
            # Failure affects this explicit publication, not namespace setup.
            self.assertEqual(eval("40 + 2", namespace), 42)
            self.assertIs(namespace["ejn"], publisher.install(namespace))

    def test_install_is_idempotent_and_rejects_user_ejn(self):
        namespace = {}
        first = publisher.install(namespace)
        self.assertIs(first, publisher.install(namespace))
        with self.assertRaises(RuntimeError):
            publisher.install({"ejn": None})
        with self.assertRaises(RuntimeError):
            publisher.install({"ejn": object()})

    def test_serializes_endian_and_strided_planes_without_retaining_arrays(self):
        namespace = {}
        publisher.install(namespace)
        source = np.arange(12, dtype=">u2").reshape(3, 4)
        planes = {"reference": source[::-1, ::2],
                  "candidate": np.array([[-2, -1, 0], [1, 2, 32767]], dtype=">i2")}
        with mock.patch("IPython.display.display") as emit:
            result = namespace["ejn"].view(planes, sample_id="sample", key="k",
                                            grid_id="aligned", units="HU")
        self.assertEqual(result["v"], 1)
        bundle = emit.call_args.args[0]
        blob = base64.b64decode(bundle["application/x-ejn-array-group"], validate=True)
        self.assertEqual(blob[:8], b"EJNARR01")
        header_len = struct.unpack(">I", blob[8:12])[0]
        header = json.loads(blob[12:12 + header_len])
        self.assertEqual([p["dtype"] for p in header["planes"]], [">u2", ">i2"])
        self.assertEqual(header["planes"][1]["offset"], 12)
        self.assertEqual(len(blob), 12 + header_len + 24)
        raw = blob[12 + header_len:]
        self.assertEqual(raw[:12], source[::-1, ::2].tobytes(order="C"))
        self.assertEqual(raw[12:], planes["candidate"].tobytes(order="C"))
        self.assertIn("text/plain", bundle)
        with mock.patch("IPython.display.display") as emit2:
            namespace["ejn"].view({"one": np.zeros((1, 1), dtype="<u1")},
                                    sample_id="sample")
        b2 = base64.b64decode(emit2.call_args.args[0]["application/x-ejn-array-group"])
        n2 = struct.unpack(">I", b2[8:12])[0]
        self.assertNotEqual(header["publication_id"],
                            json.loads(b2[12:12 + n2])["publication_id"])

    def test_aggregate_limit_rejected_before_contiguous_copy(self):
        seed = np.zeros(1, dtype="<u2")
        arrays = {"a": np.lib.stride_tricks.as_strided(seed, shape=(4096, 4096),
                                                        strides=(0, 0)),
                  "b": np.lib.stride_tricks.as_strided(seed, shape=(4096, 4096),
                                                        strides=(0, 0))}
        with mock.patch("IPython.display.display"), \
                mock.patch.object(np, "ascontiguousarray", side_effect=AssertionError("copied")):
            with self.assertRaisesRegex(ValueError, "67108864"):
                publisher._view(arrays, sample_id="sample")

    def test_rejects_unknown_dtype_and_non_2d(self):
        with mock.patch("IPython.display.display"):
            with self.assertRaisesRegex(ValueError, "unsupported dtype"):
                publisher._view({"x": np.zeros((2, 2), dtype="<i8")}, sample_id="s")
            with self.assertRaisesRegex(ValueError, "2D"):
                publisher._view({"x": np.zeros(2, dtype="<u1")}, sample_id="s")
            with self.assertRaisesRegex(ValueError, "masked"):
                publisher._view({"x": np.ma.array([[1, 999]], mask=[[False, True]],
                                                   dtype="<u2")}, sample_id="s")

    def test_mapping_iteration_and_text_are_bounded(self):
        class EndlessMapping(Mapping):
            def __len__(self):
                return 1
            def __getitem__(self, key):
                return np.zeros((1, 1), dtype="u1")
            def __iter__(self):
                for index in range(6):
                    if index == 5:
                        raise AssertionError("read past bounded mapping")
                    yield str(index)
        with self.assertRaises(ValueError):
            publisher._view(EndlessMapping(), sample_id="s")
        with self.assertRaises(ValueError):
            publisher._view({"x": np.zeros((1, 1), dtype="u1")}, sample_id="\ud800")

    def test_real_ipykernel_injection_and_display(self):
        try:
            from jupyter_client import KernelManager
            import matplotlib  # noqa: F401
        except ImportError as exc:
            self.skipTest("real-kernel dependencies unavailable: %s" % (exc,))
        with open(os.path.join(HERE, "ejn_viewer", "publisher.py"), encoding="utf-8") as fh:
            source = fh.read()
        manager = KernelManager(kernel_name="python3")
        client = None
        try:
            manager.start_kernel()
            client = manager.client()
            client.start_channels()
            client.wait_for_ready(timeout=60)
            setup = ("(lambda ns: (exec(compile(" + repr(source) +
                     ", '<ejn-publisher>', 'exec'), ns), "
                     "ns['install'](globals()))[1])({})\n")
            code = (setup + setup +
                    "assert '_view' not in globals()\n"
                    "%matplotlib inline\n"
                    "import matplotlib.pyplot as plt\n"
                    "import numpy as np\n"
                    "plt.figure()\n"
                    "ejn.view({'a': np.arange(6, dtype='>u2').reshape(2, 3), "
                    "'b': np.array([[-2, -1, 0], [1, 2, 32767]], dtype='>i2')}, "
                    "sample_id='kernel-sample')\n")
            msg_id = client.execute(code, silent=False, store_history=False)
            found = None
            while True:
                msg = client.get_iopub_msg(timeout=60)
                if msg["parent_header"].get("msg_id") != msg_id:
                    continue
                if msg["msg_type"] == "display_data":
                    data = msg["content"]["data"]
                    if "application/x-ejn-array-group" in data:
                        found = data
                if (msg["msg_type"] == "status"
                        and msg["content"]["execution_state"] == "idle"):
                    break
            self.assertIsNotNone(found)
            self.assertIn("application/x-ejn-array-group", found)
            blob = base64.b64decode(found["application/x-ejn-array-group"], validate=True)
            n = struct.unpack(">I", blob[8:12])[0]
            header = json.loads(blob[12:12+n])
            self.assertEqual(len(header["planes"]), 2)
            self.assertEqual(blob[12+n:12+n+12], struct.pack(">6H", *range(6)))
            self.assertEqual(blob[12+n+12:], struct.pack(">6h", -2, -1, 0, 1, 2, 32767))
            manager.restart_kernel(now=True)
            client.wait_for_ready(timeout=60)
            restarted = client.execute(setup + "assert ejn._ejn_publisher_marker == 'ejn-array-group-v1'")
            while True:
                reply = client.get_shell_msg(timeout=60)
                if reply["parent_header"].get("msg_id") == restarted:
                    self.assertEqual(reply["content"]["status"], "ok")
                    break
        finally:
            if client is not None:
                client.stop_channels()
            if manager.has_kernel:
                manager.shutdown_kernel(now=True)


def main():
    return unittest.main()


if __name__ == "__main__":
    main()
