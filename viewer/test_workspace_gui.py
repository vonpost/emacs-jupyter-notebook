#!/usr/bin/env python3
"""Offscreen contract checks for WorkspaceWindow."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace
import unittest

import numpy as np
from PySide6 import QtCore, QtWidgets

from ejn_viewer.workspace import WorkspaceWindow


APP = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def snapshot(planes, *, grid="aligned", numerical=True, sample="s", generation=1):
    return SimpleNamespace(
        planes=planes,
        manifest={"sample_id": sample,
                  "grid_id": grid,
                  "planes":[{"name": name, "shape": list(array.shape),
                              "grid_id": grid, "spacing": [1, 1],
                              "origin": [0, 0], "direction": [1, 0, 0, 1],
                              "spatial_units": "px"} for name, array in planes.items()]},
        numerical=numerical, workspace="w", generation=generation,
        execution="e", nbytes=sum(array.nbytes for array in planes.values()))


class WorkspaceGuiTests(unittest.TestCase):
    def test_asymmetric_panes_and_source_immutability(self):
        reference = np.arange(12, dtype=np.float32).reshape(3, 4)
        candidate = np.arange(20, dtype=np.float32).reshape(4, 5)
        before = (reference.copy(), candidate.copy())
        window = WorkspaceWindow()
        window.install_snapshot(snapshot({"reference": reference, "candidate": candidate}))
        APP.processEvents()
        self.assertEqual(len(window._views), 2)
        self.assertFalse(window._linked)
        window.level.setValue(5)
        window.width.setValue(2)
        window.fit()
        np.testing.assert_array_equal(reference, before[0])
        np.testing.assert_array_equal(candidate, before[1])
        window.close()

    def test_same_declared_grid_links_and_preserves_levels(self):
        first = np.arange(16, dtype=np.float32).reshape(4, 4)
        second = first + 10
        window = WorkspaceWindow()
        window.install_snapshot(snapshot({"a": first, "b": second}))
        APP.processEvents()
        self.assertTrue(window._linked)
        window.level.setValue(7)
        window.width.setValue(3)
        window._views["a"].setRange(xRange=(1, 3), yRange=(1, 3), padding=0)
        old_range = window._views["a"].viewRange()
        replacement = snapshot({"a": first.copy(), "b": second.copy()})
        window.install_snapshot(replacement)
        APP.processEvents()
        self.assertEqual(tuple(window._items["a"].getLevels()), (5.5, 8.5))
        self.assertEqual(window._views["a"].viewRange(), old_range)
        window.install_snapshot(snapshot({"a": first.copy(), "b": second.copy()}, generation=2))
        self.assertNotEqual(window._views["a"].viewRange(), old_range)
        window.close()

    def test_raster_disables_numeric_linking(self):
        window = WorkspaceWindow()
        window.install_snapshot(snapshot({"r": np.ones((3, 5), dtype=np.uint8)},
                                         numerical=False))
        self.assertFalse(window._linked)
        self.assertFalse(window.level.isEnabled())
        window._mouse_moved(QtCore.QPointF(-100, -100))
        self.assertEqual(window.readout.text(), "Pixel: —")
        window.close()

    def test_all_nan_uses_explicit_levels_and_rgb_raster_is_supported(self):
        window = WorkspaceWindow()
        nan = np.full((3, 4), np.nan, dtype=np.float32)
        window.install_snapshot(snapshot({"nan": nan}))
        self.assertEqual(tuple(window._items["nan"].getLevels()), (0.0, 1.0))
        window.install_snapshot(snapshot({"rendered": np.zeros((3, 4, 3), dtype=np.uint8)},
                                         numerical=False))
        self.assertFalse(window.level.isEnabled())
        self.assertEqual(tuple(window._items["rendered"].getLevels()), (0.0, 255.0))
        window.close()


if __name__ == "__main__":
    unittest.main()
