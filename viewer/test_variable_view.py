"""Bounded selected-plane publication from a named live NumPy variable."""

import unittest
from unittest import mock

import numpy as np

from ejn_viewer import publisher


class VariableViewTests(unittest.TestCase):
    def publish(self, namespace, name, **kwargs):
        with mock.patch.object(publisher, "_view") as view:
            publisher._view_variable(namespace, name, **kwargs)
        return view.call_args.args[0][name], view.call_args.kwargs

    def test_multidimensional_channel_selection_and_reversed_display_axes(self):
        source = np.arange(2 * 5 * 7 * 3, dtype=np.float32).reshape(2, 5, 7, 3)
        before = source.copy()
        selected, metadata = self.publish({"volume": source}, "volume",
                                          axes=[2, 1], indices=[1, None, None, 2])
        self.assertIs(type(selected), np.ndarray)
        np.testing.assert_array_equal(selected, source[1, :, :, 2].T)
        self.assertTrue(np.shares_memory(selected, source))
        np.testing.assert_array_equal(source, before)
        self.assertEqual(selected.nbytes, 5 * 7 * 4)
        other, same = self.publish({"volume": source}, "volume", axes=[2, 1], indices=[1, None, None, 2])
        self.assertEqual(metadata, same)
        _, changed = self.publish({"volume": source}, "volume", axes=[2, 1], indices=[0, None, None, 2])
        self.assertEqual(metadata["key"], changed["key"])
        self.assertNotEqual(metadata["sample_id"], changed["sample_id"])
        self.assertNotIn("grid_id", metadata)
        self.assertNotIn("units", metadata)

    def test_large_remote_volume_only_exposes_selected_small_plane(self):
        # A huge broadcast source makes accidental whole-volume conversion
        # observable without allocating hundreds of megabytes in the test.
        source = np.broadcast_to(np.float32(3), (5000, 64, 64))
        with mock.patch.object(np, "asarray", side_effect=AssertionError("whole-array conversion")):
            selected, _ = self.publish({"volume": source}, "volume",
                                       axes=[1, 2], indices=[4999, None, None])
        self.assertEqual(selected.shape, (64, 64))
        self.assertEqual(selected.nbytes, 16384)
        self.assertTrue(np.shares_memory(selected, source))

    def test_array_subclass_getters_slicing_and_finalize_are_bypassed(self):
        class Dangerous(np.ndarray):
            def __getattribute__(self, name):
                raise AssertionError("subclass attribute " + name)

            def __getitem__(self, index):
                raise AssertionError("subclass slicing")

            def __array_finalize__(self, source):
                if source is not None and type(source) is Dangerous:
                    raise AssertionError("subclass finalizer")

            def __repr__(self):
                raise AssertionError("array repr")

        base = np.arange(24, dtype=np.uint16).reshape(2, 3, 4)
        array = base.view(Dangerous)
        selected, _ = self.publish({"array": array}, "array", axes=[1, 2], indices=[1, None, None])
        np.testing.assert_array_equal(selected, base[1])
        self.assertIs(type(selected), np.ndarray)

    def test_metadata_rejections_precede_plane_publication(self):
        base = np.zeros((2, 3, 4), dtype=np.float32)
        cases = [
            ({"x": base}, "x()", {}), ({}, "x", {}),
            ({"x": base}, "x", {}),
            ({"x": base}, "x", {"axes": [1, 1]}),
            ({"x": base}, "x", {"axes": [True, 2]}),
            ({"x": base}, "x", {"axes": [1, 2], "indices": [-1, None, None]}),
            ({"x": base}, "x", {"axes": [1, 2], "indices": [2, None, None]}),
            ({"x": base}, "x", {"axes": [1, 2], "indices": [0, 1, None]}),
            ({"x": base}, "x", {"axes": [1, 2], "indices": [0, None]}),
            ({"x": np.zeros((2, 3), dtype=np.int64)}, "x", {}),
            ({"x": np.zeros((0, 3), dtype=np.float32)}, "x", {}),
            ({"x": np.ma.array([[1, 2]], mask=[[True, False]])}, "x", {}),
        ]
        for namespace, name, kwargs in cases:
            with self.subTest(name=name, kwargs=kwargs), mock.patch.object(publisher, "_view") as emit:
                with self.assertRaises(ValueError):
                    publisher._view_variable(namespace, name, **kwargs)
                emit.assert_not_called()

    def test_unknown_object_properties_are_not_inspected(self):
        class Dangerous:
            def __getattribute__(self, name):
                raise AssertionError("attribute " + name)

            def __repr__(self):
                raise AssertionError("repr")

        with self.assertRaisesRegex(ValueError, "NumPy ndarray"):
            publisher._view_variable({"value": Dangerous()}, "value")

    def test_plane_budget_is_checked_before_copy_and_huge_source_is_not_rejected(self):
        source = np.broadcast_to(np.float32(0), (2, 8192, 8192))
        with mock.patch.object(publisher, "_view") as emit:
            with self.assertRaisesRegex(ValueError, "33554432"):
                publisher._view_variable({"volume": source}, "volume", axes=[1, 2], indices=[0, None, None])
            emit.assert_not_called()
        selected, _ = self.publish({"volume": source}, "volume", axes=[0, 1], indices=[None, None, 0])
        self.assertEqual(selected.shape, (2, 8192))

    def test_install_refreshes_owned_methods_for_existing_durable_kernel(self):
        namespace = {"image": np.ones((2, 3), dtype=np.float32)}
        instance = publisher.install(namespace)
        type(instance).view_variable = staticmethod(lambda *a, **kw: "obsolete")
        self.assertIs(publisher.install(namespace), instance)
        with mock.patch.object(publisher, "_view") as emit:
            instance.view_variable("image")
            self.assertEqual(emit.call_args.args[0]["image"].shape, (2, 3))
        self.assertEqual(set(namespace), {"image", "ejn"})


if __name__ == "__main__":
    unittest.main()
