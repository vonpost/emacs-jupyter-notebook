#!/usr/bin/env python3
"""Publisher contract checks, plus an optional real-ipykernel smoke test."""

import base64
import io
import importlib.util
import json
import os
import struct
import sys
import types
import unittest
from collections.abc import Mapping
from unittest import mock

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from ejn_viewer import publisher
from ejn_array import read_manifest


def decode_publication(bundle):
    blob = base64.b64decode(bundle["application/x-ejn-array-group"], validate=True)
    header, offset = read_manifest(io.BytesIO(blob), len(blob))
    arrays = {plane["name"]: np.frombuffer(blob, dtype=plane["dtype"],
              count=np.prod(plane["shape"]), offset=offset + plane["offset"])
              .reshape(plane["shape"]) for plane in header["planes"]}
    return header, arrays


class PublisherTests(unittest.TestCase):
    def test_install_needs_no_array_dependencies_and_missing_dependency_is_local(self):
        with mock.patch.dict(sys.modules, {"numpy": None, "IPython.display": None, "torch": None}):
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
        self.assertIsNone(result)
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

    def test_strided_volume_crop_float16_and_numpy_publish_without_torch(self):
        source = np.arange(5 * 7 * 9, dtype=">f2").reshape(5, 7, 9)
        crop = source[1:4, ::2, 2:8:2]
        before = source.copy()
        with mock.patch.dict(sys.modules, {"torch": None}), mock.patch("IPython.display.display") as emit:
            publisher._view({"crop": crop}, sample_id="cropped")
        header, arrays = decode_publication(emit.call_args.args[0])
        self.assertEqual(header["planes"][0]["shape"], [3, 4, 3])
        self.assertEqual(header["planes"][0]["dtype"], ">f2")
        np.testing.assert_array_equal(arrays["crop"], crop)
        source[:] = 0
        np.testing.assert_array_equal(arrays["crop"], before[1:4, ::2, 2:8:2])

    def test_tensor_budgets_precede_detach_or_cpu_copy_without_torch_dependency(self):
        dense_layout = object()

        class Tensor:
            layout = dense_layout
            is_nested = False
            is_quantized = False
            device = types.SimpleNamespace(type="cuda")

            def __init__(self, shape, dtype="torch.float32"):
                self.shape, self.dtype = shape, dtype

            def detach(self):
                raise AssertionError("tensor accessed before budget validation")

        fake_torch = types.SimpleNamespace(Tensor=Tensor, strided=dense_layout)
        cases = [
            ({"a": Tensor((512, 512, 512))}, "33554432"),
            ({"a": Tensor((1, 1, 16385))}, "dimensions"),
            ({"a": Tensor((4096, 4096), "torch.bfloat16")}, "33554432"),
            ({"a": Tensor((2048, 4096), "torch.bfloat16"),
              "b": Tensor((2048, 4096), "torch.bfloat16")}, "67108864"),
            ({"a": Tensor((2, 3), "torch.complex64")}, "unsupported dtype"),
        ]
        with mock.patch.dict(sys.modules, {"torch": fake_torch, "torch.nn.parameter": None}):
            for members, message in cases:
                with self.subTest(message=message), mock.patch("IPython.display.display") as emit:
                    with self.assertRaisesRegex(ValueError, message):
                        publisher._view(members, sample_id="s")
                    emit.assert_not_called()

    def test_real_tensors_preserve_values_gradient_state_and_device(self):
        try:
            import torch
        except ImportError:
            self.skipTest("optional PyTorch dependency unavailable")
        devices = ["cpu"] + (["cuda"] if torch.cuda.is_available() else [])
        for device in devices:
            source = torch.arange(120, dtype=torch.float16, device=device).reshape(4, 5, 6)
            source.requires_grad_(True)
            crop = source[1:4:2, :, ::2].transpose(0, 1)
            parameter = torch.nn.Parameter(torch.tensor([[1.25, -2.5]], device=device))
            wide = torch.tensor([[1.5, -0.25], [256.0, float("inf")]],
                                dtype=torch.bfloat16, device=device)
            negative = torch._neg_view(torch.tensor([[1.0, -2.0]], device=device))
            expected = crop.detach().cpu().numpy().copy()
            with mock.patch("IPython.display.display") as emit:
                publisher._view({"crop": crop, "parameter": parameter, "wide": wide,
                                 "negative": negative}, sample_id="s",
                                spacing={"crop": (0.2, 0.1, 0.3), "parameter": (0.1, 0.1),
                                         "wide": (0.1, 0.1), "negative": (0.1, 0.1)})
            header, arrays = decode_publication(emit.call_args.args[0])
            np.testing.assert_array_equal(arrays["crop"], expected)
            np.testing.assert_array_equal(arrays["parameter"], [[1.25, -2.5]])
            np.testing.assert_array_equal(arrays["wide"], [[1.5, -0.25], [256.0, np.inf]])
            np.testing.assert_array_equal(arrays["negative"], [[-1.0, 2.0]])
            self.assertEqual(header["planes"][0]["dtype"], np.dtype("float16").str)
            self.assertEqual(header["planes"][0]["spacing"], [0.2, 0.1, 0.3])
            self.assertEqual(header["planes"][2]["dtype"], np.dtype("float32").str)
            self.assertTrue(source.requires_grad)
            self.assertTrue(parameter.requires_grad)
            self.assertIsNone(source.grad)
            self.assertEqual(str(source.device), device if device == "cpu" else "cuda:0")

    def test_real_unsupported_tensors_fail_before_conversion(self):
        try:
            import torch
        except ImportError:
            self.skipTest("optional PyTorch dependency unavailable")

        class Dangerous(torch.Tensor):
            def __getattribute__(self, name):
                raise AssertionError("subclass attribute " + name)

        cases = [
            (torch.zeros((2, 3), device="meta"), "meta"),
            (torch.zeros((2, 3), dtype=torch.complex64), "unsupported dtype"),
            (torch.zeros((2, 3), dtype=torch.int64), "unsupported dtype"),
            (torch.zeros((2, 3)).to_sparse(), "sparse"),
            (torch.quantize_per_tensor(torch.zeros((2, 3)), 1.0, 0, torch.qint8), "quantized"),
            (torch.zeros((2, 3)).as_subclass(Dangerous), "exact PyTorch"),
        ]
        for value, message in cases:
            with self.subTest(message=message), mock.patch("IPython.display.display") as emit:
                with self.assertRaisesRegex(ValueError, message):
                    publisher._view({"x": value}, sample_id="s")
                emit.assert_not_called()

    def test_tensor_metadata_change_is_rejected_before_cpu_allocation(self):
        try:
            import torch
        except ImportError:
            self.skipTest("optional PyTorch dependency unavailable")
        source = torch.zeros((2, 3), dtype=torch.float32)
        shape, dtype, backend = publisher._array_metadata(source, np)
        source.resize_(3, 2)
        with mock.patch.object(torch.Tensor, "to", side_effect=AssertionError("copied")):
            with self.assertRaisesRegex(ValueError, "metadata changed"):
                publisher._array_bytes(source, shape, dtype, backend, np)

    def test_shared_spacing_defaults_to_zero_sample_center_origin_and_mm(self):
        for shape in ((2, 3), (2, 3, 4)):
            values = np.zeros(shape, dtype=np.float32)
            spacing = (0.2, 0.1, 0.5)[:len(shape)]
            with mock.patch("IPython.display.display") as emit:
                publisher._view({"image": values}, sample_id="s", spacing=spacing)
            header, arrays = decode_publication(emit.call_args.args[0])
            metadata = header["planes"][0]
            self.assertEqual(metadata["spacing"], list(spacing))
            self.assertEqual(metadata["origin"], [0] * len(shape))
            self.assertEqual(metadata["direction"], np.eye(len(shape), dtype=int).ravel().tolist())
            self.assertEqual(metadata["spatial_units"], "mm")
            np.testing.assert_array_equal(arrays["image"], values)

    def test_per_member_spacing_and_origin_preserve_different_resolution_samples(self):
        planes = {"reference": np.arange(9, dtype=np.float32).reshape(3, 3),
                  "upsampled": np.arange(15, dtype=np.float32).reshape(5, 3)}
        with mock.patch("IPython.display.display") as emit:
            publisher._view(planes, sample_id="s", grid_id="shared-frame", units="HU",
                            spacing={"reference": (0.2, 0.1), "upsampled": (0.1, 0.1)},
                            origin={"reference": (10, -2), "upsampled": (10, -2)},
                            spatial_units="mm")
        header, arrays = decode_publication(emit.call_args.args[0])
        reference, upsampled = header["planes"]
        self.assertEqual(reference["spacing"], [0.2, 0.1])
        self.assertEqual(upsampled["spacing"], [0.1, 0.1])
        for metadata in header["planes"]:
            self.assertEqual(metadata["grid_id"], "shared-frame")
            self.assertEqual(metadata["origin"], [10, -2])
            self.assertEqual(metadata["units"], "HU")
        for name, original in planes.items():
            np.testing.assert_array_equal(arrays[name], original)

    def test_no_spacing_keeps_pixel_coordinate_publications(self):
        with mock.patch("IPython.display.display") as emit:
            publisher._view({"image": np.zeros((2, 3), dtype=np.float32)}, sample_id="s")
        header, _ = decode_publication(emit.call_args.args[0])
        self.assertFalse({"spacing", "origin", "direction", "spatial_units"} & set(header["planes"][0]))

    def test_invalid_spatial_metadata_is_rejected_before_any_sample_copy(self):
        planes = {"a": np.zeros((2, 3), dtype=np.float32),
                  "b": np.zeros((2, 3, 4), dtype=np.float32)}
        valid_spacing = {"a": (0.2, 0.1), "b": (0.2, 0.1, 0.3)}
        cases = [
            {"origin": (0, 0)}, {"spacing": (0.2,)},
            {"spacing": (0.2, 0.1)},  # Wrong rank for the second member.
            {"spacing": {"a": (0.2, 0.1)}},
            {"spacing": {"a": (0.2, 0.1), "other": (0.2, 0.1, 0.3)}},
            {"spacing": {"a": (0.2, 0.1), "b": (0.2, 0, 0.3)}},
            {"spacing": {"a": (0.2, 0.1), "b": (0.2, -1, 0.3)}},
            {"spacing": {"a": (0.2, 0.1), "b": (0.2, float("inf"), 0.3)}},
            {"spacing": {"a": (0.2, True), "b": (0.2, 0.1, 0.3)}},
            {"spacing": valid_spacing, "origin": {"a": (0, 0)}},
            {"spacing": valid_spacing, "origin": {"a": (0, 0), "b": (0, float("nan"), 0)}},
            {"spacing": valid_spacing, "spatial_units": ""},
        ]
        with mock.patch.object(publisher, "_array_bytes", side_effect=AssertionError("copied")):
            for kwargs in cases:
                with self.subTest(kwargs=kwargs), mock.patch("IPython.display.display") as emit:
                    with self.assertRaises(ValueError):
                        publisher._view(planes, sample_id="s", **kwargs)
                    emit.assert_not_called()

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
                    "sample_id='kernel-sample')\n"
                    "ejn.view({'crop': np.arange(5*7*9, dtype='<f2').reshape(5,7,9)[1:3,2:5,1:5]}, "
                    "sample_id='crop-sample', spacing=(0.2,0.1,0.3), origin=(10,20,30))\n")
            has_torch = importlib.util.find_spec("torch") is not None
            if has_torch:
                code += ("import torch\n"
                         "tensor = torch.arange(120, dtype=torch.float32).reshape(2,3,4,5).requires_grad_()\n"
                         "ejn.view_variable('tensor', axes=[2,1], indices=[1,None,None,2])\n"
                         "assert tensor.requires_grad and tensor.grad is None\n")
            msg_id = client.execute(code, silent=False, store_history=False)
            publications = []
            while True:
                msg = client.get_iopub_msg(timeout=60)
                if msg["parent_header"].get("msg_id") != msg_id:
                    continue
                if msg["msg_type"] == "display_data":
                    data = msg["content"]["data"]
                    if "application/x-ejn-array-group" in data:
                        publications.append(data)
                if msg["msg_type"] == "error":
                    self.fail(msg["content"]["evalue"])
                if (msg["msg_type"] == "status"
                        and msg["content"]["execution_state"] == "idle"):
                    break
            self.assertEqual(len(publications), 3 if has_torch else 2)
            found = publications[0]
            self.assertIn("application/x-ejn-array-group", found)
            blob = base64.b64decode(found["application/x-ejn-array-group"], validate=True)
            n = struct.unpack(">I", blob[8:12])[0]
            header = json.loads(blob[12:12+n])
            self.assertEqual(len(header["planes"]), 2)
            self.assertEqual(blob[12+n:12+n+12], struct.pack(">6H", *range(6)))
            self.assertEqual(blob[12+n+12:], struct.pack(">6h", -2, -1, 0, 1, 2, 32767))
            cropped_metadata, cropped = decode_publication(publications[1])
            self.assertEqual(cropped_metadata["planes"][0]["spacing"], [0.2, 0.1, 0.3])
            self.assertEqual(cropped_metadata["planes"][0]["origin"], [10, 20, 30])
            np.testing.assert_array_equal(cropped["crop"],
                np.arange(5 * 7 * 9, dtype="<f2").reshape(5, 7, 9)[1:3, 2:5, 1:5])
            if has_torch:
                _, tensors = decode_publication(publications[2])
                np.testing.assert_array_equal(tensors["tensor"],
                    np.arange(120, dtype=np.float32).reshape(2, 3, 4, 5)[1, :, :, 2].T)
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
