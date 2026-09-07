import json
import sys
import types
import unittest
from unittest.mock import patch

from ejn_helper.backend import BackendError
from ejn_helper.variables import (
    MAX_VARIABLE_BYTES,
    build_variables_expression,
    normalize_variables_reply,
)


def inspect_namespace(namespace, names=None, limit=200):
    expression = build_variables_expression({"names": names, "limit": limit})
    raw = eval(expression, {"get_ipython": lambda: types.SimpleNamespace(user_ns=namespace)})
    return normalize_variables_reply({
        "status": "ok",
        "user_expressions": {"ejn_variables": {
            "status": "ok", "data": {"text/plain": repr(raw)}
        }},
    })


class VariableMetadataTests(unittest.TestCase):
    def test_custom_objects_and_metaclasses_never_run_getters_or_repr(self):
        touched = []

        class Meta(type):
            @property
            def __name__(self):
                touched.append("class name")
                raise AssertionError

            @property
            def __dict__(self):
                touched.append("class dict")
                raise AssertionError

            @property
            def __mro__(self):
                touched.append("class mro")
                raise AssertionError

            @property
            def __module__(self):
                touched.append("class module")
                raise AssertionError

        class Dangerous(metaclass=Meta):
            def __getattribute__(self, name):
                touched.append(name)
                raise AssertionError

            def __repr__(self):
                touched.append("repr")
                raise AssertionError

        namespace = {"obj": Dangerous(), "scalar": 3, "type": 7, "exec": "shadow"}
        before = dict(namespace)
        rows = inspect_namespace(namespace)["variables"]
        self.assertEqual(touched, [])
        self.assertEqual(list(namespace), list(before))
        self.assertTrue(all(namespace[key] is value for key, value in before.items()))
        obj = next(row for row in rows if row["name"] == "obj")
        self.assertTrue(obj["type"].endswith(".Dangerous"))
        self.assertIsNone(obj["shape"])
        self.assertIsNone(obj["dtype"])

    def test_namespace_is_bounded_and_hidden_or_module_names_are_omitted(self):
        namespace = {f"name{i}": i for i in range(5000)}
        namespace.update({"_secret": 1, "sys": sys})
        result = inspect_namespace(namespace, limit=7)
        self.assertEqual(len(result["variables"]), 7)
        self.assertTrue(result["truncated"])
        self.assertLess(len(json.dumps(result)), MAX_VARIABLE_BYTES)
        self.assertEqual(inspect_namespace({"_secret": 1, "sys": sys})["variables"], [])
        self.assertEqual(inspect_namespace({"_secret": 1}, ["_secret"])["variables"][0]["name"], "_secret")

    def test_missing_name_and_memoryview_shape(self):
        self.assertEqual(inspect_namespace({}, ["missing"])["variables"], [])
        view = memoryview(bytes(12)).cast("B", shape=[3, 4])
        result = inspect_namespace({"image": view}, ["image"])
        self.assertEqual(result["variables"][0]["shape"], [3, 4])
        self.assertEqual(result["variables"][0]["dtype"], "B")

    def test_no_heavy_import_is_attempted(self):
        original_import = __import__
        imported = []

        def checked_import(name, *args, **kwargs):
            imported.append(name)
            if name.split(".")[0] in {"numpy", "torch", "pandas", "jax"}:
                raise AssertionError("heavy import")
            return original_import(name, *args, **kwargs)

        with patch("builtins.__import__", checked_import):
            self.assertEqual(inspect_namespace({"value": 1})["variables"][0]["name"], "value")
        self.assertIn("builtins", imported)

    def test_numpy_subclass_metadata_bypasses_user_properties(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("NumPy unavailable")

        class DangerousArray(np.ndarray):
            @property
            def shape(self):
                raise AssertionError("shape property called")

            @property
            def dtype(self):
                raise AssertionError("dtype property called")

            def __repr__(self):
                raise AssertionError("array repr called")

        base = np.zeros((7, 9), dtype=np.float32)
        result = inspect_namespace({"image": base.view(DangerousArray), "scalar": np.asarray(1), "ordinary": base})
        by_name = {row["name"]: row for row in result["variables"]}
        self.assertEqual(by_name["image"]["shape"], [7, 9])
        self.assertEqual(by_name["image"]["dtype"], "float32")
        self.assertEqual(by_name["scalar"]["shape"], [])
        self.assertEqual(by_name["ordinary"]["type"], "numpy.ndarray")

    def test_params_reject_expressions_and_oversized_identifiers(self):
        for params in (
            {"names": ["x.shape"]}, {"names": ["x()"]}, {"names": ["x", "x"]},
            {"names": []}, {"names": ["a" * 129]}, {"names": ["é" * 65]},
            {"limit": True}, {"limit": 201}, {"limit": 0}, {"value": "x"},
        ):
            with self.subTest(params=params), self.assertRaises(BackendError):
                build_variables_expression(params)

    def test_malformed_or_excessive_response_never_crosses_boundary(self):
        for raw in (
            "[]", "{}", json.dumps({"variables": [], "truncated": "false"}),
            json.dumps({"variables": [{"name": "x", "type": "ndarray", "shape": [True], "dtype": "f4"}], "truncated": False}),
            json.dumps({"variables": [{"name": "x", "type": "bad\nname", "shape": None, "dtype": None}], "truncated": False}),
            " " * 66000,
        ):
            with self.subTest(raw=raw[:100]), self.assertRaises(BackendError):
                normalize_variables_reply({"status": "ok", "user_expressions": {
                    "ejn_variables": {"status": "ok", "data": {"text/plain": repr(raw)}}}})


if __name__ == "__main__":
    unittest.main()
