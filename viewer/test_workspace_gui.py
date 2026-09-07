#!/usr/bin/env python3
"""Offscreen contract checks for WorkspaceWindow."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace
import unittest

import numpy as np
from PySide6 import QtCore, QtGui, QtTest, QtWidgets

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
    def navigation_window(self, *, grid="aligned"):
        array = np.arange(128 * 192, dtype=np.float32).reshape(128, 192)
        window = WorkspaceWindow()
        self.addCleanup(window.close)
        window.install_snapshot(snapshot({"reference": array, "prediction": array.copy()},
                                         grid=grid))
        window.show()
        APP.processEvents()
        window.fit()
        return window

    def camera(self, view):
        rect = view.viewRect()
        return (rect.center().x(), rect.center().y(), rect.width() / view.width())

    def wheel(self, window, name, *, pixels=(0, 0), angle=(0, 0),
              phase=QtCore.Qt.ScrollPhase.NoScrollPhase, touchpad=False):
        view = window._views[name]
        scene = view.mapViewToScene(view.viewRect().topLeft() * 0.25
                                    + view.viewRect().center() * 0.75)
        pos = QtCore.QPointF(window.graphics.mapFromScene(scene))
        device = (QtGui.QPointingDevice("test touchpad", 42,
                  QtGui.QInputDevice.DeviceType.TouchPad,
                  QtGui.QPointingDevice.PointerType.Finger,
                  QtGui.QInputDevice.Capability.Position, 2, 0)
                  if touchpad else QtGui.QPointingDevice.primaryPointingDevice())
        event = QtGui.QWheelEvent(pos, window.graphics.viewport().mapToGlobal(pos),
                                 QtCore.QPoint(*pixels), QtCore.QPoint(*angle),
                                 QtCore.Qt.MouseButton.NoButton,
                                 QtCore.Qt.KeyboardModifier.NoModifier, phase, False,
                                 QtCore.Qt.MouseEventSource.MouseEventNotSynthesized, device)
        QtWidgets.QApplication.sendEvent(window.graphics.viewport(), event)
        return view.mapSceneToView(window.graphics.mapToScene(pos.toPoint()))

    def test_trackpad_scroll_pans_without_zooming(self):
        window = self.navigation_window()
        before = self.camera(window._views["prediction"])
        self.wheel(window, "prediction", pixels=(24, -16), angle=(0, -120),
                   phase=QtCore.Qt.ScrollPhase.ScrollUpdate, touchpad=True)
        after = self.camera(window._views["prediction"])
        self.assertAlmostEqual(after[2], before[2])
        self.assertAlmostEqual(after[0] - before[0], -24 * before[2])
        self.assertAlmostEqual(after[1] - before[1], 16 * before[2])
        np.testing.assert_allclose(self.camera(window._views["reference"]), after)

    def test_native_pinch_zooms_around_pointer_and_links(self):
        window = self.navigation_window()
        view = window._views["prediction"]
        pos = QtCore.QPointF(window.graphics.mapFromScene(
            view.mapViewToScene(view.viewRect().center() + QtCore.QPointF(12, 8))))
        anchor = view.mapSceneToView(window.graphics.mapToScene(pos.toPoint()))
        before = self.camera(view)
        for kind, value in ((QtCore.Qt.NativeGestureType.BeginNativeGesture, 0),
                            (QtCore.Qt.NativeGestureType.ZoomNativeGesture, 0.25),
                            (QtCore.Qt.NativeGestureType.EndNativeGesture, 0)):
            event = QtGui.QNativeGestureEvent(kind,
                QtGui.QPointingDevice.primaryPointingDevice(), 2, pos, pos,
                window.graphics.viewport().mapToGlobal(pos), value, QtCore.QPointF())
            QtWidgets.QApplication.sendEvent(window.graphics.viewport(), event)
        self.assertAlmostEqual(self.camera(view)[2], before[2] / 1.25)
        mapped = view.mapSceneToView(window.graphics.mapToScene(pos.toPoint()))
        np.testing.assert_allclose((mapped.x(), mapped.y()), (anchor.x(), anchor.y()))
        np.testing.assert_allclose(self.camera(window._views["reference"]), self.camera(view))

    def test_linked_pan_has_no_intermediate_scale_changes_in_either_pane(self):
        window = self.navigation_window()
        # Different pane geometries must share scale, not absolute view ranges.
        window.graphics.ci.layout.setColumnFixedWidth(0, 310)
        APP.processEvents()
        window.fit()
        views = list(window._views.values())
        initial = self.camera(views[0])
        observations = []
        for view in views:
            view.sigRangeChanged.connect(lambda source, *_:
                                         observations.append(self.camera(source)))
        for index in range(40):
            source = views[index % 2]
            source.translateBy(x=1.25, y=-0.75)
            APP.processEvents()
            for view in views:
                np.testing.assert_allclose(self.camera(view),
                    (initial[0] + (index + 1) * 1.25,
                     initial[1] - (index + 1) * 0.75, initial[2]), rtol=1e-9)
        self.assertTrue(observations)
        for _, _, scale in observations:
            self.assertAlmostEqual(scale, initial[2], places=9)

    def test_default_layout_pan_does_not_breathe_then_settle(self):
        window = self.navigation_window()
        reference, prediction = window._views.values()
        before = self.camera(prediction)[2]
        observed = []
        prediction.sigRangeChanged.connect(lambda view, *_: observed.append(self.camera(view)[2]))
        reference.translateBy(x=1.25, y=-0.75)
        self.assertTrue(observed)
        for scale in observed:
            self.assertAlmostEqual(scale, before, places=9)

    def test_unshown_snapshot_replacement_preserves_camera_on_first_show(self):
        array = np.arange(16, dtype=np.float32).reshape(4, 4)
        window = WorkspaceWindow()
        self.addCleanup(window.close)
        window.install_snapshot(snapshot({"a": array, "b": array.copy()}))
        window._views["a"].setRange(xRange=(1, 3), yRange=(1, 3), padding=0)
        before = self.camera(window._views["a"])
        window.install_snapshot(snapshot({"a": array.copy(), "b": array.copy()}))
        window.show()
        APP.processEvents()
        for view in window._views.values():
            np.testing.assert_allclose(self.camera(view), before)

    def test_mouse_wheel_zooms_and_incompatible_grids_stay_independent(self):
        window = self.navigation_window(grid=None)
        first = self.camera(window._views["reference"])
        second = self.camera(window._views["prediction"])
        self.wheel(window, "prediction", angle=(0, 120))
        self.assertAlmostEqual(self.camera(window._views["prediction"])[2], second[2] / 1.2)
        np.testing.assert_allclose(self.camera(window._views["reference"]), first)

    def test_touchpad_angle_fallback_and_zero_phase_events_do_not_zoom(self):
        window = self.navigation_window()
        view = window._views["reference"]
        before = self.camera(view)
        self.wheel(window, "reference", phase=QtCore.Qt.ScrollPhase.ScrollBegin)
        np.testing.assert_allclose(self.camera(view), before)
        self.wheel(window, "reference", angle=(12, -24), touchpad=True)
        after = self.camera(view)
        self.assertAlmostEqual(after[2], before[2])
        self.assertNotEqual(after[:2], before[:2])
        self.wheel(window, "reference", phase=QtCore.Qt.ScrollPhase.ScrollEnd)
        np.testing.assert_allclose(self.camera(view), after)

    def test_resize_after_navigation_keeps_center_and_scale(self):
        window = self.navigation_window()
        self.wheel(window, "prediction", angle=(0, 120))
        self.wheel(window, "reference", pixels=(10, 20), touchpad=True)
        before = self.camera(window._views["reference"])
        observed = []
        for view in window._views.values():
            view.sigRangeChanged.connect(lambda source, *_:
                                         observed.append(self.camera(source)[2]))
        for width, height in ((800, 500), (1300, 750), (900, 900)):
            window.resize(width, height)
            APP.processEvents()
            for view in window._views.values():
                np.testing.assert_allclose(self.camera(view), before)
        for scale in observed:
            self.assertAlmostEqual(scale, before[2], places=9)

    def test_mouse_drag_moves_both_panes_without_rescaling(self):
        window = self.navigation_window()
        view = window._views["prediction"]
        before = self.camera(view)
        pos = window.graphics.mapFromScene(view.mapViewToScene(view.viewRect().center()))
        viewport = window.graphics.viewport()
        QtTest.QTest.mousePress(viewport, QtCore.Qt.MouseButton.LeftButton, pos=pos)
        try:
            for step in range(1, 6):
                QtTest.QTest.mouseMove(viewport, pos + QtCore.QPoint(step * 8, step * 4))
                APP.processEvents()
                for pane in window._views.values():
                    self.assertAlmostEqual(self.camera(pane)[2], before[2])
        finally:
            QtTest.QTest.mouseRelease(viewport, QtCore.Qt.MouseButton.LeftButton,
                                     pos=pos + QtCore.QPoint(40, 20))
        self.assertNotEqual(self.camera(view)[:2], before[:2])
        np.testing.assert_allclose(self.camera(window._views["reference"]), self.camera(view))

    def test_close_disposes_navigation_signal_connections(self):
        window = self.navigation_window()
        groups = list(window._navigation_groups)
        window.close()
        self.assertFalse(window._navigation_groups)
        self.assertTrue(all(not group.views for group in groups))

    def test_pixel_readout_cannot_expand_window(self):
        window = self.navigation_window()
        before = window.size()
        window.readout.setText("prediction with a long name " * 100)
        APP.processEvents()
        self.assertEqual(window.size(), before)


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
        self.addCleanup(window.close)
        window.show()
        APP.processEvents()
        window.install_snapshot(snapshot({"a": first, "b": second}))
        APP.processEvents()
        self.assertTrue(window._linked)
        window.level.setValue(7)
        window.width.setValue(3)
        window._views["a"].setRange(xRange=(1, 3), yRange=(1, 3), padding=0)
        old_camera = self.camera(window._views["a"])
        replacement = snapshot({"a": first.copy(), "b": second.copy()})
        window.install_snapshot(replacement)
        APP.processEvents()
        APP.processEvents()
        self.assertEqual(tuple(window._items["a"].getLevels()), (5.5, 8.5))
        np.testing.assert_allclose(self.camera(window._views["a"]), old_camera)
        window.install_snapshot(snapshot({"a": first.copy(), "b": second.copy()}, generation=2))
        self.assertNotEqual(self.camera(window._views["a"]), old_camera)
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
